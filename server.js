'use strict';
const http = require('node:http');
const fs = require('node:fs');
const crypto = require('node:crypto');
const path = require('node:path');
const { Catalog, ensureData, catalogDate: catalogDateOf, isStale, refreshCatalog } = require('./lib/catalog');
const { InventoryStore } = require('./lib/store');
const { hexToRgb } = require('./lib/color');
const { rerankBySize } = require('./lib/size');
const { parseLine } = require('./lib/csv');
const { advertise } = require('./lib/advertise');

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

/**
 * The HTTP server. `catalogDate` is when the catalog was downloaded (a Date, or null if unknown).
 * The returned server has `setCatalog(catalog, date)`, which swaps in a newer catalog between requests.
 */
function createApp({ catalog, store, publicDir = path.join(__dirname, 'public'), identify = brickognize, correctionsDir = null, catalogDate = null }) {
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

  // "31058" means "31058-1", as it does when adding a set.
  const fullSetNum = (raw) => {
    const setNum = String(raw ?? '').trim();
    return setNum && !setNum.includes('-') ? setNum + '-1' : setNum;
  };
  const favouritesView = () => ({ sets: [...store.favourites] });

  // Rows of an exported inventory (Part,Color,Quantity). Rows that do not name a known part and colour are counted, not added.
  const parseImport = (text) => {
    const lines = text.replace(/^\uFEFF/, '').split(/\r?\n/).filter((l) => l.trim() !== '');
    if (lines.length && /^\s*"?part"?\s*,/i.test(lines[0])) lines.shift();
    if (!lines.length) throw bad('That file has no rows to import');
    const lots = new Map();
    let skipped = 0;
    for (const line of lines) {
      const [part, color, quantity] = parseLine(line).map((f) => f.trim());
      const colorId = Number(color), qty = Number(quantity);
      if (!catalog.partIdx.has(part) || color === '' || color === undefined || !catalog.color(colorId) ||
        quantity === '' || !Number.isInteger(qty) || qty < 1 || qty > 100000) { skipped++; continue; }
      const k = `${part}|${colorId}`, lot = lots.get(k);
      if (lot) lot.qty += qty; else lots.set(k, { partNum: part, colorId, qty });
    }
    return { items: [...lots.values()], skipped };
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
        catalogDate: catalogDate ? catalogDate.toISOString().slice(0, 10) : null,
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

    if (p === '/api/inventory/import' && m === 'POST') {
      const { items, skipped } = parseImport((await readBody(req)).toString('utf8'));
      if (!items.length) throw bad(`None of the ${skipped} rows could be imported: unknown part or colour, or a bad quantity`);
      const batch = store.addBatch(items, 'import');
      store.save();
      return { ...inventoryView(), batchId: batch.id, skipped, added: { pieces: items.reduce((n, it) => n + it.qty, 0), lots: items.length } };
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

    // Does this look like something already added? Lets a client warn before the same pieces are counted twice.
    if (p === '/api/batches/check' && m === 'POST') {
      const body = await readJson(req);
      if (!Array.isArray(body.items)) throw bad('items must be a list');
      const items = body.items.map((it) => ({ partNum: String(it?.partNum ?? ''), colorId: Number(it?.colorId), qty: Number(it?.qty) }))
        .filter((it) => it.partNum && Number.isFinite(it.colorId) && Number.isFinite(it.qty) && it.qty > 0);
      return { similar: store.similarBatch(items, 0.7) };
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

    if (p === '/api/favourites' && m === 'GET') return favouritesView();

    if (p.startsWith('/api/favourites/') && (m === 'PUT' || m === 'DELETE')) {
      const setNum = fullSetNum(decodeURIComponent(p.slice('/api/favourites/'.length)));
      // A favourite whose set has since left the catalog can still be removed.
      if (!catalog.setIdx.has(setNum) && !(m === 'DELETE' && store.favourites.has(setNum))) throw bad(`Unknown set "${setNum}"`, 404);
      if (m === 'PUT') store.favourites.add(setNum); else store.favourites.delete(setNum);
      store.save();
      return favouritesView();
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
        favourites: store.favourites,
        favouritesOnly: sp.get('favourites') === '1',
      });
    }

    if (p.startsWith('/api/builds/') && m === 'GET') {
      const detail = catalog.buildDetail(store.list(), decodeURIComponent(p.slice('/api/builds/'.length)), matchOpts(sp));
      if (!detail) throw bad('Unknown set', 404);
      return { ...detail, favourite: store.favourites.has(detail.setNum) };
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

  const csv = (res, filename, rows) => {
    res.writeHead(200, { 'Content-Type': 'text/csv; charset=utf-8', 'Content-Disposition': `attachment; filename="${filename}"` });
    res.end(['Part,Color,Quantity', ...rows].join('\n') + '\n');
  };

  async function handle(req, res) {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/api/inventory.csv' && req.method === 'GET') {
      csv(res, 'lego-inventory.csv', store.list().map((i) => `${i.partNum},${i.colorId},${i.qty}`));
      return;
    }
    const missingCsv = /^\/api\/builds\/(.+)\/missing\.csv$/.exec(url.pathname);
    if (missingCsv && req.method === 'GET') {
      const detail = catalog.buildDetail(store.list(), decodeURIComponent(missingCsv[1]), matchOpts(url.searchParams));
      if (!detail) { res.writeHead(404, { 'Content-Type': 'text/plain' }).end('Unknown set'); return; }
      csv(res, `missing-${detail.setNum}.csv`, detail.parts.filter((x) => x.have < x.need).map((x) => `${x.partNum},${x.colorId},${x.need - x.have}`));
      return;
    }
    if (!url.pathname.startsWith('/api/')) { serveStatic(req, res, url.pathname); return; }
    const out = await api(req, url);
    res.writeHead(200, { 'Content-Type': 'application/json' }).end(JSON.stringify(out));
  }

  const server = http.createServer(async (req, res) => {
    try {
      await handle(req, res);
    } catch (err) {
      // A URL that cannot be parsed or decoded is the client's mistake, not a server fault.
      const status = err.status || (err instanceof URIError || err.code === 'ERR_INVALID_URL' ? 400 : 500);
      if (status >= 500) console.error(err);
      if (res.headersSent) { res.end(); return; }
      res.writeHead(status, { 'Content-Type': 'application/json' }).end(JSON.stringify({ error: status === 400 && !err.status ? 'Bad request' : err.message }));
    }
  });
  server.setCatalog = (next, date = null) => { catalog = next; catalogDate = date; };
  return server;
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
  const downloaded = catalogDateOf(dataDir);
  const server = createApp({ catalog, store, correctionsDir: path.join(dataDir, 'corrections'), catalogDate: downloaded });
  server.listen(port, host, () => {
    console.log(`Brick Inventory running at http://${host === '0.0.0.0' ? 'localhost' : host}:${port}`);
    advertise({ host, port, log: console.log });
    // New sets appear every week: refresh an old catalog without holding up startup or needing a restart.
    if (isStale(downloaded)) refreshCatalog({ dir: dataDir, swap: server.setCatalog, log: console.log });
  });
}

if (require.main === module) main().catch((err) => { console.error(err.message || err); process.exit(1); });

module.exports = { createApp };
