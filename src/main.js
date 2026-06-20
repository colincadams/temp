// App controller: wires the GPS feed, the three grade sources, and the fuser to
// the big-number UI. Kept deliberately small — all the real logic lives in the
// modules so the same core can be reused inside a native shell.

import { LocationService } from "./locationService.js";
import { FusedGradeEstimator } from "./fusion.js";
import { GpsAltitudeSource } from "./sources/gpsAltitudeSource.js";
import { ElevationApiSource } from "./sources/elevationApiSource.js";
import { BarometerSource } from "./sources/barometerSource.js";
import { formatGrade } from "./grade.js";

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
  speed: $("speed"),
  gpsAcc: $("gpsAcc"),
  sourcePill: $("sourcePill"),
  sources: $("sourceStatus"),
  banner: $("banner"),
  conf: $("confBar"),
};

const state = {
  unit: localStorage.getItem("grade.unit") || "percent", // "percent" | "degrees"
  running: false,
  lastUpdateTs: 0,
  wakeLock: null,
};

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
  els.speed.textContent = Number.isFinite(sp) ? `${Math.round(sp * 2.23694)} mph` : "-- mph";
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

// ---- Boot -----------------------------------------------------------------

els.startBtn.addEventListener("click", start);
els.stopBtn.addEventListener("click", stop);
els.unitToggle.addEventListener("click", toggleUnit);
els.unitToggle.textContent = state.unit === "percent" ? "Show °" : "Show %";

if (!isSecureContext()) {
  showBanner("Heads up: GPS needs HTTPS. Host this on GitHub Pages or open via localhost.", "warn");
}

if ("serviceWorker" in navigator) {
  navigator.serviceWorker.register("./sw.js").catch(() => {});
}
