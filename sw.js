// Minimal service worker: caches the app shell so it launches offline. The
// elevation API needs the network, but the GPS-altitude source keeps working
// offline, so the app stays useful in a tunnel or dead zone.

const CACHE = "highway-grade-v2";
const SHELL = [
  "./",
  "./index.html",
  "./app.css",
  "./manifest.webmanifest",
  "./src/main.js",
  "./src/geo.js",
  "./src/grade.js",
  "./src/smoothing.js",
  "./src/fusion.js",
  "./src/vehicle.js",
  "./src/locationService.js",
  "./src/sources/gpsAltitudeSource.js",
  "./src/sources/elevationApiSource.js",
  "./src/sources/barometerSource.js",
  "./icons/icon-192.png",
  "./icons/icon-512.png",
  "./icons/icon-180.png",
];

self.addEventListener("install", (e) => {
  e.waitUntil(
    caches.open(CACHE).then((c) => c.addAll(SHELL)).then(() => self.skipWaiting())
  );
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches
      .keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== CACHE).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

self.addEventListener("fetch", (e) => {
  const url = new URL(e.request.url);
  // Never cache the elevation API — always go to network.
  if (url.hostname.endsWith("open-meteo.com")) return;
  if (e.request.method !== "GET") return;

  // Cache-first for the app shell (same origin), falling back to network.
  e.respondWith(
    caches.match(e.request).then(
      (hit) =>
        hit ||
        fetch(e.request)
          .then((res) => {
            if (url.origin === location.origin && res.ok) {
              const copy = res.clone();
              caches.open(CACHE).then((c) => c.put(e.request, copy));
            }
            return res;
          })
          .catch(() => hit)
    )
  );
});
