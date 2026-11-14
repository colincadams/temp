'use strict';
const http = require('node:http');
const fs = require('node:fs');
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

function createApp({ catalog, store, publicDir = path.join(__dirname, 'public'), identify = brickognize }) {
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
      const items = Array.isArray(body.items) ? body.items.map(validItem) : [validItem(body)];
      for (const it of items) store.add(it.partNum, it.colorId, it.qty);
      store.save();
      return inventoryView();
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
      for (const it of parts) store.add(it.partNum, it.colorId, it.qty);
      store.save();
      const set = catalog.sets[catalog.setIdx.get(setNum)];
      return { ...inventoryView(), added: { setNum, name: set.name, pieces: set.total } };
    }

    if (p === '/api/builds' && m === 'GET') {
      const num = (k, d) => (sp.has(k) && Number.isFinite(Number(sp.get(k))) ? Number(sp.get(k)) : d);
      return catalog.builds(store.list(), {
        ...matchOpts(sp),
        minParts: Math.max(1, num('minParts', 20)),
        minPct: num('minPct', 0),
        q: sp.get('q') || '',
        theme: sp.get('theme') || '',
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
  createApp({ catalog, store }).listen(port, host, () => console.log(`Brick Inventory running at http://${host === '0.0.0.0' ? 'localhost' : host}:${port}`));
}

if (require.main === module) main().catch((err) => { console.error(err.message || err); process.exit(1); });

module.exports = { createApp };
