// Driving advisor for big, old/heavy motorhomes. The priority is protecting the
// drivetrain — above all, AVOIDING OVERHEATING on climbs — rather than making
// time. The logic is generic over a vehicle "profile" (see VEHICLES).
//
// Climb strategy is a simple, truck-style STEP TABLE (`climbSteps`): for each
// band of grade, hold a specific gear and ease to a specific steady speed. This
// matches how people actually drive grades and is easy to reason about. The
// target speeds are chosen to sit the engine near its torque peak in that gear
// (revs up enough to keep the belt-driven water pump & fan moving and avoid
// lugging, but not screaming) — which is the anti-overheat sweet spot.
//
// Descents use engine braking: the lowest gear that won't over-rev at a
// conservative, brake-fade-safe speed.
//
// Numbers are calibrated to owner-reported data; tune any profile to your coach.

import { clamp } from "./smoothing.js";

// `gears` are ordered TALLEST → LOWEST. gears[0] is the cruise / top gear.
// `climbSteps` are ordered gentlest → steepest; the first whose `upToGrade` is
// >= the current grade wins. `speed` is the steady target mph for that band.
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
    climbSteps: [
      { upToGrade: 3, gear: "D", speed: 62 }, // 0–3%: hold DRIVE at cruise
      { upToGrade: 7, gear: "2", speed: 40 }, // 3–7%: 2nd, ease to ~40 (~2,350 rpm)
      { upToGrade: 99, gear: "1", speed: 25 }, // 7%+: LOW, ease to ~25 (~2,450 rpm)
    ],
    descendSpeedDrop: 3.0,
    descendMaxDrop: 3.2,
    descendBrakeGrade: 4, // start engine-braking at/above this % descent
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
    climbSteps: [
      { upToGrade: 2, gear: "OD", speed: 63 }, // 0–2%: hold overdrive at cruise
      { upToGrade: 4, gear: "D", speed: 55 }, // 2–4%: out of OD into 3rd (~2,450 rpm)
      { upToGrade: 7, gear: "2", speed: 45 }, // 4–7%: 2nd, ease to ~45 (~3,070 rpm)
      { upToGrade: 99, gear: "1", speed: 28 }, // 7%+: LOW, ease to ~28 (~3,380 rpm)
    ],
    descendSpeedDrop: 3.0,
    descendMaxDrop: 3.2,
    descendBrakeGrade: 4,
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
const gearById = (p, id) => p.gears.find((g) => g.id === id) || p.gears[0];

/**
 * @param {number|null} gradePercent  +climb / -descend
 * @param {number|null} speedMph      current GPS speed, mph (null if unknown)
 * @param {{profile?: object}} [opts]
 */
export function advise(gradePercent, speedMph, opts = {}) {
  const p = opts.profile || VEHICLES[0];
  const gears = p.gears;
  const top = gears[0];

  const grade = Number.isFinite(gradePercent) ? gradePercent : 0;
  const s = Number.isFinite(speedMph) ? speedMph : null;
  const up = grade > 0.5;
  const down = grade < -0.5;
  const mag = Math.abs(grade);
  const steep = mag >= 6;

  let gear, suggested, max;

  if (up) {
    // Step table: pick the band for this grade -> gear + steady target speed.
    const step = p.climbSteps.find((st) => grade <= st.upToGrade) || p.climbSteps[p.climbSteps.length - 1];
    gear = gearById(p, step.gear);
    suggested = step.speed;
    // Max = fastest you can hold this gear before over-revving.
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
    message = `${steep ? "Steep" : "Long"} climb — hold ${gear.label}, ease to ${suggested}`;
  } else if (up && s != null && s > suggested + 2) {
    level = "caution";
    message = `Ease toward ${suggested} to run cooler`;
  } else if (down && isDownshift) {
    level = "caution";
    message =
      s != null && s > suggested + 2
        ? `Ease off — hold ${gear.label}`
        : `Descent — hold ${gear.label} to save brakes`;
  }

  // Heat nudge on sustained climbs (we can't read coolant temp, so prompt).
  const hint = up && isDownshift ? "Sustained climb — ease off further if the temp gauge climbs." : null;

  return {
    suggestedSpeedMph: Math.round(suggested),
    maxSpeedMph: Math.round(max),
    gear: gear.id,
    gearLabel: gear.label,
    estimatedRpm,
    level,
    message,
    hint,
  };
}

/**
 * Structured view of a profile's rules, for the settings screen.
 */
export function describeBreakpoints(p) {
  let from = 0;
  const climb = p.climbSteps.map((st) => {
    const g = gearById(p, st.gear);
    const band = st.upToGrade >= 99 ? `${from}%+` : `${from}–${st.upToGrade}%`;
    from = st.upToGrade;
    return {
      band,
      gearLabel: g.label,
      speed: st.speed,
      rpm: Math.round(rpmAt(p, g, st.speed) / 10) * 10,
    };
  });
  const gears = p.gears.map((g) => ({
    label: g.label,
    ratio: g.ratio,
    rpmAt60: Math.round(rpmPerMph(p, g) * 60),
    ceilingMph: Math.round(Math.min(p.flatMaxMph, p.maxSustainRpm / rpmPerMph(p, g))),
  }));
  return {
    name: p.name,
    engine: p.engine,
    transmission: p.transmission,
    finalDrive: p.finalDrive,
    flatCruiseMph: p.flatCruiseMph,
    flatMaxMph: p.flatMaxMph,
    descendBrakeGrade: p.descendBrakeGrade,
    torquePeakRpm: p.torquePeakRpm,
    maxSustainRpm: p.maxSustainRpm,
    redlineRpm: p.redlineRpm,
    climb,
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
