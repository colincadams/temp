// Geographic math helpers. Pure functions, no side effects — easy to reuse
// from a native (Capacitor) shell later.

const R_EARTH = 6371008.8; // mean Earth radius, meters

export const toRad = (deg) => (deg * Math.PI) / 180;
export const toDeg = (rad) => (rad * 180) / Math.PI;

/**
 * Great-circle distance between two lat/lon points, in meters.
 */
export function haversine(lat1, lon1, lat2, lon2) {
  const dLat = toRad(lat2 - lat1);
  const dLon = toRad(lon2 - lon1);
  const a =
    Math.sin(dLat / 2) ** 2 +
    Math.cos(toRad(lat1)) * Math.cos(toRad(lat2)) * Math.sin(dLon / 2) ** 2;
  return 2 * R_EARTH * Math.asin(Math.min(1, Math.sqrt(a)));
}

/**
 * Initial bearing (compass degrees, 0 = north) from point 1 to point 2.
 */
export function bearing(lat1, lon1, lat2, lon2) {
  const φ1 = toRad(lat1);
  const φ2 = toRad(lat2);
  const Δλ = toRad(lon2 - lon1);
  const y = Math.sin(Δλ) * Math.cos(φ2);
  const x =
    Math.cos(φ1) * Math.sin(φ2) -
    Math.sin(φ1) * Math.cos(φ2) * Math.cos(Δλ);
  return (toDeg(Math.atan2(y, x)) + 360) % 360;
}

/**
 * Point reached by traveling `dist` meters from (lat, lon) along `brng` degrees.
 * Returns { lat, lon }.
 */
export function destinationPoint(lat, lon, brng, dist) {
  const δ = dist / R_EARTH;
  const θ = toRad(brng);
  const φ1 = toRad(lat);
  const λ1 = toRad(lon);

  const sinφ2 =
    Math.sin(φ1) * Math.cos(δ) + Math.cos(φ1) * Math.sin(δ) * Math.cos(θ);
  const φ2 = Math.asin(sinφ2);
  const y = Math.sin(θ) * Math.sin(δ) * Math.cos(φ1);
  const x = Math.cos(δ) - Math.sin(φ1) * sinφ2;
  const λ2 = λ1 + Math.atan2(y, x);

  return {
    lat: toDeg(φ2),
    lon: (((toDeg(λ2) + 540) % 360) - 180), // normalize to -180..180
  };
}
