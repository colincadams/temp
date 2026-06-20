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
  flatCruiseMph: 62, // comfortable all-day cruise (455 loafs here)
  flatMaxMph: 68, // don't-exceed on the level — keep margin below tire/heat limits
  minCruiseMph: 25, // floor for suggestions on steep grades
  // Fastest road speed in each gear before the engine over-revs (a ~3,500 rpm
  // sustained ceiling, well under the 455's redline). Derived from the TH425
  // ratios (1st 2.48, 2nd 1.48, 3rd/DRIVE 1.00) assuming top gear turns
  // ~2,600 rpm at 60 mph. DRIVE's real ceiling is the tire/flat limit, so it
  // uses flatMaxMph. Adjust these if your final drive (3.07 vs 3.42) or tire
  // size differs.
  gearCeilingMph: { D: 68, "2": 55, "1": 33 },
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

  // --- Recommended gear + suggested/max speed -----------------------------
  // Unifying rule: `max` is never high enough to over-rev the recommended gear,
  // so following the advice can't hurt the engine.
  //  • Climbing: hold the highest gear that isn't lugging at your actual speed;
  //    `max` is that gear's no-over-rev ceiling, so you know the fastest you can
  //    safely be in it (and never downshift above it).
  //  • Descending: pick a conservative brake-fade-safe speed, then use the
  //    lowest gear that won't over-rev at that speed for engine braking.
  let rank, suggested, max;
  if (up) {
    // Only downshift on grades steep enough that DRIVE would lug; on gentle
    // grades the 455 pulls top gear fine at any reasonable speed.
    if (!moderate) rank = 3;
    else if (s == null) rank = steep ? 1 : 2;
    else if (s >= 42) rank = 3; // DRIVE pulls fine at highway speed (~1,800+ rpm)
    else if (s >= 28) rank = 2; // hold 2nd through the mid-range, no lugging
    else rank = 1; // crawling a steep grade — LOW
    const g = GEAR_BY_RANK[rank];
    suggested = clamp(p.flatCruiseMph - 3.5 * grade, p.minCruiseMph, p.flatCruiseMph);
    max = g === "D" ? p.flatMaxMph : p.gearCeilingMph[g];
  } else if (down) {
    suggested = clamp(p.flatCruiseMph - 3 * mag, p.minCruiseMph, p.flatCruiseMph);
    max = clamp(p.flatMaxMph - 3.2 * mag, p.minCruiseMph, p.flatMaxMph);
    if (max <= p.gearCeilingMph["1"]) rank = 1;
    else if (max <= p.gearCeilingMph["2"]) rank = 2;
    else rank = 3;
  } else {
    rank = 3;
    suggested = p.flatCruiseMph;
    max = p.flatMaxMph;
  }
  const gear = GEAR_BY_RANK[rank];
  const gearLabel = p.gearNames[gear];

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
