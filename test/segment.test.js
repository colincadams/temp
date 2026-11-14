'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { findPieces } = require('../public/segment');

/** Paint a W×H RGBA image: uneven light background plus solid rectangles. */
function scene(w, h, rects) {
  const data = new Uint8ClampedArray(w * h * 4);
  for (let y = 0; y < h; y++) for (let x = 0; x < w; x++) {
    const i = (y * w + x) * 4, shade = 235 - Math.round((x / w) * 15) + ((x * 7 + y * 13) % 5);
    data[i] = data[i + 1] = data[i + 2] = shade; data[i + 3] = 255;
  }
  for (const [x0, y0, rw, rh, [r, g, b]] of rects) {
    for (let y = y0; y < y0 + rh; y++) for (let x = x0; x < x0 + rw; x++) {
      const i = (y * w + x) * 4; data[i] = r; data[i + 1] = g; data[i + 2] = b;
    }
  }
  return data;
}

test('finds each separate piece with its box and colour', () => {
  const rects = [[20, 20, 60, 30, [200, 20, 20]], [150, 40, 40, 40, [20, 60, 190]], [60, 120, 80, 25, [10, 10, 10]]];
  const boxes = findPieces(scene(240, 180, rects), 240, 180);
  assert.equal(boxes.length, 3);
  for (const [x, y, w, h, rgb] of rects) {
    const b = boxes.find((c) => Math.abs(c.x - x) <= 2 && Math.abs(c.y - y) <= 2);
    assert.ok(b, `box near ${x},${y}`);
    assert.ok(Math.abs(b.w - w) <= 4 && Math.abs(b.h - h) <= 4);
    assert.deepEqual(b.rgb, rgb);
  }
});

test('ignores specks and an empty background', () => {
  assert.equal(findPieces(scene(240, 180, []), 240, 180).length, 0);
  assert.equal(findPieces(scene(240, 180, [[100, 100, 2, 2, [255, 0, 0]], [20, 20, 50, 50, [0, 120, 0]]]), 240, 180).length, 1);
});
