/*
 * Piece detection: finds separate objects lying on a plain background.
 *
 * 1. Estimate the background colour from the image border.
 * 2. Mark pixels whose colour differs from it (threshold picked with Otsu's method).
 * 3. Clean the mask up with a morphological close + open.
 * 4. Label connected blobs; each blob is one piece.
 *
 * Works in the browser (window.Segment) and in Node (module.exports).
 */
(function (root, factory) {
  if (typeof module === 'object' && module.exports) module.exports = factory();
  else root.Segment = factory();
})(typeof self !== 'undefined' ? self : this, function () {
  'use strict';

  const LUT = new Float32Array(256);
  for (let i = 0; i < 256; i++) { const c = i / 255; LUT[i] = c <= 0.04045 ? c / 12.92 : Math.pow((c + 0.055) / 1.055, 2.4); }
  const f = (t) => (t > 0.008856 ? Math.cbrt(t) : 7.787 * t + 16 / 116);

  function toLab(data, n) {
    const L = new Float32Array(n), A = new Float32Array(n), B = new Float32Array(n);
    for (let i = 0, j = 0; i < n; i++, j += 4) {
      const r = LUT[data[j]], g = LUT[data[j + 1]], b = LUT[data[j + 2]];
      const fx = f((0.4124 * r + 0.3576 * g + 0.1805 * b) / 0.95047);
      const fy = f(0.2126 * r + 0.7152 * g + 0.0722 * b);
      const fz = f((0.0193 * r + 0.1192 * g + 0.9505 * b) / 1.08883);
      L[i] = 116 * fy - 16; A[i] = 500 * (fx - fy); B[i] = 200 * (fy - fz);
    }
    return { L, A, B };
  }

  function median(arr) {
    const s = Float32Array.from(arr).sort();
    return s.length ? s[s.length >> 1] : 0;
  }

  function otsu(dist, maxVal) {
    const bins = 128, hist = new Float64Array(bins), n = dist.length;
    for (let i = 0; i < n; i++) hist[Math.min(bins - 1, (dist[i] / maxVal * bins) | 0)]++;
    let sum = 0;
    for (let i = 0; i < bins; i++) sum += i * hist[i];
    let wB = 0, sumB = 0, best = 0, bestT = 0;
    for (let t = 0; t < bins; t++) {
      wB += hist[t];
      if (!wB) continue;
      const wF = n - wB;
      if (!wF) break;
      sumB += t * hist[t];
      const d = sumB / wB - (sum - sumB) / wF;
      const v = wB * wF * d * d;
      if (v > best) { best = v; bestT = t; }
    }
    return (bestT + 1) / bins * maxVal;
  }

  function morph(mask, w, h, dilate) {
    const out = new Uint8Array(mask.length);
    for (let y = 0; y < h; y++) {
      for (let x = 0; x < w; x++) {
        let v = dilate ? 0 : 1;
        for (let dy = -1; dy <= 1 && v !== (dilate ? 1 : 0); dy++) {
          const yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (let dx = -1; dx <= 1; dx++) {
            const xx = x + dx;
            if (xx < 0 || xx >= w) continue;
            if (mask[yy * w + xx] === (dilate ? 1 : 0)) { v = dilate ? 1 : 0; break; }
          }
        }
        out[y * w + x] = v;
      }
    }
    return out;
  }

  /**
   * @param {Uint8ClampedArray|Uint8Array} data RGBA pixels
   * @param {number} w
   * @param {number} h
   * @param {{sensitivity?: number, minAreaFrac?: number}} [opts] sensitivity 0..1 (higher finds fainter pieces)
   * @returns {{x:number,y:number,w:number,h:number,area:number,rgb:number[]}[]} boxes in pixels, largest first
   */
  function findPieces(data, w, h, opts) {
    const { sensitivity = 0.5, minAreaFrac = 0.0006 } = opts || {};
    const n = w * h;
    const { L, A, B } = toLab(data, n);

    // Background = median colour of a thin frame around the image.
    const frame = Math.max(2, Math.round(Math.min(w, h) * 0.03));
    const bl = [], ba = [], bb = [];
    for (let y = 0; y < h; y++) {
      const edgeRow = y < frame || y >= h - frame;
      for (let x = 0; x < w; x += edgeRow ? 2 : 1) {
        if (!edgeRow && x >= frame && x < w - frame) { x = w - frame - 1; continue; }
        const i = y * w + x;
        bl.push(L[i]); ba.push(A[i]); bb.push(B[i]);
      }
    }
    const mL = median(bl), mA = median(ba), mB = median(bb);

    // Lightness counts for less than hue so soft shadows are not mistaken for pieces.
    const dist = new Float32Array(n);
    let maxD = 1;
    for (let i = 0; i < n; i++) {
      const d = Math.hypot((L[i] - mL) * 0.6, A[i] - mA, B[i] - mB);
      dist[i] = d;
      if (d > maxD) maxD = d;
    }
    const floor = 22 - sensitivity * 16; // 6..22
    const thr = Math.max(floor, otsu(dist, maxD) * (1.2 - sensitivity * 0.8));

    let mask = new Uint8Array(n);
    for (let i = 0; i < n; i++) mask[i] = dist[i] > thr ? 1 : 0;
    mask = morph(morph(mask, w, h, true), w, h, false);   // close small gaps
    mask = morph(morph(mask, w, h, false), w, h, true);   // remove specks

    // Connected components (8-neighbour flood fill).
    const label = new Int32Array(n);
    const stack = new Int32Array(n);
    const minArea = Math.max(30, n * minAreaFrac);
    const boxes = [];
    let next = 0;
    for (let start = 0; start < n; start++) {
      if (!mask[start] || label[start]) continue;
      next++;
      let sp = 0, area = 0, x0 = w, y0 = h, x1 = 0, y1 = 0;
      const pix = [];
      stack[sp++] = start; label[start] = next;
      while (sp) {
        const i = stack[--sp];
        const x = i % w, y = (i / w) | 0;
        area++;
        if (x < x0) x0 = x; if (x > x1) x1 = x; if (y < y0) y0 = y; if (y > y1) y1 = y;
        if (pix.length < 4000 || area % 7 === 0) pix.push(i);
        for (let dy = -1; dy <= 1; dy++) {
          const yy = y + dy;
          if (yy < 0 || yy >= h) continue;
          for (let dx = -1; dx <= 1; dx++) {
            const xx = x + dx;
            if (xx < 0 || xx >= w) continue;
            const j = yy * w + xx;
            if (mask[j] && !label[j]) { label[j] = next; stack[sp++] = j; }
          }
        }
      }
      if (area < minArea || area > n * 0.7) continue;
      // Piece colour: per-channel median of its pixels (robust to highlights and shadows).
      const rs = new Uint8Array(pix.length), gs = new Uint8Array(pix.length), bs = new Uint8Array(pix.length);
      for (let k = 0; k < pix.length; k++) { const j = pix[k] * 4; rs[k] = data[j]; gs[k] = data[j + 1]; bs[k] = data[j + 2]; }
      rs.sort(); gs.sort(); bs.sort();
      const mid = pix.length >> 1;
      boxes.push({ x: x0, y: y0, w: x1 - x0 + 1, h: y1 - y0 + 1, area, rgb: [rs[mid], gs[mid], bs[mid]] });
    }
    boxes.sort((a, b) => a.y + a.h / 2 - (b.y + b.h / 2) || a.x - b.x);
    return boxes;
  }

  return { findPieces };
});
