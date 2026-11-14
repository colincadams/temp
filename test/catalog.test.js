'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const { Catalog } = require('../lib/catalog');
const { parseLine } = require('../lib/csv');

const load = () => Catalog.load(path.join(__dirname, 'fixtures'));
const item = (partNum, colorId, qty) => ({ partNum, colorId, qty });
const strict = { ignoreColor: false, variants: false, minParts: 1 };

test('parseLine handles quotes, commas and empty fields', () => {
  assert.deepEqual(parseLine('a,"b, c","say ""hi""",,e'), ['a', 'b, c', 'say "hi"', '', 'e']);
  assert.deepEqual(parseLine('1,2,'), ['1', '2', '']);
});

test('loads sets using the lowest inventory version and skips spares', async () => {
  const c = await load();
  const byNum = Object.fromEntries(c.sets.map((s) => [s.num, s.total]));
  assert.deepEqual(byNum, { '100-1': 5, '200-1': 10, '300-1': 0 });
  assert.equal(c.sets[0].rootTheme, 'City');
  assert.equal(c.parts[c.partIdx.get('3069bpr0001')].name, 'Tile 1 x 2 with "Go" Print');
});

test('exact matching counts only the right part in the right colour', async () => {
  const c = await load();
  const out = c.builds([item('3001', 4, 3), item('3020', 0, 5), item('3069b', 1, 1)], strict);
  assert.equal(out.count, 2); // the empty set is never listed
  const car = out.sets.find((s) => s.setNum === '100-1'), wall = out.sets.find((s) => s.setNum === '200-1');
  assert.equal(car.owned, 4);  // 2 bricks + 2 plates; plain tile is not the printed tile
  assert.equal(wall.owned, 3); // 3 of the 6 red bricks, none of the blue
  assert.equal(out.sets[0].setNum, '100-1'); // closest to complete first
});

test('variants option lets a plain part stand in for its printed version', async () => {
  const c = await load();
  const out = c.builds([item('3001', 4, 2), item('3020', 0, 2), item('3069b', 1, 1)], { ...strict, variants: true });
  assert.equal(out.complete, 1);
  assert.equal(out.sets[0].owned, 5);
});

test('ignoring colour never counts one physical piece twice', async () => {
  const c = await load();
  const out = c.builds([item('3001', 0, 7)], { ...strict, ignoreColor: true });
  assert.equal(out.sets.find((s) => s.setNum === '200-1').owned, 7); // 10 needed across two colours, only 7 owned
  const detail = c.buildDetail([item('3001', 0, 7)], '200-1', { ignoreColor: true, variants: false });
  assert.equal(detail.owned, 7);
  assert.equal(detail.parts.reduce((n, p) => n + p.need - p.have, 0), 3);
});

test('colour guesses come from colours the part exists in, nearest first', async () => {
  const c = await load();
  const cols = c.colorsForPart(c.partIdx.get('3001'), [37, 74, 149]); // a dark photo of a blue brick
  assert.deepEqual(cols.map((x) => x.name), ['Blue', 'Red']);
});

test('search finds parts by name words or number prefix', async () => {
  const c = await load();
  assert.equal(c.searchParts('brick 2 x 4')[0].partNum, '3001');
  assert.deepEqual(c.searchParts('3069').map((p) => p.partNum).sort(), ['3069b', '3069bpr0001']);
});
