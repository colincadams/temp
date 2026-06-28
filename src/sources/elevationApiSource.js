// Grade from a public elevation model (DEM), sampled along the road you've
// ACTUALLY DRIVEN rather than along a projected bearing.
//
// The naive approach — project a point ahead/behind along the current GPS
// heading and difference the DEM — is very jumpy in canyons: a few degrees of
// heading noise swings the "ahead" point onto the canyon wall, and the DEM reads
// the wall instead of the road. Instead we keep a breadcrumb trail of where we
// physically went (which is, by definition, on the road), query the DEM at those
// points, and least-squares fit elevation vs. distance over the last ~200 m. The
// slope of that fit is the grade. The fit quality (r²) becomes the confidence,
// so when the terrain samples are inconsistent the fuser automatically trusts
// this source less.
//
// Provider: Open-Meteo Elevation API — free, no API key, CORS-enabled, accepts
// many points per request. https://open-meteo.com/en/docs/elevation-api
//
// This is the web workhorse; the native barometer is more accurate/responsive
// still and dominates when present (see fusion.js).

import { haversine } from "../geo.js";
import { linearSlope, clamp } from "../smoothing.js";
import { plausibleGrade } from "../grade.js";

const TRACK_METERS = 200; // regress the DEM over the last ~200 m of real path
const MIN_SPAN = 120; // ...but don't emit until we have at least this much
const MAX_SAMPLES = 12; // DEM points per request (kept small & even)
const MIN_MOVE_M = 40; // re-query after this much travel
const MIN_INTERVAL_MS = 6000; // ...or this much time
const MIN_SPEED = 2.5; // m/s
const ENDPOINT = "https://api.open-meteo.com/v1/elevation";

// Pick up to `max` points spread evenly by distance (GPS fixes bunch up at low
// speed; even spacing keeps the regression unbiased).
function evenByDistance(track, max) {
  if (track.length <= max) return track;
  const d0 = track[0].dist;
  const d1 = track[track.length - 1].dist;
  const step = (d1 - d0) / (max - 1);
  const out = [];
  let j = 0;
  for (let i = 0; i < max; i++) {
    const target = d0 + i * step;
    while (j < track.length - 1 && track[j].dist < target) j++;
    if (out[out.length - 1] !== track[j]) out.push(track[j]);
  }
  return out;
}

export class ElevationApiSource {
  constructor(locationService) {
    this.name = "elevation";
    this.label = "Elevation map";
    this.loc = locationService;
    this.track = []; // { lat, lon, dist (cumulative) }
    this._cum = 0;
    this._prev = null;
    this._unsub = null;
    this._inFlight = false;
    this._lastQueryDist = -Infinity;
    this._lastQueryTs = 0;
    this.status = "idle";
  }

  available() {
    return typeof fetch === "function";
  }

  start(emit) {
    this._emit = emit;
    this._unsub = this.loc.subscribe((fix) => {
      if (this._prev) this._cum += haversine(this._prev.lat, this._prev.lon, fix.lat, fix.lon);
      this._prev = fix;
      this.track.push({ lat: fix.lat, lon: fix.lon, dist: this._cum });
      const cutoff = this._cum - TRACK_METERS;
      while (this.track.length > 2 && this.track[0].dist < cutoff) this.track.shift();
      this._maybeQuery(fix);
    });
  }

  _shouldQuery(fix) {
    if (this._inFlight) return false;
    if ((fix.speed ?? 0) < MIN_SPEED) {
      this.status = "too slow";
      return false;
    }
    const span = this._cum - this.track[0].dist;
    if (span < MIN_SPAN) {
      this.status = "mapping road…";
      return false;
    }
    const movedEnough = this._cum - this._lastQueryDist >= MIN_MOVE_M;
    const timeEnough = fix.ts - this._lastQueryTs >= MIN_INTERVAL_MS;
    return movedEnough || timeEnough;
  }

  async _maybeQuery(fix) {
    if (!this._shouldQuery(fix)) return;
    this._inFlight = true;
    this._lastQueryDist = this._cum;
    this._lastQueryTs = fix.ts;

    const pts = evenByDistance(this.track, MAX_SAMPLES);
    const lats = pts.map((p) => p.lat.toFixed(6)).join(",");
    const lons = pts.map((p) => p.lon.toFixed(6)).join(",");

    try {
      const res = await fetch(`${ENDPOINT}?latitude=${lats}&longitude=${lons}`, { cache: "no-store" });
      if (!res.ok) throw new Error(`HTTP ${res.status}`);
      const data = await res.json();
      const elev = data.elevation;
      if (!Array.isArray(elev) || elev.length !== pts.length || elev.some((v) => !Number.isFinite(v))) {
        throw new Error("bad elevation response");
      }

      // Least-squares slope of elevation (m) vs. distance along the road (m).
      const xs = pts.map((p) => p.dist);
      const { slope, r2, n } = linearSlope(xs, elev);
      if (!Number.isFinite(slope)) {
        this.status = "no fit";
        return;
      }
      const gradePercent = plausibleGrade(slope * 100);

      // Confidence IS the fit quality: a clean straight line (consistent road
      // grade) scores high; scattered samples (canyon-wall noise) score low, so
      // the fuser leans on this source only when it's actually trustworthy.
      const span = this._cum - this.track[0].dist;
      const spanScore = clamp(span / TRACK_METERS, 0, 1);
      const speedScore = clamp(((fix.speed ?? 0) - MIN_SPEED) / 8, 0, 1);
      const confidence = clamp(0.15 + 0.6 * r2 * spanScore + 0.1 * speedScore, 0, 0.85);

      this.status = `fit r²=${r2.toFixed(2)} · ${n}pts`;
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
    this.track = [];
    this._cum = 0;
    this._prev = null;
    this._lastQueryDist = -Infinity;
    this.status = "idle";
  }
}
