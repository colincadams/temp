# Building the native iPhone app (accurate grade in canyons)

The web app can't read the iPhone's **barometer** (Safari doesn't expose it). The
native build wraps the *same* app in [Capacitor](https://capacitorjs.com) and
adds a barometer plugin, so grade comes from air‑pressure altitude change —
**immune to the GPS dropouts and jumpy elevation‑map readings you get against
steep canyon walls.** Once the barometer is live, the app automatically lets it
dominate and filters the noisier sources down to a fallback.

> **You need a Mac.** Building an iOS app and loading it on your iPhone requires
> macOS + Xcode. There's no way around this for native sensor access.

## What you need

- A **Mac** with **Xcode** (from the Mac App Store).
- **Node.js 18+** (`node -v`).
- **CocoaPods**: `brew install cocoapods` (or `sudo gem install cocoapods`).
- An **iPhone 6s or newer** (all have a barometer) + a USB cable.
- An **Apple ID** — a free one works for loading onto your own phone (the app
  then expires after 7 days; see the end). A paid Apple Developer account
  ($99/yr) removes that and enables TestFlight.

## One‑time setup

```bash
# from the repo root, on the claude/iphone-highway-grade-app-slndih branch
npm install
npm run build:web          # assembles the web assets into ./www
npx cap add ios            # creates the native ios/ project + installs pods
npx cap sync ios           # copies www/ and the Geolocation plugin into iOS
npx cap open ios           # opens the project in Xcode
```

### Add the barometer plugin to the app

The barometer is a tiny in‑app native plugin (two files in `native/ios/`).

1. In Xcode's left sidebar, expand **App → App**.
2. From Finder, drag **`native/ios/BarometerPlugin.swift`** and
   **`native/ios/BarometerPlugin.m`** into that **App** group.
   - Tick **Copy items if needed**.
   - Under "Add to targets", make sure **App** is checked.
3. Xcode will ask *"Would you like to configure an Objective‑C bridging
   header?"* — click **Create Bridging Header**. (Adding the `.m` triggers this;
   the empty header it creates is fine and is what lets the registration see the
   Swift class.)

### Add the permission strings

Select the **App** target → **Info** tab, and add two rows (click the `+`):

| Key | Value (suggested) |
| --- | --- |
| `Privacy - Motion Usage Description` | `Measures road grade from the barometric altimeter.` |
| `Privacy - Location When In Use Usage Description` | `Measures your speed and position for road grade.` |

(Without the Motion string the app will crash the moment it starts the
barometer; without Location you get no GPS.)

### Sign it

Select the **App** target → **Signing & Capabilities**:

- Check **Automatically manage signing**.
- **Team**: pick your Apple ID. (Add it first via Xcode → Settings → Accounts →
  `+` → Apple ID; the free "Personal Team" works.)
- **Bundle Identifier**: change to something unique, e.g.
  `com.yourname.highwaygrade`.

## Run it on your iPhone

1. Plug in the iPhone, unlock it, tap **Trust This Computer**.
2. In Xcode's top bar, choose your iPhone as the run destination.
3. Press **▶ Run**. The first build takes a few minutes.
4. The first launch is blocked by iOS: on the phone go to **Settings → General →
   VPN & Device Management → [your Apple ID] → Trust**. Then tap the app icon
   (or press Run again).
5. In the app, tap **Start** and allow **Location** and **Motion** when asked.

### Confirm the barometer is working

Open **⚙ Settings → Signal sources**. Once you're moving, **Barometer** should
read `ok` (it needs ~100 m of travel to lock in). On a grade, the gauge's source
pill will show **Barometer** as the active source, and the reading will stay
steady where the elevation map alone would jump around.

## Install without a cord (Wi‑Fi) — free

You only need the USB cable **once**, to pair. After that, every install and every
weekly re‑sign happens over Wi‑Fi.

1. Do the first **▶ Run** above with the cable connected (this pairs the device).
2. In Xcode open **Window → Devices and Simulators** (`⇧⌘2`) → select your iPhone
   under **Devices** → tick **✔ Connect via network**.
3. Unplug the cable. Your iPhone now shows a network icon and stays available as
   a run destination as long as it's on the **same Wi‑Fi** as the Mac.
4. From now on just pick the iPhone in Xcode's destination menu and press **Run**
   — it installs over the air.

**Beating the 7‑day expiry, cordless:** with a free Apple ID the app stops
opening after a week. Just press **Run** again in Xcode (wirelessly) to renew —
re‑running is an *update*, so your settings (vehicle, units) survive. Keep the
phone unlocked and on the same network; if it doesn't appear, wake it or
re‑tick the checkbox. (A paid account makes builds last a year if the weekly
re‑run gets old.)

## After you change the code

```bash
npm run sync     # rebuild www/ + copy into iOS
# then press Run again in Xcode (over Wi-Fi once paired)
```

(`npm run ios` does build + sync + open in one step.)

## Notes & troubleshooting

- **7‑day expiry (free account):** the app stops opening after a week. Just
  re‑Run it from Xcode to renew. A paid account makes builds last a year.
- **Sources shows "Barometer: native only":** the plugin files aren't compiled
  into the app — re‑check that both files are added to the **App** target and
  that you created the bridging header.
- **No GPS / location:** make sure the Location permission string is present and
  you granted permission; `@capacitor/geolocation` must be installed (it's in
  `package.json`, pulled in by `npx cap sync`).
- **CocoaPods errors on `cap add/sync`:** install/update CocoaPods, then
  `npx cap sync ios` again.
- **Cabin pressure:** rolling windows, A/C blasts, or slamming a door briefly
  nudges the barometer; the windowed averaging rides over short blips.
- The barometer gives **vertical** change; horizontal distance still comes from
  GPS **speed** (Doppler), which stays reliable in canyons even when GPS
  *position* is bouncing — so the grade stays accurate.
```
