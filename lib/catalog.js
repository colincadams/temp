'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { Readable } = require('node:stream');
const { pipeline } = require('node:stream/promises');
const { readCsv } = require('./csv');
const { hexToRgb, srgbToLab } = require('./color');

const DOWNLOAD_BASE = 'https://cdn.rebrickable.com/media/downloads/';
const FILES = ['colors', 'parts', 'part_relationships', 'themes', 'sets', 'inventories', 'inventory_parts'];
const IMG_PREFIX = 'https://cdn.rebrickable.com/media/parts/';
// Relationship types that mean "physically the same shape": Print, paTtern, Mold.
const VARIANT_RELS = new Set(['P', 'T', 'M']);

/** Download any missing Rebrickable catalog files into `dir`. */
async function ensureData(dir, { refresh = false, log = () => {} } = {}) {
  fs.mkdirSync(dir, { recursive: true });
  for (const name of FILES) {
    const dest = path.join(dir, `${name}.csv.gz`);
    if (!refresh && fs.existsSync(dest)) continue;
    log(`Downloading ${name}.csv.gz from Rebrickable…`);
    const res = await fetch(`${DOWNLOAD_BASE}${name}.csv.gz`);
    if (!res.ok) throw new Error(`Download of ${name}.csv.gz failed: HTTP ${res.status}`);
    const tmp = dest + '.tmp';
    await pipeline(Readable.fromWeb(res.body), fs.createWriteStream(tmp));
    fs.renameSync(tmp, dest);
  }
}

class Catalog {
  constructor() {
    this.colors = [];            // [{id, name, rgb, isTrans, lab}]
    this.colorIdx = new Map();   // color id -> index
    this.parts = [];             // [{num, name, lname}]
    this.partIdx = new Map();    // part num -> index
    this.partLower = new Map();  // lowercased part num -> index
    this.canon = null;           // Int32Array partIdx -> canonical partIdx (variants merged)
    this.partUse = null;         // Int32Array partIdx -> number of set rows using it
    this.partImg = [];           // partIdx -> image path suffix
    this.keyImg = new Map();     // partIdx*NC+colorIdx -> image path suffix
    this.keyUse = new Map();     // partIdx*NC+colorIdx -> number of set rows with that part in that colour
    this.partColors = new Map(); // partIdx -> Set(colorIdx)
    this.themes = new Map();     // id -> {name, parent}
    this.sets = [];              // [{num, name, year, theme, rootTheme, img, total}]
    this.setIdx = new Map();
    this.setStart = null;        // Int32Array (sets+1) offsets into row arrays
    this.rowPart = null; this.rowColor = null; this.rowQty = null;
  }

  get NC() { return this.colors.length + 1; }

  _partIndex(num, name) {
    let i = this.partIdx.get(num);
    if (i === undefined) {
      i = this.parts.length;
      this.parts.push({ num, name: name || num, lname: (name || num).toLowerCase() });
      this.partIdx.set(num, i);
      this.partLower.set(num.toLowerCase(), i);
    }
    return i;
  }

  /** Load from a directory of Rebrickable *.csv.gz (or *.csv) files. */
  static async load(dir) {
    const c = new Catalog();
    const file = (name) => {
      const gz = path.join(dir, `${name}.csv.gz`);
      return fs.existsSync(gz) ? gz : path.join(dir, `${name}.csv`);
    };

    await readCsv(file('colors'), ([id, name, rgb, isTrans]) => {
      const [r, g, b] = hexToRgb(rgb);
      c.colorIdx.set(Number(id), c.colors.length);
      c.colors.push({ id: Number(id), name, rgb, isTrans: isTrans === 'True' || isTrans === 't', lab: srgbToLab(r, g, b) });
    });

    await readCsv(file('parts'), ([num, name]) => { c._partIndex(num, name); });

    const rels = [];
    if (fs.existsSync(file('part_relationships'))) {
      await readCsv(file('part_relationships'), ([type, child, parent]) => {
        if (VARIANT_RELS.has(type)) rels.push([child, parent]);
      });
    }

    await readCsv(file('themes'), ([id, name, parent]) => {
      c.themes.set(Number(id), { name, parent: parent === '' ? null : Number(parent) });
    });
    const rootTheme = (id) => {
      let t = c.themes.get(id), guard = 0;
      while (t && t.parent !== null && c.themes.has(t.parent) && guard++ < 10) t = c.themes.get(t.parent);
      return t ? t.name : 'Unknown';
    };

    await readCsv(file('sets'), ([num, name, year, themeId, , img]) => {
      const t = c.themes.get(Number(themeId));
      c.setIdx.set(num, c.sets.length);
      c.sets.push({ num, name, lname: name.toLowerCase(), year: Number(year), theme: t ? t.name : 'Unknown', rootTheme: rootTheme(Number(themeId)), img, total: 0 });
    });

    // Pick one inventory per set: the lowest version number is the canonical one.
    const best = new Map(); // setIdx -> {id, version}
    await readCsv(file('inventories'), ([id, version, setNum]) => {
      const s = c.setIdx.get(setNum);
      if (s === undefined) return;
      const v = Number(version), cur = best.get(s);
      if (!cur || v < cur.version) best.set(s, { id: Number(id), version: v });
    });
    const invToSet = new Map();
    for (const [s, { id }] of best) invToSet.set(id, s);

    const tSet = [], tPart = [], tColor = [], tQty = [];
    await readCsv(file('inventory_parts'), ([invId, partNum, colorId, qty, isSpare, img]) => {
      const s = invToSet.get(Number(invId));
      if (s === undefined) return;
      const p = c._partIndex(partNum);
      let ci = c.colorIdx.get(Number(colorId));
      if (ci === undefined) return;
      let colors = c.partColors.get(p);
      if (!colors) c.partColors.set(p, (colors = new Set()));
      colors.add(ci);
      const k = p * c.NC + ci;
      c.keyUse.set(k, (c.keyUse.get(k) || 0) + 1);
      if (img && img.startsWith(IMG_PREFIX)) {
        const suffix = img.slice(IMG_PREFIX.length);
        if (!c.keyImg.has(k)) c.keyImg.set(k, suffix);
        if (c.partImg[p] === undefined) c.partImg[p] = suffix;
      }
      if (isSpare === 'True' || isSpare === 't') return;
      tSet.push(s); tPart.push(p); tColor.push(ci); tQty.push(Number(qty));
    });

    // Group rows by set with a counting sort.
    const nSets = c.sets.length, nRows = tSet.length;
    c.setStart = new Int32Array(nSets + 1);
    for (let i = 0; i < nRows; i++) c.setStart[tSet[i] + 1]++;
    for (let s = 0; s < nSets; s++) c.setStart[s + 1] += c.setStart[s];
    const cursor = c.setStart.slice(0, nSets);
    c.rowPart = new Int32Array(nRows); c.rowColor = new Int16Array(nRows); c.rowQty = new Int32Array(nRows);
    c.partUse = new Int32Array(c.parts.length);
    for (let i = 0; i < nRows; i++) {
      const s = tSet[i], at = cursor[s]++;
      c.rowPart[at] = tPart[i]; c.rowColor[at] = tColor[i]; c.rowQty[at] = tQty[i];
      c.sets[s].total += tQty[i];
      c.partUse[tPart[i]]++;
    }

    // Union-find over print/pattern/mold relationships.
    const parent = new Int32Array(c.parts.length);
    for (let i = 0; i < parent.length; i++) parent[i] = i;
    const find = (x) => { while (parent[x] !== x) { parent[x] = parent[parent[x]]; x = parent[x]; } return x; };
    for (const [a, b] of rels) {
      const ia = c.partIdx.get(a), ib = c.partIdx.get(b);
      if (ia === undefined || ib === undefined) continue;
      const ra = find(ia), rb = find(ib);
      if (ra !== rb) parent[ra] = rb;
    }
    c.canon = new Int32Array(c.parts.length);
    for (let i = 0; i < parent.length; i++) c.canon[i] = find(i);
    return c;
  }

  // ---------- lookups ----------

  imgUrl(p, ci) {
    const s = (ci !== undefined && this.keyImg.get(p * this.NC + ci)) || this.partImg[p];
    return s ? IMG_PREFIX + s : null;
  }

  color(id) { return this.colors[this.colorIdx.get(id)]; }

  /** Resolve a part number from another catalog (e.g. BrickLink) to a catalog part index. */
  resolvePart(num) {
    if (!num) return undefined;
    return this.partIdx.get(num) ?? this.partLower.get(String(num).toLowerCase());
  }

  /**
   * Colours this part is known to exist in, most likely match for `rgb` first.
   * Photos shift colours (exposure, shadows), so lightness counts for less than hue
   * and colours the part commonly comes in get a small head start over rare ones.
   */
  colorsForPart(p, rgb) {
    const known = [...(this.partColors.get(p) || [])];
    if (rgb) {
      const lab = srgbToLab(rgb[0], rgb[1], rgb[2]);
      const score = new Map(known.map((ci) => {
        const c = this.colors[ci].lab;
        const d = Math.hypot((c[0] - lab[0]) * 0.7, c[1] - lab[1], c[2] - lab[2]);
        return [ci, d - 4 * Math.log10(this.keyUse.get(p * this.NC + ci) || 1)];
      }));
      known.sort((a, b) => score.get(a) - score.get(b));
    } else {
      const use = (ci) => this.keyUse.get(p * this.NC + ci) || 0;
      known.sort((a, b) => use(b) - use(a)); // most common colour first
    }
    return known.map((ci) => { const { id, name, rgb: hex, isTrans } = this.colors[ci]; return { id, name, rgb: hex, isTrans }; });
  }

  partInfo(p, rgb) {
    const part = this.parts[p];
    const colors = this.colorsForPart(p, rgb);
    const ci = colors.length ? this.colorIdx.get(colors[0].id) : undefined;
    return { partNum: part.num, name: part.name, img: this.imgUrl(p, ci), colors };
  }

  searchParts(q, limit = 30) {
    const tokens = q.toLowerCase().split(/\s+/).filter(Boolean);
    if (!tokens.length) return [];
    const hits = [];
    for (let p = 0; p < this.parts.length; p++) {
      const part = this.parts[p];
      const lnum = part.num.toLowerCase();
      let ok = true;
      for (const t of tokens) if (!part.lname.includes(t) && !lnum.startsWith(t)) { ok = false; break; }
      if (!ok) continue;
      const exact = tokens.length === 1 && lnum === tokens[0] ? 1 : 0;
      hits.push([exact, this.partUse[p], p]);
    }
    hits.sort((a, b) => b[0] - a[0] || b[1] - a[1]);
    return hits.slice(0, limit).map(([, , p]) => this.partInfo(p));
  }

  /** All non-spare parts of a set as inventory-style items. */
  setParts(setNum) {
    const s = this.setIdx.get(setNum);
    if (s === undefined) return null;
    const out = [];
    for (let i = this.setStart[s]; i < this.setStart[s + 1]; i++) {
      out.push({ partNum: this.parts[this.rowPart[i]].num, colorId: this.colors[this.rowColor[i]].id, qty: this.rowQty[i] });
    }
    return out;
  }

  // ---------- build matching ----------

  _keyFn({ ignoreColor, variants }) {
    const NC = this.NC, canon = this.canon;
    return (p, ci) => (variants ? canon[p] : p) * NC + (ignoreColor ? 0 : ci + 1);
  }

  _haveMap(items, opts) {
    const key = this._keyFn(opts);
    const have = new Map();
    for (const { partNum, colorId, qty } of items) {
      const p = this.partIdx.get(partNum), ci = this.colorIdx.get(colorId);
      if (p === undefined || ci === undefined || !(qty > 0)) continue;
      const k = key(p, ci);
      have.set(k, (have.get(k) || 0) + qty);
    }
    return have;
  }

  /**
   * For every set, count how many of its pieces the inventory covers.
   * @returns {Int32Array} owned piece count per set index
   */
  ownedCounts(items, opts = {}) {
    const have = this._haveMap(items, opts);
    const key = this._keyFn(opts);
    const owned = new Int32Array(this.sets.length);
    if (!have.size) return owned;
    const { setStart, rowPart, rowColor, rowQty } = this;
    const used = new Map();
    for (let s = 0; s < owned.length; s++) {
      let n = 0;
      if (used.size) used.clear();
      for (let i = setStart[s], e = setStart[s + 1]; i < e; i++) {
        const k = key(rowPart[i], rowColor[i]);
        const avail = have.get(k);
        if (avail === undefined) continue;
        const u = used.get(k) || 0;
        const take = Math.min(rowQty[i], avail - u);
        if (take > 0) { used.set(k, u + take); n += take; }
      }
      owned[s] = n;
    }
    return owned;
  }

  /** Ranked list of sets by completion percentage. */
  builds(items, { ignoreColor = false, variants = true, minParts = 20, minPct = 0, q = '', theme = '', limit = 60, offset = 0 } = {}) {
    const owned = this.ownedCounts(items, { ignoreColor, variants });
    const tokens = q.toLowerCase().split(/\s+/).filter(Boolean);
    const hits = [];
    for (let s = 0; s < this.sets.length; s++) {
      const set = this.sets[s];
      if (set.total < minParts || set.total === 0) continue;
      const pct = owned[s] / set.total;
      if (pct * 100 < minPct) continue;
      if (theme && set.rootTheme !== theme) continue;
      if (tokens.length && !tokens.every((t) => set.lname.includes(t) || set.num.toLowerCase().startsWith(t))) continue;
      hits.push(s);
    }
    hits.sort((a, b) => {
      const pa = owned[a] / this.sets[a].total, pb = owned[b] / this.sets[b].total;
      return pb - pa || this.sets[b].total - this.sets[a].total;
    });
    const complete = hits.reduce((n, s) => n + (owned[s] === this.sets[s].total ? 1 : 0), 0);
    return {
      count: hits.length,
      complete,
      sets: hits.slice(offset, offset + limit).map((s) => {
        const { num, name, year, theme: th, img, total } = this.sets[s];
        return { setNum: num, name, year, theme: th, img, total, owned: owned[s] };
      }),
    };
  }

  /** Per-part breakdown of one set against the inventory. */
  buildDetail(items, setNum, { ignoreColor = false, variants = true } = {}) {
    const s = this.setIdx.get(setNum);
    if (s === undefined) return null;
    const opts = { ignoreColor, variants };
    const have = this._haveMap(items, opts), key = this._keyFn(opts), used = new Map();
    const parts = [];
    let owned = 0;
    for (let i = this.setStart[s]; i < this.setStart[s + 1]; i++) {
      const p = this.rowPart[i], ci = this.rowColor[i], need = this.rowQty[i];
      const k = key(p, ci), u = used.get(k) || 0;
      const take = Math.max(0, Math.min(need, (have.get(k) || 0) - u));
      used.set(k, u + take);
      owned += take;
      const col = this.colors[ci];
      parts.push({ partNum: this.parts[p].num, name: this.parts[p].name, colorId: col.id, colorName: col.name, rgb: col.rgb, img: this.imgUrl(p, ci), need, have: take });
    }
    parts.sort((a, b) => (b.need - b.have) - (a.need - a.have) || a.name.localeCompare(b.name));
    const { num, name, year, theme, img, total } = this.sets[s];
    return { setNum: num, name, year, theme, img, total, owned, parts };
  }

  rootThemes() {
    return [...new Set(this.sets.filter((s) => s.total > 0).map((s) => s.rootTheme))].sort();
  }
}

module.exports = { Catalog, ensureData, FILES };
