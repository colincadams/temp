'use strict';

const STUD_MM = 8;

/** Longest footprint side in studs, read from a part name such as "Plate 2 x 4". */
function nameStuds(name) {
  if (/^(wheel|tyre|tire)\b/i.test(name)) return null; // these are sized in millimetres
  const m = /(\d+(?:\.\d+)?)\s*x\s*(\d+(?:\.\d+)?)/i.exec(name);
  if (!m) return null;
  const studs = Math.max(Number(m[1]), Number(m[2]));
  return studs > 0 && studs <= 48 ? studs : null;
}

/** 1 when the measured length fits the named size, falling towards 0.15 as it disagrees. */
function sizeFactor(name, longMm) {
  const studs = nameStuds(name);
  if (studs === null) return 1;
  const diff = longMm / STUD_MM - studs;
  const sigma = Math.max(1, 0.15 * studs);
  return Math.max(0.15, Math.exp(-(diff * diff) / (2 * sigma * sigma)));
}

/**
 * Re-order recognition candidates using the piece's measured longest side.
 * Look-alikes such as 1 x 2 and 1 x 4 plates differ only in scale, which a single crop cannot show.
 */
function rerankBySize(candidates, longMm) {
  if (!(longMm > 0)) return candidates;
  return candidates
    .map((c) => ({ ...c, score: c.score * sizeFactor(c.name, longMm) }))
    .sort((a, b) => b.score - a.score);
}

module.exports = { nameStuds, sizeFactor, rerankBySize, STUD_MM };
