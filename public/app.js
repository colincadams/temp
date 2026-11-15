'use strict';
/* global Segment */

const $ = (sel) => document.querySelector(sel);
const esc = (s) => String(s ?? '').replace(/[&<>"']/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]));
const debounce = (fn, ms = 250) => { let t; return (...a) => { clearTimeout(t); t = setTimeout(() => fn(...a), ms); }; };

async function api(path, opts = {}) {
  if (opts.json !== undefined) {
    opts = { ...opts, method: opts.method || 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify(opts.json) };
  }
  const res = await fetch(path, opts);
  const data = await res.json().catch(() => ({}));
  if (!res.ok) throw new Error(data.error || `Request failed (${res.status})`);
  return data;
}

let meta = { colors: [], themes: [] };

// ───────────────────────── Tabs ─────────────────────────
const tabs = ['scan', 'inventory', 'builds'];
function showTab(name) {
  for (const t of tabs) {
    $(`#tab-${t}`).hidden = t !== name;
    $(`nav [data-tab=${t}]`).classList.toggle('active', t === name);
  }
  if (name === 'inventory') loadInventory();
  if (name === 'builds') loadBuilds(true);
}
document.querySelectorAll('nav button').forEach((b) => b.addEventListener('click', () => showTab(b.dataset.tab)));

// ───────────────────────── Shared widgets ─────────────────────────
function colorOptions(known, selectedId) {
  const knownIds = new Set(known.map((c) => c.id));
  const opt = (c) => `<option value="${c.id}"${c.id === selectedId ? ' selected' : ''}>${esc(c.name)}</option>`;
  const others = meta.colors.filter((c) => !knownIds.has(c.id)).sort((a, b) => a.name.localeCompare(b.name));
  return (known.length ? `<optgroup label="Colours this part comes in">${known.map(opt).join('')}</optgroup>` : '') +
    `<optgroup label="Other colours">${others.map(opt).join('')}</optgroup>`;
}
const colorRgb = (id) => (meta.colors.find((c) => c.id === Number(id)) || {}).rgb || 'cccccc';
const swatch = (rgb) => `<span class="swatch" style="background:#${esc(rgb)}"></span>`;
const partImg = (url) => (url ? `<img loading="lazy" src="${esc(url)}" alt="">` : '<img alt="">');

// ───────────────────────── Scan ─────────────────────────
const scan = { source: null, work: null, boxes: [], scale: 1 };
const WORK_MAX = 640, SOURCE_MAX = 2400;

function fitCanvas(img, max) {
  const s = Math.min(1, max / Math.max(img.width, img.height));
  const c = document.createElement('canvas');
  c.width = Math.round(img.width * s); c.height = Math.round(img.height * s);
  c.getContext('2d', { willReadFrequently: true }).drawImage(img, 0, 0, c.width, c.height);
  return c;
}

async function loadPhoto(file) {
  if (!file) return;
  const img = new Image();
  img.src = URL.createObjectURL(file);
  try { await img.decode(); } catch { alert('Could not read that image.'); return; }
  scan.source = fitCanvas(img, SOURCE_MAX);
  scan.work = fitCanvas(scan.source, WORK_MAX);
  scan.scale = scan.source.width / scan.work.width;
  URL.revokeObjectURL(img.src);
  $('#results').hidden = true;
  $('#identify-status').textContent = '';
  detect();
  $('#detect').hidden = false;
  $('#detect').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

function detect() {
  const { work } = scan;
  const data = work.getContext('2d').getImageData(0, 0, work.width, work.height).data;
  scan.boxes = Segment.findPieces(data, work.width, work.height, { sensitivity: Number($('#sensitivity').value) })
    .map((b) => ({ ...b, on: true }));
  drawPreview();
}

function drawPreview() {
  const { source, boxes, scale } = scan;
  const cv = $('#preview');
  cv.width = source.width; cv.height = source.height;
  const ctx = cv.getContext('2d');
  ctx.drawImage(source, 0, 0);
  ctx.lineWidth = Math.max(3, source.width / 250);
  const fontPx = Math.round(Math.max(16, source.width / 45));
  ctx.font = `600 ${fontPx}px system-ui, sans-serif`;
  boxes.forEach((b, i) => {
    ctx.strokeStyle = b.on ? '#00c853' : 'rgba(160,160,160,.9)';
    ctx.setLineDash(b.on ? [] : [10, 8]);
    ctx.strokeRect(b.x * scale, b.y * scale, b.w * scale, b.h * scale);
    if (b.on) {
      const label = String(i + 1), tw = ctx.measureText(label).width + 10, th = fontPx + 6;
      ctx.fillStyle = '#00c853'; ctx.fillRect(b.x * scale, b.y * scale - th, tw, th);
      ctx.fillStyle = '#000'; ctx.fillText(label, b.x * scale + 5, b.y * scale - 6);
    }
  });
  const n = boxes.filter((b) => b.on).length;
  $('#detect-count').textContent = n;
  $('#identify').disabled = n === 0;
}

$('#preview').addEventListener('click', (e) => {
  const cv = e.currentTarget, r = cv.getBoundingClientRect();
  const x = (e.clientX - r.left) / r.width * cv.width / scan.scale;
  const y = (e.clientY - r.top) / r.height * cv.height / scan.scale;
  // Smallest box under the pointer wins, so nested boxes stay reachable.
  const hit = scan.boxes.filter((b) => x >= b.x && x <= b.x + b.w && y >= b.y && y <= b.y + b.h).sort((a, b) => a.w * a.h - b.w * b.h)[0];
  if (hit) { hit.on = !hit.on; drawPreview(); }
});
$('#sensitivity').addEventListener('input', () => scan.source && detect());
for (const id of ['#photo', '#photo-lib']) {
  $(id).addEventListener('change', (e) => { loadPhoto(e.target.files[0]); e.target.value = ''; });
}

function cropPiece(b) {
  const { source, scale } = scan;
  const pad = Math.max(b.w, b.h) * 0.15;
  const x = Math.max(0, (b.x - pad) * scale), y = Math.max(0, (b.y - pad) * scale);
  const w = Math.min(source.width - x, (b.w + pad * 2) * scale), h = Math.min(source.height - y, (b.h + pad * 2) * scale);
  const s = Math.min(1, 480 / Math.max(w, h));
  const c = document.createElement('canvas');
  c.width = Math.max(1, Math.round(w * s)); c.height = Math.max(1, Math.round(h * s));
  c.getContext('2d').drawImage(source, x, y, w, h, 0, 0, c.width, c.height);
  return c;
}

const toHex = (rgb) => rgb.map((v) => v.toString(16).padStart(2, '0')).join('');
let results = [];

async function identifyAll() {
  const boxes = scan.boxes.filter((b) => b.on);
  const btn = $('#identify'), status = $('#identify-status');
  btn.disabled = true;
  results = [];
  let done = 0, failed = 0, lastError = '';
  const queue = boxes.map((b, i) => ({ b, i }));
  const worker = async () => {
    for (let job; (job = queue.shift());) {
      const crop = cropPiece(job.b);
      try {
        const blob = await new Promise((r) => crop.toBlob(r, 'image/jpeg', 0.9));
        const out = await api(`/api/identify?rgb=${toHex(job.b.rgb)}`, { method: 'POST', headers: { 'Content-Type': 'image/jpeg' }, body: blob });
        results[job.i] = { crop, ...out };
      } catch (err) {
        failed++; lastError = err.message;
        results[job.i] = { crop, candidates: [], unmatched: [], error: err.message };
      }
      status.textContent = `Identifying… ${++done} of ${boxes.length}`;
    }
  };
  status.textContent = `Identifying… 0 of ${boxes.length}`;
  await Promise.all([worker(), worker()]);
  status.textContent = failed ? `${failed} of ${boxes.length} could not be identified: ${lastError}` : `Identified ${boxes.length} pieces.`;
  btn.disabled = false;
  renderResults();
}
$('#identify').addEventListener('click', identifyAll);

function renderResults() {
  const list = $('#result-list');
  list.innerHTML = '';
  results.forEach((r, i) => {
    const card = document.createElement('div');
    card.className = 'card';
    card.appendChild(r.crop);
    const body = document.createElement('div');
    body.className = 'body';
    card.appendChild(body);
    if (!r.candidates.length) {
      const guess = r.unmatched && r.unmatched[0];
      body.innerHTML = `<div class="name">Piece ${i + 1}: no match</div><div class="sub">${esc(r.error || (guess ? `Looks like “${guess.name}” (${guess.id}), which isn't in the set catalog.` : 'Not recognised.'))} You can add it by hand from the Inventory tab.</div>`;
      card.classList.add('off');
      r.include = false;
    } else {
      const top = r.candidates[0];
      r.include = top.score >= 0.4;
      r.pick = 0;
      body.innerHTML = `
        <div class="line"><input type="checkbox" class="inc" ${r.include ? 'checked' : ''} aria-label="Include piece ${i + 1}">
          <span class="name">Piece ${i + 1}</span><span class="score ${top.score < 0.6 ? 'low' : ''}">${Math.round(top.score * 100)}% sure</span></div>
        <select class="cand" aria-label="Part">${r.candidates.map((c, k) => `<option value="${k}">${esc(c.name)} (${esc(c.partNum)}) · ${Math.round(c.score * 100)}%</option>`).join('')}</select>
        <div class="line"><span class="sw"></span><select class="col" aria-label="Colour"></select></div>
        <div class="qty"><span class="sub">Count</span><input class="q" type="number" min="1" value="1" aria-label="Count"></div>`;
      const colSel = body.querySelector('.col'), sw = body.querySelector('.sw');
      const fillColors = () => {
        const cand = r.candidates[r.pick];
        colSel.innerHTML = colorOptions(cand.colors, cand.colors[0] ? cand.colors[0].id : undefined);
        sw.innerHTML = swatch(colorRgb(colSel.value));
      };
      fillColors();
      body.querySelector('.cand').addEventListener('change', (e) => { r.pick = Number(e.target.value); fillColors(); });
      colSel.addEventListener('change', () => { sw.innerHTML = swatch(colorRgb(colSel.value)); });
      body.querySelector('.inc').addEventListener('change', (e) => { r.include = e.target.checked; card.classList.toggle('off', !r.include); });
      card.classList.toggle('off', !r.include);
      r.read = () => ({ partNum: r.candidates[r.pick].partNum, colorId: Number(colSel.value), qty: Math.max(1, parseInt(body.querySelector('.q').value, 10) || 1) });
    }
    list.appendChild(card);
  });
  $('#results').hidden = false;
  $('#add-results').disabled = false;
  $('#results').scrollIntoView({ behavior: 'smooth', block: 'start' });
}

$('#add-results').addEventListener('click', async () => {
  const items = results.filter((r) => r.include && r.read).map((r) => r.read());
  if (!items.length) return;
  $('#add-results').disabled = true;
  try {
    // The same photo added twice would count every piece twice, so ask first if this looks like a repeat.
    const { similar } = await api('/api/batches/check', { json: { items } });
    if (similar && !confirm(`These look like the ${similar.pieces} pieces you already added on ${new Date(similar.at).toLocaleString()}. Add them again?`)) {
      $('#add-results').disabled = false;
      return;
    }
    const inv = await api('/api/inventory/add', { json: { items, source: 'photo scan' } });
    updateBadge(inv);
    $('#results').hidden = true;
    $('#detect').hidden = true;
    $('#identify-status').textContent = '';
    showTab('inventory');
    $('#inv-status').textContent = `Added ${items.reduce((n, i) => n + i.qty, 0)} pieces from your photo.`;
  } catch (err) {
    alert(err.message);
    $('#add-results').disabled = false;
  }
});

// ───────────────────────── Inventory ─────────────────────────
let inventory = { items: [], pieces: 0, lots: 0 };

function updateBadge(inv) {
  inventory = inv;
  loadBatches().catch(() => {});
  $('#inv-badge').textContent = inv.pieces;
  $('#inv-pieces').textContent = inv.pieces;
  $('#inv-lots').textContent = inv.lots;
}

async function loadInventory() {
  updateBadge(await api('/api/inventory'));
  renderInventory();
}

// Everything added so far, newest first, each with an Undo.
async function loadBatches() {
  const { batches } = await api('/api/batches');
  $('#batches-box').hidden = batches.length === 0;
  $('#batches').innerHTML = batches.slice(0, 30).map((b) => `
    <div class="row batch" data-id="${esc(b.id)}">
      <span class="grow">${esc(b.source)} · ${b.pieces} pieces <span class="hint">${esc(new Date(b.at).toLocaleString())}</span></span>
      <button class="btn">Undo</button>
    </div>`).join('');
}
$('#batches').addEventListener('click', async (e) => {
  const row = e.target.closest('.batch');
  if (!row || !e.target.closest('button')) return;
  updateBadge(await api(`/api/batches/${encodeURIComponent(row.dataset.id)}`, { method: 'DELETE' }));
  renderInventory();
  $('#inv-status').textContent = 'Removed that addition from your inventory.';
});

function renderInventory() {
  const f = $('#inv-filter').value.trim().toLowerCase();
  const items = inventory.items.filter((i) => !f || `${i.name} ${i.partNum} ${i.colorName}`.toLowerCase().includes(f));
  $('#inv-empty').hidden = inventory.items.length > 0;
  $('#inv-filter').hidden = inventory.items.length === 0;
  $('#inv-list').innerHTML = items.map((i) => `
    <div class="card" data-part="${esc(i.partNum)}" data-color="${i.colorId}">
      ${partImg(i.img)}
      <div class="body">
        <div class="name">${esc(i.name)}</div>
        <div class="sub">${swatch(i.rgb)} ${esc(i.colorName)} · ${esc(i.partNum)}</div>
        <div class="qty">
          <button data-d="-1" aria-label="One fewer">−</button>
          <input type="number" min="0" value="${i.qty}" aria-label="Quantity">
          <button data-d="1" aria-label="One more">+</button>
        </div>
      </div>
    </div>`).join('');
}

async function setQty(card, qty) {
  const inv = await api('/api/inventory/set', { json: { partNum: card.dataset.part, colorId: Number(card.dataset.color), qty: Math.max(0, qty) } });
  updateBadge(inv);
  renderInventory();
}
$('#inv-list').addEventListener('click', (e) => {
  const b = e.target.closest('button[data-d]');
  if (!b) return;
  const card = b.closest('.card');
  setQty(card, (parseInt(card.querySelector('input').value, 10) || 0) + Number(b.dataset.d));
});
$('#inv-list').addEventListener('change', (e) => {
  if (e.target.matches('input[type=number]')) setQty(e.target.closest('.card'), parseInt(e.target.value, 10) || 0);
});
$('#inv-filter').addEventListener('input', renderInventory);
$('#inv-clear').addEventListener('click', async () => {
  if (!inventory.pieces || !confirm(`Remove all ${inventory.pieces} pieces from your inventory?`)) return;
  updateBadge(await api('/api/inventory', { method: 'DELETE' }));
  renderInventory();
});

// Import a CSV in the format Export CSV produces.
$('#inv-import').addEventListener('change', async (e) => {
  const file = e.target.files[0];
  e.target.value = '';
  if (!file) return;
  try {
    const out = await api('/api/inventory/import', { method: 'POST', headers: { 'Content-Type': 'text/csv' }, body: file });
    updateBadge(out);
    renderInventory();
    const rows = out.skipped === 1 ? '1 row was' : `${out.skipped} rows were`;
    $('#inv-status').textContent = `Added ${out.added.pieces} pieces from ${file.name}.` +
      (out.skipped ? ` ${rows} skipped because the part, colour or quantity was not recognised.` : '');
  } catch (err) { $('#inv-status').textContent = `Could not import ${file.name}: ${err.message}`; }
});

// Manual add by search
$('#part-search').addEventListener('input', debounce(async (e) => {
  const q = e.target.value.trim();
  const box = $('#search-results');
  if (q.length < 2) { box.innerHTML = ''; return; }
  const { parts } = await api(`/api/parts/search?q=${encodeURIComponent(q)}`);
  if (e.target.value.trim() !== q) return;
  box.innerHTML = parts.length ? parts.map((p) => `
    <div class="card" data-part="${esc(p.partNum)}">
      ${partImg(p.img)}
      <div class="body">
        <div class="name">${esc(p.name)}</div>
        <div class="sub">${esc(p.partNum)}</div>
        <select aria-label="Colour">${colorOptions(p.colors, p.colors[0] ? p.colors[0].id : undefined)}</select>
        <div class="qty"><input type="number" min="1" value="1" aria-label="Quantity"><button class="btn add" style="width:auto;padding:0 12px">Add</button></div>
      </div>
    </div>`).join('') : '<p class="hint">No parts found.</p>';
}));
$('#search-results').addEventListener('click', async (e) => {
  if (!e.target.closest('.add')) return;
  const card = e.target.closest('.card');
  const qty = Math.max(1, parseInt(card.querySelector('input').value, 10) || 1);
  updateBadge(await api('/api/inventory/add', { json: { partNum: card.dataset.part, colorId: Number(card.querySelector('select').value), qty } }));
  renderInventory();
  $('#inv-status').textContent = `Added ${qty} × ${card.querySelector('.name').textContent}.`;
});

$('#add-set-form').addEventListener('submit', async (e) => {
  e.preventDefault();
  const setNum = $('#add-set').value.trim();
  if (!setNum) return;
  try {
    const out = await api('/api/inventory/add-set', { json: { setNum } });
    updateBadge(out);
    renderInventory();
    $('#add-set').value = '';
    $('#inv-status').textContent = `Added ${out.added.pieces} pieces from ${out.added.setNum} ${out.added.name}.`;
  } catch (err) { $('#inv-status').textContent = err.message; }
});

// ───────────────────────── Builds ─────────────────────────
const builds = { offset: 0, page: 60, seq: 0 };
const matchParams = () => `ignoreColor=${$('#b-color').checked ? 1 : 0}&variants=${$('#b-variants').checked ? 1 : 0}`;

const star = (setNum, on) => `<button type="button" class="star${on ? ' on' : ''}" data-set="${esc(setNum)}" aria-pressed="${on}"
  aria-label="${on ? 'Remove from favourites' : 'Add to favourites'}" title="${on ? 'Remove from favourites' : 'Add to favourites'}">${on ? '★' : '☆'}</button>`;

// A year filter only applies once a whole four-digit year has been typed.
function yearParams() {
  const year = (id) => { const v = parseInt($(id).value, 10); return v >= 1000 && v <= 9999 ? v : null; };
  const min = year('#b-year-min'), max = year('#b-year-max');
  return (min ? `&minYear=${min}` : '') + (max ? `&maxYear=${max}` : '');
}

async function loadBuilds(reset) {
  if (reset) builds.offset = 0;
  const seq = ++builds.seq;
  const favOnly = $('#b-fav').checked;
  const qs = `${matchParams()}&minParts=${encodeURIComponent($('#b-min').value || 20)}&q=${encodeURIComponent($('#b-q').value)}&theme=${encodeURIComponent($('#b-theme').value)}&sort=${$('#b-sort').value}${yearParams()}${favOnly ? '&favourites=1' : ''}&limit=${builds.page}&offset=${builds.offset}`;
  const out = await api(`/api/builds?${qs}`);
  if (seq !== builds.seq) return;
  const list = $('#b-list');
  if (reset) list.innerHTML = '';
  list.insertAdjacentHTML('beforeend', out.sets.map((s) => {
    const pct = s.owned / s.total, full = s.owned === s.total;
    return `<div class="set" role="button" tabindex="0" data-set="${esc(s.setNum)}">
      <img loading="lazy" src="${esc(s.img)}" alt="">
      ${star(s.setNum, s.favourite)}
      <div class="name">${esc(s.name)}</div>
      <div class="sub hint" style="margin:0">${esc(s.setNum)} · ${esc(s.theme)} · ${s.year}</div>
      <div class="bar ${full ? 'full' : ''}"><i style="width:${(pct * 100).toFixed(1)}%"></i></div>
      <div>${full ? '<span class="have">You can build this!</span>' : `${Math.floor(pct * 100)}% · missing ${s.total - s.owned} of ${s.total}`}</div>
    </div>`;
  }).join(''));
  builds.offset += out.sets.length;
  $('#b-more').hidden = builds.offset >= out.count;
  $('#b-summary').textContent = favOnly && out.count === 0
    ? 'No favourite sets match. Tap the star on a set to make it a favourite.'
    : inventory.pieces === 0 && !out.complete
      ? 'Your inventory is empty, so nothing is buildable yet. Scan some pieces first.'
      : `You can fully build ${out.complete} of ${out.count} matching ${favOnly ? 'favourite ' : ''}sets. Sorted by how close you are.`;
}
for (const id of ['#b-color', '#b-variants', '#b-theme', '#b-sort', '#b-fav']) $(id).addEventListener('change', () => loadBuilds(true));
for (const id of ['#b-q', '#b-min', '#b-year-min', '#b-year-max']) $(id).addEventListener('input', debounce(() => loadBuilds(true)));
$('#b-more').addEventListener('click', () => loadBuilds(false));

// Stars on the set cards and in the set dialog.
document.addEventListener('click', async (e) => {
  const btn = e.target.closest('.star');
  if (!btn) return;
  const setNum = btn.dataset.set, on = btn.getAttribute('aria-pressed') !== 'true';
  try {
    await api(`/api/favourites/${encodeURIComponent(setNum)}`, { method: on ? 'PUT' : 'DELETE' });
  } catch (err) { alert(err.message); return; }
  for (const el of document.querySelectorAll('.star')) if (el.dataset.set === setNum) el.outerHTML = star(setNum, on);
  if (!on && $('#b-fav').checked) loadBuilds(true);
});

async function openSet(setNum) {
  const d = await api(`/api/builds/${encodeURIComponent(setNum)}?${matchParams()}`);
  const missing = d.parts.filter((p) => p.have < p.need), have = d.parts.filter((p) => p.have >= p.need);
  const row = (p) => `
    <div class="card">${partImg(p.img)}<div class="body">
      <div class="name">${esc(p.name)}</div>
      <div class="sub">${swatch(p.rgb)} ${esc(p.colorName)} · ${esc(p.partNum)}</div>
      <div class="${p.have < p.need ? 'missing' : 'have'}">${p.have < p.need ? `Need ${p.need - p.have} more (have ${p.have} of ${p.need})` : `Have ${p.need} of ${p.need}`}</div>
    </div></div>`;
  $('#set-detail').innerHTML = `
    <h2>${star(d.setNum, d.favourite)}${esc(d.name)}</h2>
    <p class="hint">${esc(d.setNum)} · ${esc(d.theme)} · ${d.year} · you have ${d.owned} of ${d.total} pieces (${Math.floor(d.owned / d.total * 100)}%) ·
      <a href="https://rebrickable.com/sets/${encodeURIComponent(d.setNum)}/" target="_blank" rel="noopener">instructions &amp; details on Rebrickable</a></p>
    ${missing.length ? `<h2>Missing (${d.total - d.owned} pieces) <a class="btn" href="/api/builds/${encodeURIComponent(d.setNum)}/missing.csv?${matchParams()}" download>Export list</a></h2><div class="cards">${missing.map(row).join('')}</div>` : '<p class="have">You have every piece for this set.</p>'}
    ${have.length ? `<h2 style="margin-top:16px">Already have</h2><div class="cards">${have.map(row).join('')}</div>` : ''}`;
  $('#set-dialog').showModal();
  $('#set-dialog').scrollTop = 0;
}
$('#b-list').addEventListener('click', (e) => {
  const card = e.target.closest('.set');
  if (card && !e.target.closest('.star')) openSet(card.dataset.set);
});
$('#b-list').addEventListener('keydown', (e) => {
  if ((e.key === 'Enter' || e.key === ' ') && e.target.matches('.set')) { e.preventDefault(); openSet(e.target.dataset.set); }
});
$('#set-close').addEventListener('click', () => $('#set-dialog').close());

// ───────────────────────── Boot ─────────────────────────
(async function init() {
  meta = await api('/api/meta');
  $('#b-theme').insertAdjacentHTML('beforeend', meta.themes.map((t) => `<option>${esc(t)}</option>`).join(''));
  updateBadge(await api('/api/inventory'));
})().catch((err) => alert(`Could not load the app: ${err.message}`));
