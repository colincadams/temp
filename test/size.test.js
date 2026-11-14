'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const { nameStuds, sizeFactor, rerankBySize } = require('../lib/size');

test('reads the longest side from part names', () => {
  assert.equal(nameStuds('Plate 2 x 4'), 4);
  assert.equal(nameStuds('Brick Sloped 45° 2 x 2'), 2);
  assert.equal(nameStuds('Technic Beam 1 x 11 Thick'), 11);
  assert.equal(nameStuds('Minifig Head'), null);
  assert.equal(nameStuds('Tyre 21 x 12'), null);
});

test('measured length promotes the candidate of the right size', () => {
  const cands = [
    { partNum: '3710', name: 'Plate 1 x 4', score: 0.7 },
    { partNum: '3023', name: 'Plate 1 x 2', score: 0.6 },
    { partNum: 'x', name: 'Minifig Head', score: 0.1 },
  ];
  assert.equal(rerankBySize(cands, 16.5)[0].partNum, '3023');
  assert.equal(rerankBySize(cands, 33)[0].partNum, '3710');
  assert.deepEqual(rerankBySize(cands, NaN), cands); // no measurement: unchanged
  assert.equal(rerankBySize(cands, 0), cands);
});

test('size factor is bounded and tolerant of small errors', () => {
  assert.ok(sizeFactor('Brick 2 x 4', 34) > 0.9);
  assert.equal(sizeFactor('Brick 2 x 4', 200), 0.15);
  assert.equal(sizeFactor('Minifig Head', 50), 1);
});
