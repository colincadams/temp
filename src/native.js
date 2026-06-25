// Native bridge — only does anything inside the Capacitor iOS app. On the plain
// web (no Capacitor) every block below early-returns, so this file is safe to
// ship in both builds.
//
// It does two jobs in the native app:
//   1. Polyfills navigator.geolocation using @capacitor/geolocation, because the
//      iOS WKWebView does NOT provide the web Geolocation API. This keeps
//      locationService.js (which calls navigator.geolocation) unchanged.
//   2. Exposes window.HighwayGradeNative.barometer, the bridge that
//      src/sources/barometerSource.js reads, backed by the native Barometer
//      plugin (CMAltimeter). This is what gives accurate grade in canyons.
(function () {
  const Cap = globalThis.Capacitor;
  if (!Cap || typeof Cap.isNativePlatform !== "function" || !Cap.isNativePlatform()) {
    return; // plain web — leave navigator.geolocation and the bridge alone
  }

  const plugin = (name) =>
    typeof Cap.registerPlugin === "function"
      ? Cap.registerPlugin(name)
      : (Cap.Plugins || {})[name];

  // --- 1. Geolocation polyfill ---------------------------------------------
  const Geo = plugin("Geolocation");
  if (Geo) {
    Geo.requestPermissions?.().catch(() => {});
    let nextId = 1;
    const watches = new Map(); // our numeric id -> pending native watch id

    navigator.geolocation = {
      getCurrentPosition(success, error, options) {
        Geo.getCurrentPosition(options || { enableHighAccuracy: true })
          .then(success)
          .catch(error || (() => {}));
      },
      watchPosition(success, error, options) {
        const id = nextId++;
        const pending = Geo.watchPosition(
          options || { enableHighAccuracy: true, timeout: 15000 },
          (pos, err) => {
            if (err) error && error(err);
            else if (pos) success(pos); // Capacitor's position shape matches the web's
          }
        );
        watches.set(id, pending);
        return id;
      },
      clearWatch(id) {
        const pending = watches.get(id);
        if (!pending) return;
        watches.delete(id);
        Promise.resolve(pending)
          .then((nativeId) => Geo.clearWatch({ id: nativeId?.id ?? nativeId }))
          .catch(() => {});
      },
    };
  }

  // --- 2. Barometer bridge -------------------------------------------------
  const Baro = plugin("Barometer");
  if (Baro) {
    globalThis.HighwayGradeNative = {
      barometer: {
        // barometerSource.js calls this with a callback for each sample.
        subscribe(cb) {
          let listener = null;
          Baro.start().catch(() => {});
          const pending = Baro.addListener("reading", (ev) => {
            cb({ relativeAltitude: ev.relativeAltitude, timestamp: ev.timestamp });
          });
          Promise.resolve(pending).then((h) => {
            listener = h;
          });
          return function unsubscribe() {
            try {
              listener && listener.remove();
            } catch (e) {
              /* ignore */
            }
            Baro.stop().catch(() => {});
          };
        },
      },
    };
  }
})();
