'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { Catalog } = require('../lib/catalog');
const { InventoryStore } = require('../lib/store');
const { createApp } = require('../server');

async function withServer(fn) {
  const catalog = await Catalog.load(path.join(__dirname, 'fixtures'));
  const identify = async () => [{ id: '3020', name: 'Plate 2 x 4', score: 0.6 }, { id: '3001', name: 'Brick 2 x 4', score: 0.5 }, { id: 'nope', name: '?', score: 0.4 }];
  const server = createApp({ catalog, store: new InventoryStore(null), identify });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try { await fn(base); } finally { server.close(); }
}

test('parts/info returns known parts with colours ranked by the measured colour', () => withServer(async (base) => {
  const out = await (await fetch(`${base}/api/parts/info?nums=3001,missing,3020&rgb=254a95`)).json();
  assert.deepEqual(out.parts.map((p) => p.partNum), ['3001', '3020']);
  assert.equal(out.parts[0].colors[0].name, 'Blue');
  assert.equal(out.parts[0].score, 0);
}));

test('identify maps to catalog parts, reports unmatched ones, and add/builds round-trip', () => withServer(async (base) => {
  const id = await (await fetch(`${base}/api/identify?rgb=c91a09`, { method: 'POST', body: Buffer.from('x') })).json();
  assert.deepEqual(id.candidates.map((c) => c.partNum), ['3020', '3001']);
  assert.equal(id.unmatched[0].id, 'nope');
  const add = await (await fetch(`${base}/api/inventory/add`, { method: 'POST', body: JSON.stringify({ items: [{ partNum: '3001', colorId: 4, qty: 2 }] }) })).json();
  assert.equal(add.pieces, 2);
  const builds = await (await fetch(`${base}/api/builds?minParts=1`)).json();
  assert.equal(builds.sets[0].setNum, '100-1');
  assert.equal(builds.sets[0].owned, 2);
  const bad = await fetch(`${base}/api/inventory/add`, { method: 'POST', body: JSON.stringify({ partNum: 'zzz', colorId: 4, qty: 1 }) });
  assert.equal(bad.status, 400);
}));
