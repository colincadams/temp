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

## Motorhome advisor (1976 GMC)

Below the grade, three tiles show **suggested speed**, **max speed**, and the
**gear** (selector position) for a 1976 GMC Motorhome — Olds 455 V8 with the
TH425 3-speed automatic, so gear is `DRIVE`, `2`, or `LOW`. The guidance follows
old-coach mountain-driving practice:

- **Climbing:** downshift as you slow so the engine stays in its torque band
  instead of lugging; expect to give up speed on grades. Uphill, the **max** tile
  shows the fastest you can safely run in the recommended gear *without
  over-revving* (DRIVE ≈ tire/flat limit, 2nd ≈ 55, LOW ≈ 33) — so you never drop
  a gear at too high a speed.
- **Descending:** let engine braking hold your speed instead of riding the
  brakes. The app picks the lowest gear that won't over-rev at a conservative,
  brake-fade-safe speed (2nd on most grades, LOW on the steepest), and the
  **max** tile is that safe speed. Net rule: following `max` never over-revs the
  recommended gear.

The big number's **color reflects safety status, not just incline**:

| Color | Meaning |
| --- | --- |
| Neutral | All good — hold your speed/gear |
| **Amber** | Ease off, or a downshift out of DRIVE is advised |
| **Red** (pulsing) | Slow down &/or shift down now — over the safe speed, or lugging on a climb |

These are conservative general guidelines, not factory specs. Tune them to your
coach by editing the `GMC_1976` profile in [`src/vehicle.js`](src/vehicle.js)
(cruise/max speeds, gear names, thresholds).

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
