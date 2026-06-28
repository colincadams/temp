// One Geolocation watcher for the whole app. Every grade source subscribes here
// rather than opening its own watch (iOS only services one well, and it keeps
// the GPS samples consistent across sources).

import { haversine, bearing } from "./geo.js";

/**
 * @typedef {Object} Fix
 * @property {number} lat
 * @property {number} lon
 * @property {number|null} altitude        GPS altitude, meters (often noisy/null)
 * @property {number} accuracy             horizontal accuracy, meters
 * @property {number|null} altitudeAccuracy vertical accuracy, meters
 * @property {number|null} speed           m/s, from GPS (may be null)
 * @property {number|null} gpsHeading      compass deg from GPS (null when slow)
 * @property {number|null} moveHeading     compass deg derived from movement
 * @property {number} ts                   epoch ms
 */

export class LocationService {
  constructor() {
    this._subs = new Set();
    this._watchId = null;
    this._last = null; // last accepted fix, for movement heading/speed
    this.lastFix = null;
    this.lastError = null;
  }

  /** @param {(fix: Fix) => void} fn */
  subscribe(fn) {
    this._subs.add(fn);
    if (this.lastFix) fn(this.lastFix);
    return () => this._subs.delete(fn);
  }

  onError(fn) {
    this._onError = fn;
  }

  start() {
    if (this._watchId != null) return;
    if (!("geolocation" in navigator)) {
      this.lastError = "Geolocation not supported on this device.";
      this._onError?.(this.lastError);
      return;
    }
    this._watchId = navigator.geolocation.watchPosition(
      (pos) => this._handle(pos),
      (err) => {
        this.lastError = err.message || "Location error";
        this._onError?.(this.lastError);
      },
      { enableHighAccuracy: true, maximumAge: 1000, timeout: 15000 }
    );
  }

  stop() {
    if (this._watchId != null) {
      navigator.geolocation.clearWatch(this._watchId);
      this._watchId = null;
    }
    this._last = null;
  }

  _handle(pos) {
    const c = pos.coords;
    const ts = pos.timestamp || Date.now();

    // Derive heading & speed from movement — more reliable than coords.heading,
    // which iOS leaves null below a few m/s and during GPS jitter.
    let moveHeading = null;
    let derivedSpeed = null;
    if (this._last) {
      const d = haversine(this._last.lat, this._last.lon, c.latitude, c.longitude);
      const dt = (ts - this._last.ts) / 1000;
      if (d > 2 && dt > 0) {
        moveHeading = bearing(this._last.lat, this._last.lon, c.latitude, c.longitude);
        derivedSpeed = d / dt;
      }
    }

    const fix = {
      lat: c.latitude,
      lon: c.longitude,
      altitude: Number.isFinite(c.altitude) ? c.altitude : null,
      accuracy: Number.isFinite(c.accuracy) ? c.accuracy : 9999,
      altitudeAccuracy: Number.isFinite(c.altitudeAccuracy)
        ? c.altitudeAccuracy
        : null,
      speed: Number.isFinite(c.speed) && c.speed >= 0 ? c.speed : derivedSpeed,
      gpsHeading: Number.isFinite(c.heading) ? c.heading : null,
      moveHeading,
      ts,
    };

    this._last = fix;
    this.lastFix = fix;
    this.lastError = null;
    for (const fn of this._subs) {
      try {
        fn(fix);
      } catch (e) {
        console.error("location subscriber error", e);
      }
    }
  }
}
