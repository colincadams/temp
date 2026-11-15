'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Catalog } = require('../lib/catalog');
const { InventoryStore } = require('../lib/store');
const { createApp } = require('../server');

const fixtures = path.join(__dirname, 'fixtures');

async function withServer(fn, { store = new InventoryStore(null), ...opts } = {}) {
  const catalog = await Catalog.load(fixtures);
  const server = createApp({ catalog, store, ...opts });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try { await fn(base, server, store); } finally { server.close(); }
}

const json = (url, opts) => fetch(url, opts).then((r) => r.json());
const post = (url, body) => json(url, { method: 'POST', body: JSON.stringify(body) });
const item = (partNum, colorId, qty) => ({ partNum, colorId, qty });

// ───────── Repeat-scan check ─────────

test('similarBatch measures shared pieces against the larger batch', () => {
  const store = new InventoryStore(null);
  assert.equal(store.similarBatch([item('3001', 4, 1)]), null); // nothing added yet
  const b = store.addBatch([item('3001', 4, 6), item('3020', 0, 4)], 'scan');
  // 5 + 4 shared of max(10, 10)
  assert.deepEqual(store.similarBatch([item('3001', 4, 5), item('3020', 0, 5)]), { id: b.id, at: b.at, source: 'scan', pieces: 10, overlap: 0.9 });
  // Same part in another colour is a different lot: 4 shared of 10
  assert.equal(store.similarBatch([item('3001', 1, 6), item('3020', 0, 4)]), null);
  // A small scan that is entirely inside a big batch is not a repeat of it: 3 of 10
  assert.equal(store.similarBatch([item('3001', 4, 3)]), null);
  // ...and a big scan that contains a small batch is not either: 10 of 40
  assert.equal(store.similarBatch([item('3001', 4, 30), item('3020', 0, 10)]), null);
  // Exactly 0.7 counts, and lots split over several rows are added up
  assert.equal(store.similarBatch([item('3001', 4, 3), item('3001', 4, 3), item('3020', 0, 1)]).overlap, 0.7);
  assert.equal(store.similarBatch([]), null);
});

test('similarBatch reports the most similar batch, the newest on a tie', () => {
  const store = new InventoryStore(null);
  const a = store.addBatch([item('3001', 4, 10)], 'first');
  const b = store.addBatch([item('3001', 4, 8)], 'second');
  const c = store.addBatch([item('3001', 4, 8)], 'third');
  assert.equal(store.similarBatch([item('3001', 4, 10)]).id, a.id);
  assert.equal(store.similarBatch([item('3001', 4, 8)]).id, c.id);
  assert.notEqual(c.id, b.id);
});

test('POST /api/batches/check finds a repeat of an earlier addition', () => withServer(async (base) => {
  const scan = [item('3001', 4, 3), item('3020', 0, 2), item('3069b', 1, 5)];
  assert.deepEqual(await post(`${base}/api/batches/check`, { items: scan }), { similar: null });
  const added = await post(`${base}/api/inventory/add`, { source: 'photo scan', items: scan });
  const { batches } = await json(`${base}/api/batches`);

  const same = await post(`${base}/api/batches/check`, { items: scan });
  assert.deepEqual(same, { similar: { id: added.batchId, at: batches[0].at, source: 'photo scan', pieces: 10, overlap: 1 } });
  assert.ok(!Number.isNaN(Date.parse(same.similar.at)));

  const close = await post(`${base}/api/batches/check`, { items: [item('3001', 4, 3), item('3020', 0, 2), item('3069b', 1, 3)] });
  assert.equal(close.similar.overlap, 0.8);
  const different = await post(`${base}/api/batches/check`, { items: [item('3001', 1, 3), item('3020', 0, 2)] });
  assert.equal(different.similar, null);

  // Checking never changes the inventory, and an undone batch is no longer reported.
  assert.equal((await json(`${base}/api/inventory`)).pieces, 10);
  await fetch(`${base}/api/batches/${added.batchId}`, { method: 'DELETE' });
  assert.deepEqual(await post(`${base}/api/batches/check`, { items: scan }), { similar: null });

  assert.deepEqual(await post(`${base}/api/batches/check`, { items: [] }), { similar: null });
  assert.equal((await fetch(`${base}/api/batches/check`, { method: 'POST', body: '{}' })).status, 400);
  assert.equal((await fetch(`${base}/api/batches/check`, { method: 'POST', body: 'not json' })).status, 400);
}));

// ───────── Favourites ─────────

test('favourites can be added, listed and removed, by full or short set number', () => withServer(async (base) => {
  assert.deepEqual(await json(`${base}/api/favourites`), { sets: [] });
  assert.deepEqual(await json(`${base}/api/favourites/200-1`, { method: 'PUT' }), { sets: ['200-1'] });
  assert.deepEqual(await json(`${base}/api/favourites/100`, { method: 'PUT' }), { sets: ['200-1', '100-1'] });
  assert.deepEqual(await json(`${base}/api/favourites/100-1`, { method: 'PUT' }), { sets: ['200-1', '100-1'] }); // no duplicates
  assert.deepEqual(await json(`${base}/api/favourites`), { sets: ['200-1', '100-1'] });
  assert.deepEqual(await json(`${base}/api/favourites/200`, { method: 'DELETE' }), { sets: ['100-1'] });
  assert.deepEqual(await json(`${base}/api/favourites/200-1`, { method: 'DELETE' }), { sets: ['100-1'] }); // already gone
  for (const method of ['PUT', 'DELETE']) {
    const res = await fetch(`${base}/api/favourites/999-1`, { method });
    assert.equal(res.status, 404);
    assert.match((await res.json()).error, /999-1/);
  }
  assert.deepEqual(await json(`${base}/api/favourites`), { sets: ['100-1'] });
}));

test('builds mark favourites and can list only them', () => withServer(async (base) => {
  const all = await json(`${base}/api/builds?minParts=1`);
  assert.deepEqual(all.sets.map((s) => [s.setNum, s.favourite]), [['200-1', false], ['100-1', false]]);
  assert.equal((await json(`${base}/api/builds/200-1`)).favourite, false);
  assert.deepEqual(await json(`${base}/api/builds?minParts=1&favourites=1`), { count: 0, complete: 0, sets: [] });

  await fetch(`${base}/api/favourites/200`, { method: 'PUT' });
  const marked = await json(`${base}/api/builds?minParts=1`);
  assert.deepEqual(marked.sets.map((s) => [s.setNum, s.favourite]), [['200-1', true], ['100-1', false]]);
  const only = await json(`${base}/api/builds?minParts=1&favourites=1`);
  assert.equal(only.count, 1);
  assert.deepEqual(only.sets.map((s) => [s.setNum, s.favourite]), [['200-1', true]]);
  assert.equal((await json(`${base}/api/builds/200-1`)).favourite, true);
  assert.equal((await json(`${base}/api/builds/100-1`)).favourite, false);
  // The other filters still apply to a favourites-only list.
  assert.equal((await json(`${base}/api/builds?minParts=1&favourites=1&maxYear=2020`)).count, 0);
}));

test('favourites are saved with the inventory and survive clearing it', async () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fav-'));
  const file = path.join(dir, 'inventory.json');
  try {
    await withServer(async (base) => {
      await post(`${base}/api/inventory/add`, { items: [item('3001', 4, 2)] });
      await fetch(`${base}/api/favourites/100-1`, { method: 'PUT' });
      const saved = JSON.parse(fs.readFileSync(file, 'utf8'));
      assert.deepEqual(saved.favourites, ['100-1']);
      assert.deepEqual(saved.items, { '3001|4': 2 });
      assert.equal(saved.batches.length, 1);

      assert.equal((await json(`${base}/api/inventory`, { method: 'DELETE' })).pieces, 0);
      assert.deepEqual(await json(`${base}/api/favourites`), { sets: ['100-1'] });
      assert.deepEqual(JSON.parse(fs.readFileSync(file, 'utf8')).favourites, ['100-1']);
    }, { store: new InventoryStore(file) });
    const reopened = new InventoryStore(file);
    assert.deepEqual([...reopened.favourites], ['100-1']);
    assert.equal(reopened.list().length, 0);
    // A store file written before favourites existed still loads.
    fs.writeFileSync(file, JSON.stringify({ items: { '3001|4': 1 }, batches: [] }));
    assert.deepEqual([...new InventoryStore(file).favourites], []);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

// ───────── Import ─────────

const importCsv = (base, body) => fetch(`${base}/api/inventory/import`, { method: 'POST', headers: { 'Content-Type': 'text/csv' }, body });

test('an exported inventory can be imported again as one undoable batch', () => withServer(async (base) => {
  await post(`${base}/api/inventory/add`, { items: [item('3001', 4, 3), item('3069bpr0001', 1, 2)] });
  const exported = await (await fetch(`${base}/api/inventory.csv`)).text();
  await fetch(`${base}/api/inventory`, { method: 'DELETE' });

  const out = await (await importCsv(base, exported)).json();
  assert.equal(out.pieces, 5);
  assert.equal(out.lots, 2);
  assert.equal(out.skipped, 0);
  assert.deepEqual(out.added, { pieces: 5, lots: 2 });
  assert.deepEqual(out.items.map((i) => [i.partNum, i.colorId, i.qty]).sort(), [['3001', 4, 3], ['3069bpr0001', 1, 2]]);
  const { batches } = await json(`${base}/api/batches`);
  assert.deepEqual(batches.map((b) => [b.id, b.source, b.pieces, b.lots]), [[out.batchId, 'import', 5, 2]]);
  assert.equal((await json(`${base}/api/batches/${out.batchId}`, { method: 'DELETE' })).pieces, 0);
}));

test('import skips rows it cannot use and counts them', () => withServer(async (base) => {
  const body = '﻿Part,Color,Quantity\r\n' + [
    '3001,4,2',
    '3001,4,3',        // same lot again: added up
    '"3020",0, 1 ',    // quoted and padded fields
    'nope,4,1',        // unknown part
    '3001,999,1',      // unknown colour
    '3001,,1',         // no colour (not colour 0)
    '3001,4,0',        // bad quantities
    '3001,4,-2',
    '3001,4,1.5',
    '3001,4,many',
    '3001,4',
    '',
  ].join('\r\n');
  const out = await (await importCsv(base, body)).json();
  assert.equal(out.skipped, 8);
  assert.deepEqual(out.added, { pieces: 6, lots: 2 });
  assert.deepEqual(out.items.map((i) => [i.partNum, i.colorId, i.qty]).sort(), [['3001', 4, 5], ['3020', 0, 1]]);
  assert.equal(typeof out.batchId, 'string');
}));

test('import rejects a file with nothing in it', () => withServer(async (base) => {
  for (const body of ['', '\n\n', 'Part,Color,Quantity', 'Part,Color,Quantity\n', 'part,color,quantity\r\n\r\n']) {
    const res = await importCsv(base, body);
    assert.equal(res.status, 400, JSON.stringify(body));
    assert.ok((await res.json()).error);
  }
  // Rows, but none usable: also nothing to add.
  assert.equal((await importCsv(base, 'Part,Color,Quantity\nnope,4,1\n')).status, 400);
  // A file without the header line is still read.
  assert.equal((await (await importCsv(base, '3001,4,2\n')).json()).pieces, 2);
  assert.equal((await json(`${base}/api/batches`)).batches.length, 1);
}));

// ───────── Catalog date and swap ─────────

test('meta reports the catalog date, and setCatalog swaps the catalog without a restart', () => withServer(async (base, server) => {
  const before = await json(`${base}/api/meta`);
  assert.equal(before.catalogDate, '2026-03-04');
  assert.equal(before.setCount, 3);
  await post(`${base}/api/inventory/add`, { items: [item('3001', 4, 2)] });

  // A newer catalog with one more set.
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'cat-'));
  try {
    fs.cpSync(fixtures, dir, { recursive: true });
    fs.appendFileSync(path.join(dir, 'sets.csv'), '400-1,New Tower,2026,1,4,https://example.test/400.jpg\n');
    fs.appendFileSync(path.join(dir, 'inventories.csv'), '40,1,400-1\n');
    fs.appendFileSync(path.join(dir, 'inventory_parts.csv'), '40,3001,4,4,False,\n');
    server.setCatalog(await Catalog.load(dir), new Date('2026-11-15T08:00:00Z'));
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }

  const after = await json(`${base}/api/meta`);
  assert.equal(after.catalogDate, '2026-11-15');
  assert.equal(after.setCount, 4);
  const builds = await json(`${base}/api/builds?minParts=1&minYear=2026`);
  assert.deepEqual(builds.sets.map((s) => [s.setNum, s.owned]), [['400-1', 2]]); // the inventory carried over
  assert.deepEqual(await json(`${base}/api/favourites/400`, { method: 'PUT' }), { sets: ['400-1'] });
}, { catalogDate: new Date('2026-03-04T23:59:00Z') }));

test('meta has a null catalog date when it is not known', () => withServer(async (base) => {
  assert.equal((await json(`${base}/api/meta`)).catalogDate, null);
}));

// ───────── Robustness ─────────

test('a malformed URL gets an error response instead of stopping the server', () => withServer(async (base) => {
  assert.equal((await fetch(`${base}/%E0%A4%A`)).status, 400);
  assert.equal((await fetch(`${base}/api/builds/%E0%A4%A/missing.csv`)).status, 400);
  assert.equal((await fetch(`${base}/api/favourites/%E0%A4%A`, { method: 'PUT' })).status, 400);
  assert.equal((await fetch(`${base}/api/meta`)).status, 200);
}));
