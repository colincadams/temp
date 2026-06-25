# Highway Grade

A phone app that shows the **grade (slope) of the road you're driving** as one
big number in the middle of the screen. Green/▼ when descending, red/▲ when
climbing.

It ships as a **web app** you can open on an iPhone (no App Store, no Mac), and
it's architected so it can later become a **native app** that uses the iPhone's
barometer for much higher accuracy — by implementing a single file.

> ⚠️ **Drive safely.** This is an estimate. Mount your phone; don't hold or
> stare at it while driving.

## How it estimates grade

Grade = vertical change ÷ horizontal distance (×100 for percent). There's no
public feed of "the grade of the road you're on," so the app computes it by
fusing up to three sources, weighted by confidence:

| Source | Accuracy | Works on web? | Notes |
| --- | --- | --- | --- |
| **Barometer** + GPS | **±0.2–0.5%**, fast | No (native only) | Pressure altimeter resolves ~0.1 m. Best by far. |
| **Elevation map** (DEM) | **±1–2%**, smooth | ✅ yes (primary) | Samples [Open‑Meteo](https://open-meteo.com/en/docs/elevation-api) ahead/behind you. Free, no API key. Needs signal. |
| **GPS altitude** | ±5–15%/sample | ✅ yes (fallback) | Noisy; least-squares fit over ~220 m. Works offline. |

In a browser the **elevation map** does the heavy lifting and **GPS altitude**
is the offline fallback. The fuser blends whatever is live, so adding the
barometer later just makes the same number better.

## Motorhome advisor

Pick your coach from the **vehicle selector** (the ⚙ button, on the start
screen or the bottom bar). Two profiles ship today:

| Vehicle | Drivetrain | Notes |
| --- | --- | --- |
| **1976 GMC Motorhome** | Olds 455 V8 · TH425 3-speed (`DRIVE`/`2`/`LOW`) | Lazy torque peak (~2,400 rpm); geared tall. |
| **Ford F-53 V10** (2000 Pace Arrow & similar) | Triton 6.8L V10 · 4R100 4-speed w/ overdrive (`OD`/`D`/`2`/`1`) | Models the shared F-53 chassis; the V10 wants revs (peak ~3,250). |

Below the grade, an **estimated tachometer** (SVG arc gauge with colored zones,
torque-peak marker, and a per-vehicle redline) shows the engine rpm computed
from your road speed and the recommended gear, with the **gear** in its center.
Flanking tiles show **suggested speed**, **your speed**, and **max speed**.

The climb logic is built around **avoiding overheating**. These coaches are
geared tall, so on a grade they lug easily, and a lugging engine under load is
what cooks it. It always drives conservatively (no "hot mode" to remember):

- **Climbing:** **downshift to keep revs up** so the water pump and fan shed
  heat (owners run these high up long grades), and **ease the speed down
  generously** as the grade steepens to cut power demand. The rpm floor scales
  with the grade, so mild grades hold a tall gear and steep grades rev higher.
  The **max** tile is the fastest you should hold in that gear before
  over-revving.
- **Descending:** engine-brake instead of riding the brakes — the app holds the
  lowest gear that won't over-rev at a conservative, brake-fade-safe speed.

**Settings** (⚙) shows the active vehicle's **breakpoints** — flat cruise/max,
the climb/descent grade thresholds, the rpm floor / torque peak / sustain /
redline, and a per-gear table (ratio, rpm @ 60, the climb downshift speed, and
each gear's no-over-rev ceiling) — plus the live signal-source status.

Color (the grade number, the gear, the tiles) reflects safety/heat status:
neutral → amber when a cooling downshift or ease-off is advised → red when you
should act now.

The big number's **color reflects safety status, not just incline**:

| Color | Meaning |
| --- | --- |
| Neutral | All good — hold your speed/gear |
| **Amber** | Ease off, or a downshift out of DRIVE is advised |
| **Red** (pulsing) | Slow down &/or shift down now — over the safe speed, or lugging on a climb |

These are general guidelines, not factory specs. The drivetrain numbers are
calibrated to owner-reported data. Tune any vehicle (or add your own) by editing
the `VEHICLES` array in [`src/vehicle.js`](src/vehicle.js) — cruise/max speeds,
final drive, tire revs/mile, gear ratios, and the cooling-rpm window. Watch the
on-screen tach against your real tach on a climb and nudge `tireRevsPerMile`
until they match.

## Run it on your iPhone

GPS requires HTTPS, so host the static files somewhere with TLS. Easiest is
**GitHub Pages**:

1. Push this branch to GitHub (already done if Claude pushed it).
2. Repo **Settings → Pages →** Source: *Deploy from a branch* → pick this
   branch, folder `/ (root)` → Save.
3. Open the published URL in **Safari** on your iPhone.
4. Tap **Start** and allow location access. Optionally **Share → Add to Home
   Screen** to get a full-screen, no-browser-chrome app icon.

Local testing on a computer:

```bash
python3 -m http.server 8080   # then open http://localhost:8080
```

(localhost is treated as secure, so GPS works there too.)

## Project layout

```
index.html              big-number UI
app.css                 dark, high-contrast styling
manifest.webmanifest    PWA manifest (add-to-home-screen)
sw.js                   service worker (offline app shell)
src/
  geo.js                haversine / bearing / destination point
  smoothing.js          time-based EMA, median, least-squares slope
  grade.js              %↔degrees, formatting
  locationService.js    single shared Geolocation watcher
  fusion.js             confidence-weighted blend of sources
  sources/
    gpsAltitudeSource.js     GPS-altitude grade (offline fallback)
    elevationApiSource.js    Open-Meteo DEM grade (web primary)
    barometerSource.js       barometer grade (native hook — see below)
scripts/gen-icons.mjs   regenerates the PNG icons (no deps)
```

All logic is plain ES modules with no build step, so it hosts as-is and is
reusable from a native wrapper.

## Going native (the barometer upgrade)

The recommended path is **Capacitor**, which wraps this exact web app in a
native shell — no rewrite. You then expose the barometer to the page by
implementing one bridge that `src/sources/barometerSource.js` already looks for:

```js
window.HighwayGradeNative = {
  barometer: {
    // Call cb for each altimeter sample. On iOS this is CMAltimeter's
    // relativeAltitude (meters since monitoring started).
    subscribe(cb) {
      // cb({ relativeAltitude, timestamp });  // timestamp = epoch ms
      return function unsubscribe() { /* stop the altimeter */ };
    },
  },
};
```

When that bridge exists, `BarometerSource` activates automatically and the fuser
starts trusting it above the other sources. Nothing else changes.

## Privacy

Location stays on the device. The only network call is to the Open-Meteo
elevation API, which receives coordinates near you (a point ahead and behind) to
return ground elevation. No accounts, no analytics, no storage beyond your
unit preference in `localStorage`.
