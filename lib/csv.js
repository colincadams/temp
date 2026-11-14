'use strict';
const fs = require('node:fs');
const zlib = require('node:zlib');
const readline = require('node:readline');

/** Split one CSV record into fields (RFC 4180 quoting). */
function parseLine(line) {
  const out = [];
  let i = 0;
  const n = line.length;
  while (i <= n) {
    if (line[i] === '"') {
      let s = '';
      i++;
      for (;;) {
        const j = line.indexOf('"', i);
        if (j === -1) { s += line.slice(i); i = n; break; }
        s += line.slice(i, j);
        if (line[j + 1] === '"') { s += '"'; i = j + 2; } else { i = j + 1; break; }
      }
      out.push(s);
      i++; // skip comma
    } else {
      let j = line.indexOf(',', i);
      if (j === -1) j = n;
      out.push(line.slice(i, j));
      i = j + 1;
    }
  }
  return out;
}

function quotesBalanced(s) {
  let c = 0;
  for (let i = 0; i < s.length; i++) if (s.charCodeAt(i) === 34) c++;
  return c % 2 === 0;
}

/** Stream a (optionally gzipped) CSV file, calling onRow(fields) for each data row. */
async function readCsv(file, onRow) {
  let input = fs.createReadStream(file);
  if (file.endsWith('.gz')) input = input.pipe(zlib.createGunzip());
  const rl = readline.createInterface({ input, crlfDelay: Infinity });
  let header = true;
  let pending = null;
  for await (const raw of rl) {
    let line = raw;
    if (pending !== null) { line = pending + '\n' + raw; pending = null; }
    if (line.includes('"') && !quotesBalanced(line)) { pending = line; continue; }
    if (header) { header = false; continue; }
    if (line === '') continue;
    onRow(parseLine(line));
  }
}

module.exports = { parseLine, readCsv };
