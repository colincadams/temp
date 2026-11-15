'use strict';
const test = require('node:test');
const assert = require('node:assert/strict');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const { Catalog, FILES, catalogDate, isStale, refreshCatalog } = require('../lib/catalog');

const fixtures = path.join(__dirname, 'fixtures');
const DAY = 24 * 60 * 60 * 1000;

function tempCatalog() {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), 'fresh-'));
  fs.cpSync(fixtures, dir, { recursive: true });
  return dir;
}

test('the catalog date is the modification time of its oldest file', () => {
  const dir = tempCatalog();
  try {
    const newer = new Date('2026-11-01T10:00:00Z'), older = new Date('2026-09-20T07:30:00Z');
    for (const name of FILES) fs.utimesSync(path.join(dir, `${name}.csv`), newer, newer);
    assert.equal(catalogDate(dir).toISOString(), newer.toISOString());
    fs.utimesSync(path.join(dir, 'sets.csv'), older, older);
    assert.equal(catalogDate(dir).toISOString(), older.toISOString());
    // Files that are not part of the catalog do not count.
    fs.writeFileSync(path.join(dir, 'inventory.json'), '{}');
    fs.utimesSync(path.join(dir, 'inventory.json'), new Date('2020-01-01'), new Date('2020-01-01'));
    assert.equal(catalogDate(dir).toISOString(), older.toISOString());
    // A .csv.gz is used in preference to a .csv, as when loading.
    fs.writeFileSync(path.join(dir, 'sets.csv.gz'), '');
    fs.utimesSync(path.join(dir, 'sets.csv.gz'), newer, newer);
    assert.equal(catalogDate(dir).toISOString(), newer.toISOString());
    // The relationships file is optional; any other missing file means there is no date.
    fs.rmSync(path.join(dir, 'part_relationships.csv'));
    assert.equal(catalogDate(dir).toISOString(), newer.toISOString());
    fs.rmSync(path.join(dir, 'themes.csv'));
    assert.equal(catalogDate(dir), null);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('a catalog is stale after more than 14 days', () => {
  const now = new Date('2026-11-15T12:00:00Z');
  assert.equal(isStale(new Date(now - 15 * DAY), now), true);
  assert.equal(isStale(new Date(now - 14 * DAY - 1000), now), true);
  assert.equal(isStale(new Date(now - 14 * DAY), now), false);
  assert.equal(isStale(new Date(now - DAY), now), false);
  assert.equal(isStale(now, now), false);
  assert.equal(isStale(null, now), false);
  assert.equal(isStale(new Date(now - 3 * DAY), now, 2), true);
});

test('refreshCatalog downloads, loads the whole catalog, then swaps it in', async () => {
  const dir = tempCatalog();
  try {
    const steps = [], log = [];
    let swapped = null;
    const ok = await refreshCatalog({
      dir,
      log: (l) => log.push(l),
      download: async (d, opts) => {
        steps.push(['download', d, opts.refresh]);
        fs.appendFileSync(path.join(d, 'sets.csv'), '400-1,New Tower,2026,1,4,https://example.test/400.jpg\n');
      },
      swap: (catalog, date) => { steps.push(['swap']); swapped = { catalog, date }; },
    });
    assert.equal(ok, true);
    assert.deepEqual(steps, [['download', dir, true], ['swap']]);
    assert.ok(swapped.catalog instanceof Catalog);
    assert.equal(swapped.catalog.sets.length, 4);
    assert.equal(swapped.catalog.setIdx.has('400-1'), true);
    assert.equal(swapped.date.toISOString(), catalogDate(dir).toISOString());
    assert.match(log.at(-1), /^Catalog updated: 4 sets/);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});

test('refreshCatalog keeps the old catalog when the download or the load fails', async () => {
  let swaps = 0;
  const swap = () => { swaps++; };
  const log = [];
  const failedDownload = await refreshCatalog({ dir: fixtures, swap, log: (l) => log.push(l), download: async () => { throw new Error('HTTP 503'); },
    load: async () => { throw new Error('must not load after a failed download'); } });
  assert.equal(failedDownload, false);
  assert.match(log.at(-1), /Could not update the catalog, keeping the current one: HTTP 503/);

  const failedLoad = await refreshCatalog({ dir: fixtures, swap, log: (l) => log.push(l), download: async () => {}, load: async () => { throw new Error('unexpected end of file'); } });
  assert.equal(failedLoad, false);
  assert.match(log.at(-1), /keeping the current one: unexpected end of file/);

  // A truncated download fails in the real loader too, before anything is swapped.
  const dir = tempCatalog();
  try {
    const failedReal = await refreshCatalog({ dir, swap, download: async (d) => { fs.rmSync(path.join(d, 'colors.csv')); } });
    assert.equal(failedReal, false);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
  assert.equal(swaps, 0);
});
