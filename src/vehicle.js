// Driving advisor for a 1976 GMC Motorhome.
//
// Drivetrain: Oldsmobile 455 V8 + TurboHydramatic TH425 — a 3-speed automatic
// front-wheel drive. So "gear" here means the selector position you should hold:
//   D (DRIVE, lets it use 3rd/top), 2 (holds 2nd), 1 (LOW, holds 1st).
//
// The priority on this coach is AVOIDING OVERHEATING on climbs. The 455 is
// geared tall (~2,375 rpm at 60 in top), so on a grade it lugs easily — and a
// lugging big-block under sustained load is what cooks it (and spikes the trans
// temp). The fix, which is also standard GMC-owner practice, is:
//   • Climb: downshift to keep the engine in/above its torque peak (~2,400 rpm)
//     so the water pump and fan spin fast enough to shed heat — owners happily
//     run 3,500–4,500 rpm up long grades. Keeping revs UP matters more than
//     keeping them low.
//   • Climb: also ease off the throttle/speed as it steepens — less power
//     demanded = less heat made. So on a steep hot grade you both slow down AND
//     hold a lower gear.
//   • Descend: let engine braking (a low gear) hold your speed instead of riding
//     the brakes; keep revs below the sustain limit.
//
// "Hot mode" (warm-weather / heavy-load) shifts everything more conservative:
// downshift sooner to keep revs higher, and back off speed more.
//
// These are general guidelines, not factory specs. The drivetrain numbers are
// calibrated to owner-reported data (3.07 final drive, ~2,375 rpm @ 60 in top,
// 370 lb-ft torque peak @ 2,400 rpm); tune the profile to your coach.

import { clamp } from "./smoothing.js";

export const GMC_1976 = {
  name: "1976 GMC Motorhome",
  engine: "Olds 455 V8",
  transmission: "TH425 3-speed auto",
  flatCruiseMph: 62, // comfortable all-day cruise (455 loafs here)
  flatMaxMph: 68, // don't-exceed on the level — margin below tire/heat limits

  // Drivetrain, calibrated so top gear ≈ 2,375 rpm @ 60 mph (owner-reported).
  finalDrive: 3.07,
  tireRevsPerMile: 774, // effective; chosen to match the 2,375 rpm @ 60 figure
  gearRatios: { D: 1.0, "2": 1.48, "1": 2.48 },

  // Cooling-oriented climb window.
  torquePeakRpm: 2400, // 370 lb-ft here — the heart of the pulling range
  coolingClimbRpm: 2000, // keep climbing revs at/above this (no lugging, fan/pump moving)
  hotWeatherRpmBump: 400, // Hot mode lifts the climb-rpm floor to ~the torque peak
  maxSustainRpm: 4200, // don't hold above this (owners run 4–4.5k on long grades)

  minCruiseMph: 25, // floor for speed suggestions on steep grades
  gearNames: { D: "DRIVE", "2": "2nd", "1": "LOW" },
};

const RANK = { D: 3, "2": 2, "1": 1 };
const GEAR_BY_RANK = { 3: "D", 2: "2", 1: "1" };
const CLIMB_COOL_GRADE = 4; // below this, heat isn't a concern — stay in DRIVE
const DESCEND_BRAKE_GRADE = 4; // below this, no engine braking needed — stay in DRIVE

// Engine rpm at a given road speed in a given gear, and the inverse.
const rpmPerMph = (p, gear) => (p.tireRevsPerMile / 60) * p.finalDrive * p.gearRatios[gear];
const rpmAt = (p, gear, mph) => rpmPerMph(p, gear) * mph;
const speedAtRpm = (p, gear, rpm) => rpm / rpmPerMph(p, gear);

/**
 * @param {number|null} gradePercent  +climb / -descend
 * @param {number|null} speedMph      current GPS speed, mph (null if unknown)
 * @param {{hot?: boolean, profile?: object}} [opts]
 * @returns {{suggestedSpeedMph:number, maxSpeedMph:number, gear:string,
 *            gearLabel:string, estimatedRpm:number, level:"ok"|"caution"|"warn",
 *            message:string}}
 */
export function advise(gradePercent, speedMph, opts = {}) {
  const { hot = false, profile: p = GMC_1976 } = opts;
  const grade = Number.isFinite(gradePercent) ? gradePercent : 0;
  const s = Number.isFinite(speedMph) ? speedMph : null;
  const up = grade > 0.5;
  const down = grade < -0.5;
  const mag = Math.abs(grade);
  const steep = mag >= 6;

  let rank, suggested, max;

  if (up) {
    // Ease off as the hill steepens to cut the power demand (and heat); Hot mode
    // backs off more.
    const speedDrop = hot ? 4.5 : 3.5;
    suggested = clamp(p.flatCruiseMph - speedDrop * grade, p.minCruiseMph, p.flatCruiseMph);

    if (grade < CLIMB_COOL_GRADE) {
      rank = 3; // gentle climb — DRIVE is fine, little heat at stake
    } else {
      // Keep revs at/above the cooling floor so the pump & fan move: hold the
      // TALLEST gear that still clears the floor at our (current or target)
      // speed. Hot mode raises the floor toward the torque peak.
      const rpmFloor = p.coolingClimbRpm + (hot ? p.hotWeatherRpmBump : 0);
      const atSpeed = s ?? suggested;
      rank = 1;
      for (const g of ["D", "2", "1"]) {
        if (rpmAt(p, g, atSpeed) >= rpmFloor) {
          rank = RANK[g];
          break;
        }
      }
    }
    const g = GEAR_BY_RANK[rank];
    // Fastest you should hold in this gear before revs/heat get excessive.
    max = Math.min(p.flatMaxMph, speedAtRpm(p, g, p.maxSustainRpm));
    max = Math.max(max, suggested);
  } else if (down) {
    // Conservative, brake-fade-safe descent speeds (the thresholds you liked).
    suggested = clamp(p.flatCruiseMph - 3 * mag, p.minCruiseMph, p.flatCruiseMph);
    max = clamp(p.flatMaxMph - 3.2 * mag, p.minCruiseMph, p.flatMaxMph);
    if (mag < DESCEND_BRAKE_GRADE) {
      rank = 3; // gentle descent — DRIVE is fine, brakes aren't at risk
    } else {
      // Lowest gear (most engine braking) that won't over-rev at the max speed.
      rank = 3;
      for (const g of ["1", "2", "D"]) {
        if (rpmAt(p, g, max) <= p.maxSustainRpm) {
          rank = RANK[g];
          break;
        }
      }
    }
  } else {
    rank = 3;
    suggested = p.flatCruiseMph;
    max = p.flatMaxMph;
  }

  const gear = GEAR_BY_RANK[rank];
  const gearLabel = p.gearNames[gear];
  const estimatedRpm = Math.round(rpmAt(p, gear, s ?? suggested) / 10) * 10;

  // --- Status / urgency (drives the color) --------------------------------
  // Red = act now (slow down &/or shift down). Amber = ease off, or a downshift
  // to run cooler is advised. Neutral = all good.
  let level = "ok";
  let message = `OK in ${gearLabel}`;

  if (s != null && s > max + 1) {
    level = "warn";
    message = down
      ? `Too fast for ${Math.round(mag)}% down — brake & hold ${gearLabel}`
      : `Ease off — over ${Math.round(max)} stresses the engine`;
  } else if (down && steep) {
    level = s != null && s > suggested ? "warn" : "caution";
    message = `Steep descent — engine-brake in ${gearLabel}`;
  } else if (up && rank < 3) {
    // A cooling downshift is advised. Hot + steep is the real overheat danger.
    level = hot && steep ? "warn" : "caution";
    const why = hot ? "to run cooler" : "keep revs up";
    message = `${steep ? "Steep" : "Long"} climb — hold ${gearLabel}, ${why}`;
  } else if (up && s != null && s > suggested + 2) {
    level = "caution";
    message = `Ease toward ${Math.round(suggested)} to run cooler`;
  } else if (down && rank < 3) {
    level = "caution";
    message =
      s != null && s > suggested + 2
        ? `Ease off — hold ${gearLabel}`
        : `Descent — hold ${gearLabel} to save brakes`;
  }

  return {
    suggestedSpeedMph: Math.round(suggested),
    maxSpeedMph: Math.round(max),
    gear,
    gearLabel,
    estimatedRpm,
    level,
    message,
  };
}

export { RANK, rpmAt, speedAtRpm };
