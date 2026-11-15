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

const post = (url, body) => fetch(url, { method: 'POST', body: JSON.stringify(body) }).then((r) => r.json());

test('additions are batches that can be listed and undone', () => withServer(async (base) => {
  const first = await post(`${base}/api/inventory/add`, { source: 'scan', items: [{ partNum: '3001', colorId: 4, qty: 3 }, { partNum: '3020', colorId: 0, qty: 1 }] });
  await post(`${base}/api/inventory/add-set`, { setNum: '200' });
  assert.equal((await (await fetch(`${base}/api/inventory`)).json()).pieces, 14);
  const { batches } = await (await fetch(`${base}/api/batches`)).json();
  assert.deepEqual(batches.map((b) => [b.source, b.pieces, b.lots]), [['set 200-1 Big Wall', 10, 2], ['scan', 4, 2]]);
  const after = await (await fetch(`${base}/api/batches/${first.batchId}`, { method: 'DELETE' })).json();
  assert.equal(after.pieces, 10);
  assert.equal(after.items.find((i) => i.partNum === '3001' && i.colorId === 4).qty, 6);
  assert.equal((await fetch(`${base}/api/batches/${first.batchId}`, { method: 'DELETE' })).status, 404);
}));

test('builds can be sorted by fewest missing, filtered by year, and export the missing parts', () => withServer(async (base) => {
  await post(`${base}/api/inventory/add`, { items: [{ partNum: '3001', colorId: 4, qty: 6 }] });
  const byPercent = await (await fetch(`${base}/api/builds?minParts=1&variants=0`)).json();
  assert.deepEqual(byPercent.sets.map((s) => s.setNum), ['200-1', '100-1']);   // 6 of 10 beats 2 of 5
  const byMissing = await (await fetch(`${base}/api/builds?minParts=1&variants=0&sort=missing`)).json();
  assert.deepEqual(byMissing.sets.map((s) => s.setNum), ['100-1', '200-1']);   // 3 short beats 4 short
  const recent = await (await fetch(`${base}/api/builds?minParts=1&minYear=2021`)).json();
  assert.deepEqual(recent.sets.map((s) => s.setNum), ['200-1']);
  const csv = await (await fetch(`${base}/api/builds/200-1/missing.csv?variants=0`)).text();
  assert.equal(csv, 'Part,Color,Quantity\n3001,1,4\n');
}));

test('corrections save the crop under the right part number', async () => {
  const fs = require('node:fs'), os = require('node:os');
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'corr-'));
  const catalog = await Catalog.load(path.join(__dirname, 'fixtures'));
  const server = createApp({ catalog, store: new InventoryStore(null), correctionsDir: dir });
  await new Promise((r) => server.listen(0, '127.0.0.1', r));
  const base = `http://127.0.0.1:${server.address().port}`;
  try {
    const ok = await (await fetch(`${base}/api/corrections?partNum=3020&colorId=0&predicted=3001&longMm=31.5`, { method: 'POST', body: Buffer.alloc(500, 7) })).json();
    assert.deepEqual(fs.readdirSync(path.join(dir, '3020')), [`${ok.saved}.jpg`]);
    const record = JSON.parse(fs.readFileSync(path.join(dir, 'corrections.jsonl'), 'utf8'));
    assert.deepEqual([record.partNum, record.colorId, record.predicted, record.longMm], ['3020', 0, '3001', 31.5]);
    assert.equal((await fetch(`${base}/api/corrections?partNum=../../etc`, { method: 'POST', body: Buffer.alloc(500) })).status, 400);
  } finally { server.close(); fs.rmSync(dir, { recursive: true, force: true }); }
});
