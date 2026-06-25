// Combines whatever grade sources are currently producing estimates into one
// number. Each source reports a confidence (0–1); we also weight by a fixed
// trust factor per source type (barometer > elevation map > GPS altitude).
// Stale estimates decay out so a source that stops updating stops counting.

import { TimeEMA, clamp } from "./smoothing.js";
import { percentToDegrees } from "./grade.js";

const TRUST = { barometer: 1.0, elevation: 0.85, gps: 0.45 };
const STALE_MS = 9000; // estimate ignored after this long with no update

export class FusedGradeEstimator {
  constructor({ tauMs = 2200 } = {}) {
    this.latest = new Map(); // source -> { gradePercent, confidence, ts }
    this.ema = new TimeEMA(tauMs);
    this.output = {
      gradePercent: null,
      degrees: null,
      confidence: 0,
      activeSource: null,
      contributors: [],
    };
  }

  /** Feed one source estimate in. */
  update(est) {
    this.latest.set(est.source, est);
    this._recompute(est.ts);
  }

  /** Recompute using only fresh estimates (call periodically too, for staleness). */
  refresh(now = Date.now()) {
    this._recompute(now);
  }

  _recompute(now) {
    let wSum = 0;
    let gwSum = 0;
    let best = { w: -1, source: null };
    const contributors = [];

    // When the barometer is live and confident, it measures altitude change
    // directly — immune to the GPS dropouts and jumpy elevation-map readings you
    // get against steep canyon walls. So let it dominate: the other sources are
    // heavily attenuated to act only as a fallback, not to pull the number around.
    const baro = this.latest.get("barometer");
    const baroDominant = baro && now - baro.ts <= STALE_MS && baro.confidence >= 0.6;

    for (const [source, est] of this.latest) {
      if (now - est.ts > STALE_MS) continue;
      const trust = TRUST[source] ?? 0.3;
      let w = trust * clamp(est.confidence, 0, 1);
      if (baroDominant && source !== "barometer") w *= 0.15;
      if (w <= 0) continue;
      wSum += w;
      gwSum += w * est.gradePercent;
      contributors.push({ source, weight: w, gradePercent: est.gradePercent });
      if (w > best.w) best = { w, source };
    }

    if (wSum <= 0) {
      // Nothing fresh — let the displayed value go stale/blank.
      this.output = {
        gradePercent: this.output.gradePercent,
        degrees: this.output.degrees,
        confidence: 0,
        activeSource: null,
        contributors: [],
      };
      return;
    }

    const blended = gwSum / wSum;
    const smoothed = this.ema.push(blended, now);
    contributors.sort((a, b) => b.weight - a.weight);

    this.output = {
      gradePercent: smoothed,
      degrees: percentToDegrees(smoothed),
      confidence: clamp(wSum, 0, 1),
      activeSource: best.source,
      contributors,
    };
  }

  reset() {
    this.latest.clear();
    this.ema.reset();
    this.output = {
      gradePercent: null,
      degrees: null,
      confidence: 0,
      activeSource: null,
      contributors: [],
    };
  }
}
