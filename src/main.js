// App controller: wires the GPS feed, the three grade sources, and the fuser to
// the big-number UI. Kept deliberately small — all the real logic lives in the
// modules so the same core can be reused inside a native shell.

import { LocationService } from "./locationService.js";
import { FusedGradeEstimator } from "./fusion.js";
import { GpsAltitudeSource } from "./sources/gpsAltitudeSource.js";
import { ElevationApiSource } from "./sources/elevationApiSource.js";
import { BarometerSource } from "./sources/barometerSource.js";
import { formatGrade } from "./grade.js";
import {
  advise,
  VEHICLES,
  getVehicle,
  DEFAULT_VEHICLE_ID,
  describeBreakpoints,
  tachConfig,
} from "./vehicle.js";
import { createTachometer } from "./tach.js";

const $ = (id) => document.getElementById(id);
const els = {
  big: $("magnitude"),
  sign: $("sign"),
  arrow: $("arrow"),
  unit: $("unitLabel"),
  display: $("display"),
  overlay: $("overlay"),
  startBtn: $("startBtn"),
  stopBtn: $("stopBtn"),
  unitToggle: $("unitToggle"),
  speedVal: $("speedVal"),
  gpsAcc: $("gpsAcc"),
  sourcePill: $("sourcePill"),
  sources: $("sourceStatus"),
  banner: $("banner"),
  conf: $("confBar"),
  statusMsg: $("statusMsg"),
  advice: $("advice"),
  suggestedVal: $("suggestedVal"),
  maxVal: $("maxVal"),
  // Settings
  settings: $("settings"),
  settingsBtn: $("settingsBtn"),
  overlaySettingsBtn: $("overlaySettingsBtn"),
  settingsClose: $("settingsClose"),
  vehicleSelect: $("vehicleSelect"),
  vehicleSpec: $("vehicleSpec"),
  vehicleName: $("vehicleName"),
  overlayVehicle: $("overlayVehicle"),
  breakpoints: $("breakpoints"),
};

const STATUS_COLOR = { ok: "#f4f7fb", caution: "#ffb020", warn: "#ff453a" };

const state = {
  unit: localStorage.getItem("grade.unit") || "percent", // "percent" | "degrees"
  vehicleId: localStorage.getItem("grade.vehicle") || DEFAULT_VEHICLE_ID,
  running: false,
  lastUpdateTs: 0,
  wakeLock: null,
};

let profile = getVehicle(state.vehicleId);
let tach = createTachometer($("tach"), tachConfig(profile));

const loc = new LocationService();
const fuser = new FusedGradeEstimator();
const sources = [
  new BarometerSource(loc), // native-only; ignored gracefully in the browser
  new ElevationApiSource(loc),
  new GpsAltitudeSource(loc),
];

loc.onError((msg) => showBanner(msg, "warn"));

function showBanner(msg, kind = "info") {
  if (!msg) {
    els.banner.hidden = true;
    return;
  }
  els.banner.hidden = false;
  els.banner.textContent = msg;
  els.banner.className = `banner ${kind}`;
}

// ---- Start / stop ---------------------------------------------------------

async function start() {
  if (state.running) return;
  if (!isSecureContext()) {
    showBanner("Open this page over HTTPS (or localhost). GPS is blocked otherwise.", "warn");
    return;
  }
  state.running = true;
  els.overlay.hidden = true;
  showBanner(null);

  loc.start();
  fuser.reset();
  for (const s of sources) {
    if (s.available?.() === false && s.name !== "barometer") continue;
    s.start((est) => {
      state.lastUpdateTs = Date.now();
      fuser.update(est);
    });
  }
  await requestWakeLock();
  if (!renderTimer) renderTimer = setInterval(render, 250);
  render();
}

function stop() {
  state.running = false;
  for (const s of sources) s.stop?.();
  loc.stop();
  releaseWakeLock();
  els.overlay.hidden = false;
}

// ---- Wake lock (keep the screen on while driving) -------------------------

async function requestWakeLock() {
  try {
    if ("wakeLock" in navigator) {
      state.wakeLock = await navigator.wakeLock.request("screen");
      state.wakeLock.addEventListener?.("release", () => {});
    }
  } catch {
    /* Safari may reject if not user-initiated or low battery; non-fatal. */
  }
}
function releaseWakeLock() {
  try {
    state.wakeLock?.release();
  } catch {}
  state.wakeLock = null;
}
document.addEventListener("visibilitychange", () => {
  if (state.running && document.visibilityState === "visible") requestWakeLock();
});

// ---- Rendering ------------------------------------------------------------

let renderTimer = null;

function render() {
  const now = Date.now();
  fuser.refresh(now);
  const out = fuser.output;
  const fresh = now - state.lastUpdateTs < 9000 && out.confidence > 0;

  const f = formatGrade(fresh ? out.gradePercent : null, state.unit);
  els.big.textContent = f.magnitude;
  els.sign.textContent = f.sign;
  els.arrow.textContent = f.arrow;
  els.unit.textContent = state.unit === "degrees" ? "°" : "%";
  els.display.dataset.direction = f.direction;

  els.conf.style.width = `${Math.round((fresh ? out.confidence : 0) * 100)}%`;

  // Secondary readouts.
  const sp = loc.lastFix?.speed;
  const speedMph = Number.isFinite(sp) ? sp * 2.23694 : null;
  els.speedVal.textContent = speedMph != null ? Math.round(speedMph) : "--";

  // --- Motorhome speed/gear advisor + safety-status coloring ---
  if (fresh && out.gradePercent != null) {
    const a = advise(out.gradePercent, speedMph, { profile });
    els.display.dataset.status = a.level;
    els.advice.dataset.status = a.level;
    els.statusMsg.textContent = a.message;
    els.suggestedVal.textContent = a.suggestedSpeedMph;
    els.maxVal.textContent = a.maxSpeedMph;
    tach.update(a.estimatedRpm, { gear: a.gear, color: STATUS_COLOR[a.level] });
  } else {
    els.display.dataset.status = "ok";
    els.advice.dataset.status = "ok";
    els.statusMsg.textContent = state.running ? "Acquiring grade…" : "Tap start to begin";
    els.suggestedVal.textContent = "--";
    els.maxVal.textContent = "--";
    tach.update(NaN);
  }
  const acc = loc.lastFix?.accuracy;
  els.gpsAcc.textContent = Number.isFinite(acc) && acc < 9999 ? `±${Math.round(acc)} m` : "no GPS";

  const active = sources.find((s) => s.name === out.activeSource);
  els.sourcePill.textContent = fresh && active ? active.label : "acquiring…";
  els.sourcePill.dataset.active = String(fresh);

  els.sources.innerHTML = sources
    .map((s) => {
      const live = out.contributors.find((c) => c.source === s.name);
      const cls = live ? "live" : s.available?.() === false ? "off" : "idle";
      return `<li class="${cls}"><span>${s.label}</span><span>${s.status}</span></li>`;
    })
    .join("");
}

// ---- Units toggle ---------------------------------------------------------

function toggleUnit() {
  state.unit = state.unit === "percent" ? "degrees" : "percent";
  localStorage.setItem("grade.unit", state.unit);
  els.unitToggle.textContent = state.unit === "percent" ? "Show °" : "Show %";
  render();
}

function isSecureContext() {
  return window.isSecureContext || location.hostname === "localhost";
}

// ---- Vehicle + settings ---------------------------------------------------

function applyVehicle(id) {
  state.vehicleId = id;
  localStorage.setItem("grade.vehicle", id);
  profile = getVehicle(id);
  // Rebuild the tach for this vehicle's redline / zones / scale.
  tach = createTachometer($("tach"), tachConfig(profile));
  els.vehicleName.textContent = profile.name.split(" (")[0];
  els.overlayVehicle.textContent = `${profile.name} · tap ⚙ to change`;
  renderBreakpoints();
  render();
}

function renderBreakpoints() {
  const b = describeBreakpoints(profile);
  els.vehicleSpec.textContent = `${b.engine} · ${b.transmission} · ${b.finalDrive}:1 axle`;

  const rows = b.gears
    .map(
      (g) => `<tr>
        <td>${g.label}</td>
        <td>${g.ratio.toFixed(2)}</td>
        <td>${g.rpmAt60.toLocaleString()}</td>
        <td>${g.climbBelowMph ? "&lt; " + g.climbBelowMph : "cruise"}</td>
        <td>${g.ceilingMph}</td>
      </tr>`
    )
    .join("");

  els.breakpoints.innerHTML = `
    <dl class="bp-list">
      <div><dt>Cruise / max (flat)</dt><dd>${b.flatCruiseMph} / ${b.flatMaxMph} mph</dd></div>
      <div><dt>Downshift to climb at</dt><dd>≥ ${b.climbCoolGrade}% grade</dd></div>
      <div><dt>Engine-brake descents at</dt><dd>≥ ${b.descendBrakeGrade}% grade</dd></div>
      <div><dt>Climb rpm floor</dt><dd>${b.climbRpmFloor.toLocaleString()} rpm</dd></div>
      <div><dt>Torque peak</dt><dd>${b.torquePeakRpm.toLocaleString()} rpm</dd></div>
      <div><dt>Max sustained rpm</dt><dd>${b.maxSustainRpm.toLocaleString()} rpm</dd></div>
      <div><dt>Redline (gauge)</dt><dd>${b.redlineRpm.toLocaleString()} rpm</dd></div>
    </dl>
    <table class="bp-table">
      <thead><tr><th>Gear</th><th>Ratio</th><th>rpm@60</th><th>Climb</th><th>Max</th></tr></thead>
      <tbody>${rows}</tbody>
    </table>
    <p class="hint">“Climb” = hold this gear below that speed on a grade. “Max” = fastest in this gear without over-revving.</p>`;
}

function openSettings() {
  els.settings.hidden = false;
}
function closeSettings() {
  els.settings.hidden = true;
}

function initSettings() {
  els.vehicleSelect.innerHTML = VEHICLES.map(
    (v) => `<option value="${v.id}">${v.name}</option>`
  ).join("");
  els.vehicleSelect.value = state.vehicleId;
  els.vehicleSelect.addEventListener("change", (e) => applyVehicle(e.target.value));
  els.settingsBtn.addEventListener("click", openSettings);
  els.overlaySettingsBtn.addEventListener("click", openSettings);
  els.settingsClose.addEventListener("click", closeSettings);
}

// ---- Boot -----------------------------------------------------------------

els.startBtn.addEventListener("click", start);
els.stopBtn.addEventListener("click", stop);
els.unitToggle.addEventListener("click", toggleUnit);
els.unitToggle.textContent = state.unit === "percent" ? "Show °" : "Show %";

initSettings();
applyVehicle(state.vehicleId);

if (!isSecureContext()) {
  showBanner("Heads up: GPS needs HTTPS. Host this on GitHub Pages or open via localhost.", "warn");
}

if ("serviceWorker" in navigator) {
  // Auto-reload once when a new version takes over, so updates apply on a single
  // refresh instead of needing a second one.
  let reloading = false;
  navigator.serviceWorker.addEventListener("controllerchange", () => {
    if (reloading) return;
    reloading = true;
    location.reload();
  });
  navigator.serviceWorker.register("./sw.js").then((reg) => {
    // Check for a newer service worker each time the app is opened.
    reg.update().catch(() => {});
  }).catch(() => {});
}
