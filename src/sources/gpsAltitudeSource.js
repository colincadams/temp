// Grade from GPS altitude. This is the noisy fallback (works fully offline).
// iPhone GPS vertical accuracy is ±10–20 m, so we never trust a single pair of
// fixes — we fit a least-squares line to altitude vs. cumulative horizontal
// distance over a sliding window, which averages the noise down.

import { haversine } from "../geo.js";
import { linearSlope, clamp } from "../smoothing.js";
import { plausibleGrade } from "../grade.js";

const WINDOW_METERS = 220; // baseline length to fit over
const MIN_POINTS = 6;
const MIN_SPEED = 2.5; // m/s (~9 km/h) — below this, parked/jitter dominates

export class GpsAltitudeSource {
  constructor(locationService) {
    this.name = "gps";
    this.label = "GPS altitude";
    this.loc = locationService;
    this.buffer = []; // { dist (cumulative), alt, ts }
    this._cum = 0;
    this._unsub = null;
    this.status = "idle";
  }

  available() {
    return "geolocation" in navigator;
  }

  start(emit) {
    this._emit = emit;
    let prev = null;
    this._unsub = this.loc.subscribe((fix) => {
      if (prev) this._cum += haversine(prev.lat, prev.lon, fix.lat, fix.lon);
      prev = fix;

      if (fix.altitude == null) {
        this.status = "no altitude from GPS";
        return;
      }
      this.buffer.push({ dist: this._cum, alt: fix.altitude, ts: fix.ts });

      // Drop points older than the window length (by distance).
      const cutoff = this._cum - WINDOW_METERS;
      while (this.buffer.length && this.buffer[0].dist < cutoff) this.buffer.shift();

      const span = this._cum - this.buffer[0].dist;
      const speed = fix.speed ?? 0;

      if (this.buffer.length < MIN_POINTS || span < WINDOW_METERS * 0.5) {
        this.status = "warming up";
        return;
      }
      if (speed < MIN_SPEED) {
        this.status = "too slow";
        return;
      }

      const xs = this.buffer.map((p) => p.dist);
      const ys = this.buffer.map((p) => p.alt);
      const { slope, r2, n } = linearSlope(xs, ys);
      if (!Number.isFinite(slope)) {
        this.status = "no fit";
        return;
      }

      const gradePercent = plausibleGrade(slope * 100);

      // Confidence: better with a longer baseline, more points, a clean linear
      // fit, and tighter reported vertical accuracy.
      const altAcc = fix.altitudeAccuracy ?? 25;
      const spanScore = clamp(span / WINDOW_METERS, 0, 1);
      const nScore = clamp(n / 15, 0, 1);
      const accScore = clamp(1 - (altAcc - 5) / 30, 0, 1);
      const confidence = clamp(0.15 + 0.45 * spanScore * nScore + 0.4 * r2 * accScore, 0, 0.7);

      this.status = `±${altAcc.toFixed(0)}m vert`;
      emit({ source: this.name, gradePercent, confidence, ts: fix.ts });
    });
  }

  stop() {
    this._unsub?.();
    this._unsub = null;
    this.buffer = [];
    this._cum = 0;
    this.status = "idle";
  }
}
