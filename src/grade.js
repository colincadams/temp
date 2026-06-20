// Grade unit conversions and formatting. A "grade" of 5% means 5 m of rise per
// 100 m of horizontal travel.

import { toDeg, toRad } from "./geo.js";
import { clamp } from "./smoothing.js";

/** percent grade (rise/run * 100) -> angle in degrees */
export const percentToDegrees = (pct) => toDeg(Math.atan(pct / 100));

/** angle in degrees -> percent grade */
export const degreesToPercent = (deg) => Math.tan(toRad(deg)) * 100;

/**
 * Highways essentially never exceed ~10–12% sustained; clamp to a sane band so a
 * single bad sample can't throw a wild number on screen.
 */
export const plausibleGrade = (pct) => clamp(pct, -25, 25);

/**
 * Format a grade for the big display. Returns { magnitude, sign, arrow }.
 *   unit: "percent" | "degrees"
 */
export function formatGrade(pct, unit = "percent") {
  if (pct == null || !Number.isFinite(pct)) {
    return { magnitude: "--", sign: "", arrow: "•", direction: "flat" };
  }
  const value = unit === "degrees" ? percentToDegrees(pct) : pct;
  const abs = Math.abs(value);
  const magnitude = abs < 10 ? abs.toFixed(1) : abs.toFixed(0);

  let direction = "flat";
  let arrow = "•";
  if (pct >= 0.4) {
    direction = "up";
    arrow = "▲";
  } else if (pct <= -0.4) {
    direction = "down";
    arrow = "▼";
  }
  const sign = direction === "up" ? "+" : direction === "down" ? "−" : "";
  return { magnitude, sign, arrow, direction };
}
