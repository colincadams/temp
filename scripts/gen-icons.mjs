// Generates the PWA / home-screen icons as PNGs with no external dependencies.
// Draws a simple "incline" mark (a rising road wedge) on the app's dark bg.
// Run: node scripts/gen-icons.mjs
import zlib from "node:zlib";
import { writeFileSync, mkdirSync } from "node:fs";

const BG = [11, 15, 20]; // #0b0f14
const WEDGE = [60, 42, 16]; // muted amber fill
const LINE = [255, 176, 32]; // #ffb020

function crc32(buf) {
  let c = ~0;
  for (let i = 0; i < buf.length; i++) {
    c ^= buf[i];
    for (let k = 0; k < 8; k++) c = (c >>> 1) ^ (0xedb88320 & -(c & 1));
  }
  return ~c >>> 0;
}
function chunk(type, data) {
  const len = Buffer.alloc(4);
  len.writeUInt32BE(data.length);
  const td = Buffer.concat([Buffer.from(type, "ascii"), data]);
  const crc = Buffer.alloc(4);
  crc.writeUInt32BE(crc32(td));
  return Buffer.concat([len, td, crc]);
}
function png(width, height, rgb) {
  const sig = Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]);
  const ihdr = Buffer.alloc(13);
  ihdr.writeUInt32BE(width, 0);
  ihdr.writeUInt32BE(height, 4);
  ihdr[8] = 8; // bit depth
  ihdr[9] = 2; // color type: truecolor RGB
  const raw = Buffer.alloc((width * 3 + 1) * height);
  let o = 0;
  for (let y = 0; y < height; y++) {
    raw[o++] = 0; // filter: none
    for (let x = 0; x < width; x++) {
      const [r, g, b] = rgb(x, y);
      raw[o++] = r;
      raw[o++] = g;
      raw[o++] = b;
    }
  }
  return Buffer.concat([
    sig,
    chunk("IHDR", ihdr),
    chunk("IDAT", zlib.deflateSync(raw, { level: 9 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
}

function makeIcon(N) {
  // Wedge triangle: bottom-left -> bottom-right -> top-right (a rising slope).
  const x0 = 0.14 * N, x1 = 0.86 * N, yb = 0.80 * N, yt = 0.28 * N;
  const ax = x0, ay = yb, bx = x1, by = yb, cx = x1, cy = yt;
  const area = (px, py, qx, qy, rx, ry) =>
    (qx - px) * (ry - py) - (qy - py) * (rx - px);
  const inTri = (x, y) => {
    const d1 = area(x, y, ax, ay, bx, by);
    const d2 = area(x, y, bx, by, cx, cy);
    const d3 = area(x, y, cx, cy, ax, ay);
    const neg = d1 < 0 || d2 < 0 || d3 < 0;
    const pos = d1 > 0 || d2 > 0 || d3 > 0;
    return !(neg && pos);
  };
  // Distance from point to the hypotenuse segment A->C (the road surface).
  const distLine = (x, y) => {
    const vx = cx - ax, vy = cy - ay;
    const t = Math.max(0, Math.min(1, ((x - ax) * vx + (y - ay) * vy) / (vx * vx + vy * vy)));
    return Math.hypot(x - (ax + t * vx), y - (ay + t * vy));
  };
  const stroke = N * 0.05;
  return png(N, N, (x, y) => {
    if (distLine(x, y) <= stroke) return LINE;
    if (inTri(x, y)) return WEDGE;
    return BG;
  });
}

mkdirSync("icons", { recursive: true });
for (const N of [180, 192, 512]) {
  writeFileSync(`icons/icon-${N}.png`, makeIcon(N));
  console.log(`wrote icons/icon-${N}.png`);
}
