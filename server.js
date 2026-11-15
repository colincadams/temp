'use strict';
const http = require('node:http');
const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const { Catalog, ensureData } = require('./lib/catalog');
const { InventoryStore } = require('./lib/store');
const { hexToRgb } = require('./lib/color');
const { rerankBySize } = require('./lib/size');

const BRICKOGNIZE_URL = 'https://api.brickognize.com/predict/parts/';
const MAX_BODY = 12 * 1024 * 1024;
const MIME = { '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.css': 'text/css; charset=utf-8', '.svg': 'image/svg+xml' };

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    let size = 0;
    req.on('data', (c) => {
      size += c.length;
      if (size > MAX_BODY) { reject(Object.assign(new Error('Request body too large'), { status: 413 })); req.destroy(); return; }
      chunks.push(c);
    });
    req.on('end', () => resolve(Buffer.concat(chunks)));
    req.on('error', reject);
  });
}

async function readJson(req) {
  const body = await readBody(req);
  try { return JSON.parse(body.toString('utf8') || '{}'); } catch { throw Object.assign(new Error('Invalid JSON'), { status: 400 }); }
}

function bad(msg, status = 400) { return Object.assign(new Error(msg), { status }); }

function createApp({ catalog, store, publicDir = path.join(__dirname, 'public'), identify = brickognize, correctionsDir = null }) {
  const matchOpts = (sp) => ({ ignoreColor: sp.get('ignoreColor') === '1', variants: sp.get('variants') !== '0' });

  const inventoryView = () => {
    const items = [];
    let pieces = 0;
    for (const { partNum, colorId, qty } of store.list()) {
      const p = catalog.partIdx.get(partNum), col = catalog.color(colorId);
      if (p === undefined || !col) continue;
      pieces += qty;
      items.push({ partNum, name: catalog.parts[p].name, colorId, colorName: col.name, rgb: col.rgb, qty, img: catalog.imgUrl(p, catalog.colorIdx.get(colorId)) });
    }
    items.sort((a, b) => a.name.localeCompare(b.name) || a.colorName.localeCompare(b.colorName));
    return { items, pieces, lots: items.length };
  };

  const validItem = (body) => {
    const partNum = String(body.partNum ?? ''), colorId = Number(body.colorId), qty = Number(body.qty);
    if (!catalog.partIdx.has(partNum)) throw bad(`Unknown part "${partNum}"`);
    if (!catalog.color(colorId)) throw bad(`Unknown colour ${body.colorId}`);
    if (!Number.isInteger(qty) || qty < 0 || qty > 100000) throw bad('Quantity must be a whole number');
    return { partNum, colorId, qty };
  };

  async function api(req, url) {
    const { pathname: p, searchParams: sp } = url;
    const m = req.method;

    if (p === '/api/meta' && m === 'GET') {
      return {
        colors: catalog.colors.filter((c) => c.id >= 0).map(({ id, name, rgb, isTrans }) => ({ id, name, rgb, isTrans })),
        themes: catalog.rootThemes(),
        setCount: catalog.sets.length,
        partCount: catalog.parts.length,
      };
    }

    if (p === '/api/parts/search' && m === 'GET') return { parts: catalog.searchParts(sp.get('q') || '') };

    // Names, images and likely colours for parts recognised on the phone.
    if (p === '/api/parts/info' && m === 'GET') {
      const rgbHex = sp.get('rgb');
      const rgb = rgbHex && /^[0-9a-f]{6}$/i.test(rgbHex) ? hexToRgb(rgbHex) : null;
      const parts = [];
      for (const num of (sp.get('nums') || '').split(',').slice(0, 50)) {
        const pi = catalog.resolvePart(num);
        if (pi !== undefined) parts.push({ ...catalog.partInfo(pi, rgb), score: 0 });
      }
      return { parts };
    }

    if (p === '/api/identify' && m === 'POST') {
      const image = await readBody(req);
      if (!image.length) throw bad('Empty image');
      const rgbHex = sp.get('rgb');
      const rgb = rgbHex && /^[0-9a-f]{6}$/i.test(rgbHex) ? hexToRgb(rgbHex) : null;
      const found = await identify(image, req.headers['content-type'] || 'image/jpeg');
      const candidates = [], unmatched = [];
      const seen = new Set();
      for (const item of found) {
        const pi = catalog.resolvePart(item.id);
        if (pi === undefined) { unmatched.push({ id: item.id, name: item.name, score: item.score }); continue; }
        if (seen.has(pi)) continue;
        seen.add(pi);
        candidates.push({ ...catalog.partInfo(pi, rgb), score: item.score });
      }
      // Native clients measure the piece in millimetres; use that to separate same-shape, different-size parts.
      return { candidates: rerankBySize(candidates, Number(sp.get('longMm'))), unmatched };
    }

    if (p === '/api/inventory' && m === 'GET') return inventoryView();
    if (p === '/api/inventory' && m === 'DELETE') { store.clear(); store.save(); return inventoryView(); }

    if (p === '/api/inventory/add' && m === 'POST') {
      const body = await readJson(req);
      const items = (Array.isArray(body.items) ? body.items.map(validItem) : [validItem(body)]).filter((it) => it.qty > 0);
      if (!items.length) throw bad('Nothing to add');
      const batch = store.addBatch(items, body.source);
      store.save();
      return { ...inventoryView(), batchId: batch.id };
    }

    if (p === '/api/inventory/set' && m === 'POST') {
      const it = validItem(await readJson(req));
      store.set(it.partNum, it.colorId, it.qty);
      store.save();
      return inventoryView();
    }

    if (p === '/api/inventory/add-set' && m === 'POST') {
      const body = await readJson(req);
      let setNum = String(body.setNum ?? '').trim();
      if (setNum && !setNum.includes('-')) setNum += '-1';
      const parts = catalog.setParts(setNum);
      if (!parts || !parts.length) throw bad(`No parts list found for set "${setNum}"`, 404);
      const set = catalog.sets[catalog.setIdx.get(setNum)];
      const batch = store.addBatch(parts, `set ${setNum} ${set.name}`);
      store.save();
      return { ...inventoryView(), batchId: batch.id, added: { setNum, name: set.name, pieces: set.total } };
    }

    // Everything added to the inventory, newest first, so a scan or a set can be undone.
    if (p === '/api/batches' && m === 'GET') {
      return {
        batches: store.batches.map((b) => ({ id: b.id, at: b.at, source: b.source, lots: b.items.length, pieces: b.items.reduce((n, it) => n + it.qty, 0) })).reverse(),
      };
    }

    if (p.startsWith('/api/batches/') && m === 'DELETE') {
      if (!store.undoBatch(decodeURIComponent(p.slice('/api/batches/'.length)))) throw bad('No such batch', 404);
      store.save();
      return inventoryView();
    }

    // A user fixed a match: keep the crop under the right part number as a labelled real-world example.
    if (p === '/api/corrections' && m === 'POST') {
      if (!correctionsDir) throw bad('Corrections are not being collected', 404);
      const pi = catalog.resolvePart(sp.get('partNum'));
      if (pi === undefined) throw bad(`Unknown part "${sp.get('partNum')}"`);
      const image = await readBody(req);
      if (image.length < 100) throw bad('Empty image');
      const partNum = catalog.parts[pi].num, id = crypto.randomUUID();
      const dir = path.join(correctionsDir, partNum.replace(/[^A-Za-z0-9._-]/g, '_'));
      fs.mkdirSync(dir, { recursive: true });
      fs.writeFileSync(path.join(dir, `${id}.jpg`), image);
      const colour = sp.has('colorId') && sp.get('colorId') !== '' ? catalog.color(Number(sp.get('colorId'))) : undefined;
      const record = { id, at: new Date().toISOString(), partNum, colorId: colour ? colour.id : null,
        predicted: (sp.get('predicted') || '').slice(0, 40) || null, longMm: Number(sp.get('longMm')) || null };
      fs.appendFileSync(path.join(correctionsDir, 'corrections.jsonl'), JSON.stringify(record) + '\n');
      return { saved: id };
    }

    if (p === '/api/builds' && m === 'GET') {
      const num = (k, d) => (sp.has(k) && Number.isFinite(Number(sp.get(k))) ? Number(sp.get(k)) : d);
      return catalog.builds(store.list(), {
        ...matchOpts(sp),
        minParts: Math.max(1, num('minParts', 20)),
        minPct: num('minPct', 0),
        q: sp.get('q') || '',
        theme: sp.get('theme') || '',
        sort: sp.get('sort') === 'missing' ? 'missing' : 'percent',
        minYear: num('minYear', 0),
        maxYear: num('maxYear', 9999),
        limit: Math.min(200, Math.max(1, num('limit', 60))),
        offset: Math.max(0, num('offset', 0)),
      });
    }

    if (p.startsWith('/api/builds/') && m === 'GET') {
      const detail = catalog.buildDetail(store.list(), decodeURIComponent(p.slice('/api/builds/'.length)), matchOpts(sp));
      if (!detail) throw bad('Unknown set', 404);
      return detail;
    }

    throw bad('Not found', 404);
  }

  function serveStatic(req, res, pathname) {
    const rel = pathname === '/' ? 'index.html' : decodeURIComponent(pathname).replace(/^\/+/, '');
    const file = path.resolve(publicDir, rel);
    if (!file.startsWith(path.resolve(publicDir) + path.sep)) { res.writeHead(403).end(); return; }
    fs.readFile(file, (err, data) => {
      if (err) { res.writeHead(404, { 'Content-Type': 'text/plain' }).end('Not found'); return; }
      res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-cache' }).end(data);
    });
  }

  return http.createServer(async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/api/inventory.csv' && req.method === 'GET') {
      const rows = store.list().map((i) => `${i.partNum},${i.colorId},${i.qty}`);
      res.writeHead(200, { 'Content-Type': 'text/csv; charset=utf-8', 'Content-Disposition': 'attachment; filename="lego-inventory.csv"' });
      res.end(['Part,Color,Quantity', ...rows].join('\n') + '\n');
      return;
    }
    const missingCsv = /^\/api\/builds\/(.+)\/missing\.csv$/.exec(url.pathname);
    if (missingCsv && req.method === 'GET') {
      const detail = catalog.buildDetail(store.list(), decodeURIComponent(missingCsv[1]), matchOpts(url.searchParams));
      if (!detail) { res.writeHead(404, { 'Content-Type': 'text/plain' }).end('Unknown set'); return; }
      const rows = detail.parts.filter((x) => x.have < x.need).map((x) => `${x.partNum},${x.colorId},${x.need - x.have}`);
      res.writeHead(200, { 'Content-Type': 'text/csv; charset=utf-8', 'Content-Disposition': `attachment; filename="missing-${detail.setNum}.csv"` });
      res.end(['Part,Color,Quantity', ...rows].join('\n') + '\n');
      return;
    }
    if (!url.pathname.startsWith('/api/')) { serveStatic(req, res, url.pathname); return; }
    try {
      const out = await api(req, url);
      res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(out));
    } catch (err) {
      const status = err.status || 500;
      if (status >= 500) console.error(err);
      res.writeHead(status, { 'Content-Type': 'application/json' }).end(JSON.stringify({ error: err.message }));
    }
  });
}

/** Ask the Brickognize API which part is in the image. Returns [{id, name, score}]. */
async function brickognize(image, contentType) {
  const form = new FormData();
  form.append('query_image', new Blob([image], { type: contentType }), 'piece.jpg');
  let res;
  try {
    res = await fetch(BRICKOGNIZE_URL, { method: 'POST', body: form, headers: { accept: 'application/json' }, signal: AbortSignal.timeout(30000) });
  } catch (err) {
    throw bad(`Could not reach the recognition service (${err.cause?.code || err.message})`, 502);
  }
  if (!res.ok) throw bad(`Recognition service returned HTTP ${res.status}`, 502);
  const data = await res.json();
  return (data.items || []).filter((i) => i.type === 'part').map(({ id, name, score }) => ({ id, name, score }));
}

async function main() {
  const dataDir = process.env.DATA_DIR || path.join(__dirname, 'data');
  const port = Number(process.env.PORT) || 3000;
  const host = process.env.HOST || '127.0.0.1';
  await ensureData(dataDir, { refresh: process.argv.includes('--refresh-data'), log: console.log });
  console.log('Loading Lego catalog…');
  const t = Date.now();
  const catalog = await Catalog.load(dataDir);
  console.log(`Loaded ${catalog.sets.length} sets and ${catalog.parts.length} parts in ${((Date.now() - t) / 1000).toFixed(1)}s`);
  const store = new InventoryStore(path.join(dataDir, 'inventory.json'));
  createApp({ catalog, store, correctionsDir: path.join(dataDir, 'corrections') }).listen(port, host, () => console.log(`Brick Inventory running at http://${host === '0.0.0.0' ? 'localhost' : host}:${port}`));
}

if (require.main === module) main().catch((err) => { console.error(err.message || err); process.exit(1); });

module.exports = { createApp };
