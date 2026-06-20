// Smoothing / regression helpers used by the grade sources and the fuser.

/**
 * Exponential moving average with a time-constant. Instead of a fixed alpha we
 * derive alpha from elapsed time so the smoothing behaves consistently even
 * when sample timing is irregular (GPS fixes can jitter).
 *
 *   tauMs — how quickly old values decay. Larger = smoother but laggier.
 */
export class TimeEMA {
  constructor(tauMs = 2500) {
    this.tauMs = tauMs;
    this.value = null;
    this.lastTs = null;
  }

  reset() {
    this.value = null;
    this.lastTs = null;
  }

  push(x, ts = Date.now()) {
    if (!Number.isFinite(x)) return this.value;
    if (this.value === null) {
      this.value = x;
      this.lastTs = ts;
      return this.value;
    }
    const dt = Math.max(0, ts - this.lastTs);
    const alpha = 1 - Math.exp(-dt / this.tauMs);
    this.value += alpha * (x - this.value);
    this.lastTs = ts;
    return this.value;
  }
}

/**
 * Median of an array (robust to GPS altitude outliers). Non-mutating.
 */
export function median(arr) {
  if (!arr.length) return NaN;
  const s = [...arr].sort((a, b) => a - b);
  const m = Math.floor(s.length / 2);
  return s.length % 2 ? s[m] : (s[m - 1] + s[m]) / 2;
}

/**
 * Ordinary least-squares slope of y over x. Returns { slope, r2, n }.
 * Used to fit altitude (y) against cumulative horizontal distance (x), so the
 * slope IS the grade as a fraction (multiply by 100 for percent).
 */
export function linearSlope(xs, ys) {
  const n = xs.length;
  if (n < 2) return { slope: NaN, r2: 0, n };
  let sx = 0, sy = 0, sxx = 0, sxy = 0, syy = 0;
  for (let i = 0; i < n; i++) {
    sx += xs[i];
    sy += ys[i];
    sxx += xs[i] * xs[i];
    sxy += xs[i] * ys[i];
    syy += ys[i] * ys[i];
  }
  const denom = n * sxx - sx * sx;
  if (Math.abs(denom) < 1e-9) return { slope: NaN, r2: 0, n };
  const slope = (n * sxy - sx * sy) / denom;
  const rDenom = (n * sxx - sx * sx) * (n * syy - sy * sy);
  const r2 = rDenom > 0 ? (n * sxy - sx * sy) ** 2 / rDenom : 0;
  return { slope, r2, n };
}

export const clamp = (x, lo, hi) => Math.max(lo, Math.min(hi, x));
