'use strict';
const fs = require('node:fs');
const path = require('node:path');

/** Inventory persisted as JSON: { "partNum|colorId": quantity }. */
class InventoryStore {
  constructor(file) {
    this.file = file;
    this.items = new Map();
    if (file && fs.existsSync(file)) {
      const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
      for (const [k, v] of Object.entries(raw.items || {})) if (v > 0) this.items.set(k, v);
    }
  }

  static key(partNum, colorId) { return `${partNum}|${colorId}`; }

  get(partNum, colorId) { return this.items.get(InventoryStore.key(partNum, colorId)) || 0; }

  set(partNum, colorId, qty) {
    const k = InventoryStore.key(partNum, colorId);
    if (qty > 0) this.items.set(k, qty); else this.items.delete(k);
  }

  add(partNum, colorId, qty) { this.set(partNum, colorId, this.get(partNum, colorId) + qty); }

  clear() { this.items.clear(); }

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
    fs.writeFileSync(tmp, JSON.stringify({ items: Object.fromEntries(this.items) }));
    fs.renameSync(tmp, this.file);
  }
}

module.exports = { InventoryStore };
