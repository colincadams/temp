// Grade from a barometric altimeter. The iPhone's pressure sensor resolves
// ~0.1 m of *relative* altitude change, so paired with horizontal distance it
// gives the most accurate, most responsive grade (~±0.3%).
//
// Safari does NOT expose the barometer to web pages, so in a plain browser this
// source reports unavailable and the fuser simply ignores it. To "go native"
// you wrap this same web app (e.g. with Capacitor) and provide a bridge:
//
//   window.HighwayGradeNative = {
//     barometer: {
//       // call `cb({ relativeAltitude, timestamp })` for each sensor sample.
//       // relativeAltitude: meters relative to when monitoring started (CMAltimeter)
//       // timestamp: epoch ms
//       subscribe(cb) { ...; return function unsubscribe() {...}; }
//     }
//   };
//
// Implement that one bridge and this source lights up automatically — no other
// app code changes. The maths below are identical in spirit to the GPS source,
// just fed a far cleaner altitude signal.

import { haversine } from "../geo.js";
import { linearSlope, clamp } from "../smoothing.js";
import { plausibleGrade } from "../grade.js";

const WINDOW_METERS = 120; // shorter than GPS — the signal is clean enough
const MIN_POINTS = 8;
const MIN_SPEED = 2.0;

function getBridge() {
  return globalThis.HighwayGradeNative?.barometer ?? null;
}

export class BarometerSource {
  constructor(locationService) {
    this.name = "barometer";
    this.label = "Barometer";
    this.loc = locationService;
    this.buffer = []; // { dist (cumulative horizontal), alt (relative baro), ts }
    this._cum = 0;
    this._speed = 0;
    this._unsubLoc = null;
    this._unsubBaro = null;
    this.status = getBridge() ? "idle" : "native only";
  }

  available() {
    return getBridge() != null;
  }

  start(emit) {
    const bridge = getBridge();
    if (!bridge) {
      this.status = "native only";
      return; // not available in this (web) environment
    }
    this._emit = emit;

    // Track horizontal distance traveled from the shared GPS feed.
    let prev = null;
    this._unsubLoc = this.loc.subscribe((fix) => {
      if (prev) this._cum += haversine(prev.lat, prev.lon, fix.lat, fix.lon);
      prev = fix;
      this._speed = fix.speed ?? 0;
    });

    // Each barometer sample is paired with the current cumulative distance.
    this._unsubBaro = bridge.subscribe(({ relativeAltitude, timestamp }) => {
      if (!Number.isFinite(relativeAltitude)) return;
      const ts = timestamp || Date.now();
      this.buffer.push({ dist: this._cum, alt: relativeAltitude, ts });

      const cutoff = this._cum - WINDOW_METERS;
      while (this.buffer.length && this.buffer[0].dist < cutoff) this.buffer.shift();

      const span = this._cum - this.buffer[0].dist;
      if (this.buffer.length < MIN_POINTS || span < WINDOW_METERS * 0.5) {
        this.status = "warming up";
        return;
      }
      if (this._speed < MIN_SPEED) {
        this.status = "too slow";
        return;
      }

      const xs = this.buffer.map((p) => p.dist);
      const ys = this.buffer.map((p) => p.alt);
      const { slope, r2, n } = linearSlope(xs, ys);
      if (!Number.isFinite(slope)) return;

      const gradePercent = plausibleGrade(slope * 100);
      const confidence = clamp(0.6 + 0.4 * r2 * clamp(n / 20, 0, 1), 0.6, 0.98);
      this.status = "ok";
      this._emit?.({ source: this.name, gradePercent, confidence, ts });
    });

    this.status = "active";
  }

  stop() {
    this._unsubLoc?.();
    this._unsubBaro?.();
    this._unsubLoc = this._unsubBaro = null;
    this.buffer = [];
    this._cum = 0;
    this.status = getBridge() ? "idle" : "native only";
  }
}
