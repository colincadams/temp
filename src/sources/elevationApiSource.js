// Grade from a public elevation model (DEM). We sample the terrain a little
// ahead of and behind the car along the direction of travel and take the slope
// between them. Absolute DEM error is several meters, but those errors are
// spatially correlated, so the *difference* over a short baseline is a good
// grade estimate (~±1–2%) — and it's smooth and immune to cabin air pressure.
//
// Provider: Open-Meteo Elevation API — free, no API key, CORS-enabled.
//   https://open-meteo.com/en/docs/elevation-api
// The DEM is ~90 m resolution, so we use a baseline well above that.

import { destinationPoint } from "../geo.js";
import { effectiveHeading } from "../locationService.js";
import { clamp } from "../smoothing.js";
import { plausibleGrade } from "../grade.js";

const HALF_BASELINE = 90; // meters ahead and behind -> 180 m total
const MIN_MOVE_M = 45; // re-query after this much travel
const MIN_INTERVAL_MS = 7000; // ...or this much time
const MIN_SPEED = 2.5; // m/s
const ENDPOINT = "https://api.open-meteo.com/v1/elevation";

export class ElevationApiSource {
  constructor(locationService) {
    this.name = "elevation";
    this.label = "Elevation map";
    this.loc = locationService;
    this._unsub = null;
    this._inFlight = false;
    this._lastQueryFix = null;
    this._lastQueryTs = 0;
    this.status = "idle";
  }

  available() {
    return typeof fetch === "function";
  }

  start(emit) {
    this._emit = emit;
    this._unsub = this.loc.subscribe((fix) => this._maybeQuery(fix));
  }

  _shouldQuery(fix) {
    if (this._inFlight) return false;
    const heading = effectiveHeading(fix);
    if (heading == null) {
      this.status = "need heading (drive straight)";
      return false;
    }
    if ((fix.speed ?? 0) < MIN_SPEED) {
      this.status = "too slow";
      return false;
    }
    if (!this._lastQueryFix) return true;
    const dt = fix.ts - this._lastQueryTs;
    const moved = Math.hypot(
      (fix.lat - this._lastQueryFix.lat) * 111320,
      (fix.lon - this._lastQueryFix.lon) * 111320 * Math.cos((fix.lat * Math.PI) / 180)
    );
    return moved >= MIN_MOVE_M || dt >= MIN_INTERVAL_MS;
  }

  async _maybeQuery(fix) {
    if (!this._shouldQuery(fix)) return;
    const heading = effectiveHeading(fix);
    this._inFlight = true;
    this._lastQueryFix = fix;
    this._lastQueryTs = fix.ts;

    const behind = destinationPoint(fix.lat, fix.lon, heading, -HALF_BASELINE);
    const ahead = destinationPoint(fix.lat, fix.lon, heading, HALF_BASELINE);
    const lats = [behind.lat, fix.lat, ahead.lat].map((v) => v.toFixed(6)).join(",");
    const lons = [behind.lon, fix.lon, ahead.lon].map((v) => v.toFixed(6)).join(",");

    try {
      const res = await fetch(`${ENDPOINT}?latitude=${lats}&longitude=${lons}`, {
        cache: "no-store",
      });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const e = data.elevation;
      if (!Array.isArray(e) || e.length < 3 || e.some((v) => !Number.isFinite(v))) {
        throw new Error("bad elevation response");
      }
      // Rise over the full baseline, in the direction of travel.
      const gradePercent = plausibleGrade(((e[2] - e[0]) / (2 * HALF_BASELINE)) * 100);

      // Confidence is high but eased down at low speed / when heading is only
      // GPS-reported (less stable than movement-derived).
      const speedScore = clamp(((fix.speed ?? 0) - MIN_SPEED) / 8, 0, 1);
      const headingScore = fix.moveHeading != null ? 1 : 0.6;
      const confidence = clamp(0.55 + 0.35 * speedScore * headingScore, 0, 0.9);

      this.status = "ok";
      this._emit?.({ source: this.name, gradePercent, confidence, ts: fix.ts });
    } catch (err) {
      this.status = navigator.onLine ? `error: ${err.message}` : "offline";
    } finally {
      this._inFlight = false;
    }
  }

  stop() {
    this._unsub?.();
    this._unsub = null;
    this._lastQueryFix = null;
    this.status = "idle";
  }
}
