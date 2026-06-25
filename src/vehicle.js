// Driving advisor for big, old/heavy motorhomes. The priority is protecting the
// drivetrain — above all, AVOIDING OVERHEATING on climbs — rather than making
// time. The logic is generic over a vehicle "profile" (see VEHICLES); each
// profile describes its drivetrain and a few tuning breakpoints.
//
// Shared principles, applied to whatever gears a profile has:
//   • Climb: drop out of the tall top gear(s) so the engine keeps revs up near
//     its working range instead of lugging — a lugging engine under sustained
//     load is what overheats. Also ease off the speed as the grade steepens
//     (less power demanded = less heat).
//   • Descend: let engine braking (a lower gear) hold a conservative,
//     brake-fade-safe speed instead of riding the brakes — without over-revving.
//   • `max` is never high enough to over-rev the recommended gear.
//
// Drivetrain numbers are calibrated to owner-reported data; tune any profile to
// your specific coach (axle ratio, tire size, the rpm/grade breakpoints).

import { clamp } from "./smoothing.js";

// Each profile's `gears` are ordered TALLEST → LOWEST. gears[0] is the cruise /
// top gear (overdrive if present). `ratio` is the transmission ratio for that
// selector position's top gear.
export const VEHICLES = [
  {
    id: "gmc-1976",
    name: "1976 GMC Motorhome",
    engine: "Olds 455 V8",
    transmission: "TH425 3-speed auto",
    finalDrive: 3.07,
    tireRevsPerMile: 774, // calibrated so DRIVE ≈ 2,375 rpm @ 60 (owner-reported)
    gears: [
      { id: "D", label: "DRIVE", ratio: 1.0 },
      { id: "2", label: "2nd", ratio: 1.48 },
      { id: "1", label: "LOW", ratio: 2.48 },
    ],
    flatCruiseMph: 62,
    flatMaxMph: 68,
    minCruiseMph: 25,
    climbSpeedDrop: 4.5, // mph of suggested-speed backoff per % climb
    descendSpeedDrop: 3.0,
    descendMaxDrop: 3.2,
    climbCoolGrade: 4, // start dropping gears for cooling at/above this % climb
    descendBrakeGrade: 4, // start engine-braking at/above this % descent
    climbRpmFloor: 2400, // keep climbing revs at/above this (no lugging; pump/fan up)
    climbRpmPerGrade: 0, // extra rpm floor per % of grade beyond climbCoolGrade
    torquePeakRpm: 2400, // 370 lb-ft here
    maxSustainRpm: 4200, // don't hold above this (owners run 4–4.5k on long grades)
    redlineRpm: 4800,
    tachMaxRpm: 5000,
  },
  {
    id: "ford-f53-v10",
    name: "Ford F-53 V10 (2000 Pace Arrow & similar)",
    engine: "Triton 6.8L V10",
    transmission: "4R100 4-speed auto (overdrive)",
    finalDrive: 5.38, // F-53 axle, ~20.5–22k GVWR
    tireRevsPerMile: 497, // ~235/80R22.5; OD ≈ 1,900 rpm @ 60
    gears: [
      { id: "OD", label: "OD", ratio: 0.71 },
      { id: "D", label: "D", ratio: 1.0 },
      { id: "2", label: "2nd", ratio: 1.53 },
      { id: "1", label: "LOW", ratio: 2.71 },
    ],
    flatCruiseMph: 63,
    flatMaxMph: 70,
    minCruiseMph: 28,
    climbSpeedDrop: 4.0,
    descendSpeedDrop: 3.0,
    descendMaxDrop: 3.2,
    climbCoolGrade: 3, // the V10 rule: get out of overdrive early on grades
    descendBrakeGrade: 4,
    climbRpmFloor: 2000, // base floor; mild grades stay in a tall gear...
    climbRpmPerGrade: 180, // ...steeper grades demand more revs (V10 likes to spin)
    torquePeakRpm: 3250, // 425 lb-ft here
    maxSustainRpm: 4500,
    redlineRpm: 5000,
    tachMaxRpm: 5500,
  },
];

export const DEFAULT_VEHICLE_ID = "gmc-1976";
export const getVehicle = (id) => VEHICLES.find((v) => v.id === id) || VEHICLES[0];

// Engine rpm at a road speed in a given gear (and the inverse).
const rpmPerMph = (p, gear) => (p.tireRevsPerMile / 60) * p.finalDrive * gear.ratio;
const rpmAt = (p, gear, mph) => rpmPerMph(p, gear) * mph;
const speedAtRpm = (p, gear, rpm) => rpm / rpmPerMph(p, gear);

/**
 * @param {number|null} gradePercent  +climb / -descend
 * @param {number|null} speedMph      current GPS speed, mph (null if unknown)
 * @param {{profile?: object}} [opts]
 */
export function advise(gradePercent, speedMph, opts = {}) {
  const p = opts.profile || VEHICLES[0];
  const gears = p.gears;
  const top = gears[0];
  const lowest = gears[gears.length - 1];

  const grade = Number.isFinite(gradePercent) ? gradePercent : 0;
  const s = Number.isFinite(speedMph) ? speedMph : null;
  const up = grade > 0.5;
  const down = grade < -0.5;
  const mag = Math.abs(grade);
  const steep = mag >= 6;

  let gear, suggested, max;

  if (up) {
    // Ease off as the hill steepens to cut power demand (and heat). These coaches
    // aren't driven for speed, so we back off generously.
    suggested = clamp(p.flatCruiseMph - p.climbSpeedDrop * grade, p.minCruiseMph, p.flatCruiseMph);

    if (grade < p.climbCoolGrade) {
      gear = top; // gentle climb — top gear is fine, little heat at stake
    } else {
      // Keep revs at/above the floor so the engine isn't lugging and the pump &
      // fan move: hold the TALLEST gear that still clears the floor at our
      // (current or target) speed. The floor rises with the grade so steeper
      // climbs hold proportionally higher revs.
      const floor = p.climbRpmFloor + (p.climbRpmPerGrade || 0) * Math.max(0, grade - p.climbCoolGrade);
      const atSpeed = s ?? suggested;
      gear = lowest;
      for (const g of gears) {
        if (rpmAt(p, g, atSpeed) >= floor) {
          gear = g;
          break;
        }
      }
    }
    // Fastest you should hold in this gear before revs/heat get excessive.
    max = Math.min(p.flatMaxMph, speedAtRpm(p, gear, p.maxSustainRpm));
    max = Math.max(max, suggested);
  } else if (down) {
    suggested = clamp(p.flatCruiseMph - p.descendSpeedDrop * mag, p.minCruiseMph, p.flatCruiseMph);
    max = clamp(p.flatMaxMph - p.descendMaxDrop * mag, p.minCruiseMph, p.flatMaxMph);
    if (mag < p.descendBrakeGrade) {
      gear = top; // gentle descent — brakes aren't at risk
    } else {
      // Lowest gear (most engine braking) that won't over-rev at the max speed.
      gear = top;
      for (let i = gears.length - 1; i >= 0; i--) {
        if (rpmAt(p, gears[i], max) <= p.maxSustainRpm) {
          gear = gears[i];
          break;
        }
      }
    }
  } else {
    gear = top;
    suggested = p.flatCruiseMph;
    max = p.flatMaxMph;
  }

  const estimatedRpm = Math.round(rpmAt(p, gear, s ?? suggested) / 10) * 10;
  const isDownshift = gear.id !== top.id;

  // --- Status / urgency (drives the color) --------------------------------
  let level = "ok";
  let message = `OK in ${top.label}`;

  if (s != null && s > max + 1) {
    level = "warn";
    message = down
      ? `Too fast for ${Math.round(mag)}% down — brake & hold ${gear.label}`
      : `Ease off — over ${Math.round(max)} stresses the engine`;
  } else if (down && steep) {
    level = s != null && s > suggested ? "warn" : "caution";
    message = `Steep descent — engine-brake in ${gear.label}`;
  } else if (up && isDownshift) {
    level = "caution";
    message = `${steep ? "Steep" : "Long"} climb — hold ${gear.label}, keep revs up`;
  } else if (up && s != null && s > suggested + 2) {
    level = "caution";
    message = `Ease toward ${Math.round(suggested)} to run cooler`;
  } else if (down && isDownshift) {
    level = "caution";
    message =
      s != null && s > suggested + 2
        ? `Ease off — hold ${gear.label}`
        : `Descent — hold ${gear.label} to save brakes`;
  }

  return {
    suggestedSpeedMph: Math.round(suggested),
    maxSpeedMph: Math.round(max),
    gear: gear.id,
    gearLabel: gear.label,
    estimatedRpm,
    level,
    message,
  };
}

/**
 * Structured view of a profile's breakpoints, for the settings screen.
 */
export function describeBreakpoints(p) {
  const gears = p.gears.map((g, i) => {
    const taller = i > 0 ? p.gears[i - 1] : null;
    // On a climb you'd be in this gear once the next-taller gear drops below the
    // rpm floor — i.e. below this road speed.
    const climbBelowMph = taller ? Math.round(p.climbRpmFloor / rpmPerMph(p, taller)) : null;
    const ceilingMph = Math.round(Math.min(p.flatMaxMph, p.maxSustainRpm / rpmPerMph(p, g)));
    return {
      label: g.label,
      ratio: g.ratio,
      rpmAt60: Math.round(rpmPerMph(p, g) * 60),
      climbBelowMph,
      ceilingMph,
    };
  });
  return {
    name: p.name,
    engine: p.engine,
    transmission: p.transmission,
    finalDrive: p.finalDrive,
    flatCruiseMph: p.flatCruiseMph,
    flatMaxMph: p.flatMaxMph,
    climbCoolGrade: p.climbCoolGrade,
    descendBrakeGrade: p.descendBrakeGrade,
    climbRpmFloor: p.climbRpmFloor,
    torquePeakRpm: p.torquePeakRpm,
    maxSustainRpm: p.maxSustainRpm,
    redlineRpm: p.redlineRpm,
    gears,
  };
}

/** Tachometer config derived from a profile (zones, redline, scale). */
export function tachConfig(p) {
  return {
    max: p.tachMaxRpm,
    redline: p.redlineRpm,
    torquePeak: p.torquePeakRpm,
    zones: [
      { to: p.torquePeakRpm, color: "#3b4a5a" }, // low / lugging
      { to: p.maxSustainRpm, color: "#34c759" }, // working range
      { to: p.redlineRpm, color: "#ffb020" }, // high
      { to: p.tachMaxRpm, color: "#ff453a" }, // redline
    ],
  };
}

export { rpmAt, speedAtRpm };
