// Driving advisor for a 1976 GMC Motorhome.
//
// Drivetrain: Oldsmobile 455 V8 + TurboHydramatic TH425 — a 3-speed automatic
// front-wheel drive. So "gear" here means the selector position you should hold:
//   D (DRIVE, lets it use 3rd/top), 2 (holds 2nd), 1 (LOW, holds 1st).
//
// Guiding principles for an old, heavy, modestly-powered coach:
//  • Climbing: downshift so the engine stays in its torque band instead of
//    lugging in top gear; expect to lose speed on grades — that's normal.
//  • Descending: descend in the SAME gear you'd climb it. Let engine braking
//    hold your speed so you're not riding (and overheating) the brakes.
//  • The steeper the hill, the lower the gear and the lower the safe speed.
//
// These are conservative general guidelines, not factory specs — tune the
// profile below to your coach. The advice is colored by urgency so the big
// number turns amber/red when you should ease off or shift down.

import { clamp } from "./smoothing.js";

export const GMC_1976 = {
  name: "1976 GMC Motorhome",
  engine: "Olds 455 V8",
  transmission: "TH425 3-speed auto",
  flatCruiseMph: 58, // relaxed cruising speed on the level
  flatMaxMph: 63, // don't-exceed on the level
  minCruiseMph: 25, // floor for suggestions on steep grades
  gearNames: { D: "DRIVE", "2": "2nd", "1": "LOW" },
};

const RANK = { D: 3, "2": 2, "1": 1 };
const GEAR_BY_RANK = { 3: "D", 2: "2", 1: "1" };

/**
 * @param {number|null} gradePercent  +climb / -descend
 * @param {number|null} speedMph      current GPS speed, mph (null if unknown)
 * @returns {{suggestedSpeedMph:number, maxSpeedMph:number, gear:string,
 *            gearLabel:string, level:"ok"|"caution"|"warn", message:string}}
 */
export function advise(gradePercent, speedMph, p = GMC_1976) {
  const grade = Number.isFinite(gradePercent) ? gradePercent : 0;
  const s = Number.isFinite(speedMph) ? speedMph : null;
  const up = grade > 0.5;
  const down = grade < -0.5;
  const mag = Math.abs(grade);
  const moderate = mag >= 3;
  const steep = mag >= 6;

  // --- Recommended gear (selector position) -------------------------------
  // Climbing: track actual speed so we downshift as we slow (and never hold a
  // gear that over-revs at speed). Descending: grade-driven, because we WANT a
  // low gear for engine braking even before we've slowed down.
  let rank;
  if (up) {
    if (s == null) rank = steep ? 1 : moderate ? 2 : 3;
    else if (s >= 42) rank = 3; // DRIVE pulls fine at highway speed
    else if (s >= 28) rank = 2; // hold 2nd through the mid-range
    else rank = 1; // crawling a steep grade — LOW
  } else if (down) {
    rank = steep ? 1 : moderate ? 2 : 3;
  } else {
    rank = 3;
  }
  const gear = GEAR_BY_RANK[rank];
  const gearLabel = p.gearNames[gear];

  // --- Suggested & max speed ---------------------------------------------
  let suggested, max;
  if (up) {
    // Heavy + underpowered: speed falls off as the hill steepens.
    suggested = clamp(p.flatCruiseMph - 3.5 * grade, p.minCruiseMph, p.flatCruiseMph);
    max = p.flatMaxMph; // overspeed isn't the climbing risk — lugging is
  } else if (down) {
    // Safety-limited: keep to a speed engine braking can hold in `gear`.
    suggested = clamp(p.flatCruiseMph - 3 * mag, p.minCruiseMph, p.flatCruiseMph);
    max = clamp(p.flatMaxMph - 3.2 * mag, p.minCruiseMph, p.flatMaxMph);
  } else {
    suggested = p.flatCruiseMph;
    max = p.flatMaxMph;
  }

  // --- Status / urgency (drives the color) --------------------------------
  // Red = slow down &/or shift down NOW. Amber = ease off or a downshift is
  // advised. Green/neutral = all good.
  let level = "ok";
  let message = `OK in ${gearLabel}`;

  if (s != null && s > max + 1) {
    level = "warn";
    message = down
      ? `Too fast for ${Math.round(mag)}% down — brake & hold ${gearLabel}`
      : `Over safe speed — ease off`;
  } else if (down && steep) {
    const tooQuick = s != null && s > suggested;
    level = tooQuick ? "warn" : "caution";
    message = `Steep descent — engine-brake in ${gearLabel}`;
  } else if (up && steep && s != null && s < 24) {
    level = "warn";
    message = `Lugging — drop to ${gearLabel}`;
  } else if (s != null && s > suggested + 2) {
    level = "caution";
    message = down ? `Ease off — hold ${gearLabel}` : `Ease back toward ${Math.round(suggested)}`;
  } else if (rank < 3) {
    // A downshift out of DRIVE is recommended.
    level = "caution";
    message = up && steep ? `Long climb — hold ${gearLabel}` : `Hold ${gearLabel}`;
  }

  return {
    suggestedSpeedMph: Math.round(suggested),
    maxSpeedMph: Math.round(max),
    gear,
    gearLabel,
    level,
    message,
  };
}

export { RANK };
