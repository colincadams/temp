'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

/**
 * Inventory persisted as JSON: quantities per "partNum|colorId", plus the batches (scans, sets,
 * manual additions) that produced them, so any batch can be undone.
 */
class InventoryStore {
  constructor(file) {
    this.file = file;
    this.items = new Map();
    this.batches = [];
    if (file && fs.existsSync(file)) {
      const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
      for (const [k, v] of Object.entries(raw.items || {})) if (v > 0) this.items.set(k, v);
      this.batches = Array.isArray(raw.batches) ? raw.batches : [];
    }
  }

  static key(partNum, colorId) { return `${partNum}|${colorId}`; }

  get(partNum, colorId) { return this.items.get(InventoryStore.key(partNum, colorId)) || 0; }

  set(partNum, colorId, qty) {
    const k = InventoryStore.key(partNum, colorId);
    if (qty > 0) this.items.set(k, qty); else this.items.delete(k);
  }

  add(partNum, colorId, qty) { this.set(partNum, colorId, this.get(partNum, colorId) + qty); }

  clear() { this.items.clear(); this.batches = []; }

  /** Add items as one undoable batch. `source` says where they came from, e.g. "scan" or "set 31058-1". */
  addBatch(items, source) {
    const batch = { id: crypto.randomUUID(), at: new Date().toISOString(), source: String(source || 'manual').slice(0, 80), items };
    for (const it of items) this.add(it.partNum, it.colorId, it.qty);
    this.batches.push(batch);
    if (this.batches.length > 500) this.batches.shift();
    return batch;
  }

  /** Take a batch's pieces back out. Quantities never go below zero. Returns false if there is no such batch. */
  undoBatch(id) {
    const i = this.batches.findIndex((b) => b.id === id);
    if (i === -1) return false;
    for (const it of this.batches[i].items) this.set(it.partNum, it.colorId, Math.max(0, this.get(it.partNum, it.colorId) - it.qty));
    this.batches.splice(i, 1);
    return true;
  }

  /** @returns {{partNum:string,colorId:number,qty:number}[]} */
  list() {
    const out = [];
    for (const [k, qty] of this.items) {
      const i = k.lastIndexOf('|');
      out.push({ partNum: k.slice(0, i), colorId: Number(k.slice(i + 1)), qty });
    }
    return out;
  }

  save() {
    if (!this.file) return;
    fs.mkdirSync(path.dirname(this.file), { recursive: true });
    const tmp = this.file + '.tmp';
    fs.writeFileSync(tmp, JSON.stringify({ items: Object.fromEntries(this.items), batches: this.batches }));
    fs.renameSync(tmp, this.file);
  }
}

module.exports = { InventoryStore };
