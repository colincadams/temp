'use strict';
const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');

/**
 * Inventory persisted as JSON: quantities per "partNum|colorId", plus the batches (scans, sets,
 * manual additions) that produced them, so any batch can be undone, and the sets marked as favourites.
 */
class InventoryStore {
  constructor(file) {
    this.file = file;
    this.items = new Map();
    this.batches = [];
    this.favourites = new Set(); // set numbers
    if (file && fs.existsSync(file)) {
      const raw = JSON.parse(fs.readFileSync(file, 'utf8'));
      for (const [k, v] of Object.entries(raw.items || {})) if (v > 0) this.items.set(k, v);
      this.batches = Array.isArray(raw.batches) ? raw.batches : [];
      if (Array.isArray(raw.favourites)) this.favourites = new Set(raw.favourites.map(String));
    }
  }

  static key(partNum, colorId) { return `${partNum}|${colorId}`; }

  get(partNum, colorId) { return this.items.get(InventoryStore.key(partNum, colorId)) || 0; }

  set(partNum, colorId, qty) {
    const k = InventoryStore.key(partNum, colorId);
    if (qty > 0) this.items.set(k, qty); else this.items.delete(k);
  }

  add(partNum, colorId, qty) { this.set(partNum, colorId, this.get(partNum, colorId) + qty); }

  /** Empty the inventory. Favourites are about sets, not pieces, so they stay. */
  clear() { this.items.clear(); this.batches = []; }

  /**
   * The existing batch most like `items`, or null if none shares at least `threshold` of its pieces.
   * Overlap is the pieces the two have in common (the smaller quantity of each part-and-colour lot)
   * divided by the piece count of the larger of the two.
   */
  similarBatch(items, threshold = 0.7) {
    const tally = (list) => {
      const lots = new Map();
      let pieces = 0;
      for (const it of list) {
        if (!(it.qty > 0)) continue;
        const k = InventoryStore.key(it.partNum, it.colorId);
        lots.set(k, (lots.get(k) || 0) + it.qty);
        pieces += it.qty;
      }
      return { lots, pieces };
    };
    const mine = tally(items);
    if (!mine.pieces) return null;
    let best = null;
    for (let i = this.batches.length - 1; i >= 0; i--) { // newest first, so the newest wins a tie
      const b = this.batches[i], theirs = tally(b.items);
      if (!theirs.pieces) continue;
      let shared = 0;
      for (const [k, qty] of mine.lots) shared += Math.min(qty, theirs.lots.get(k) || 0);
      const overlap = shared / Math.max(mine.pieces, theirs.pieces);
      if (overlap >= threshold && (!best || overlap > best.overlap)) best = { id: b.id, at: b.at, source: b.source, pieces: theirs.pieces, overlap };
    }
    return best;
  }

  /**
   * Add items as one undoable batch. `source` says where they came from, e.g. "scan" or "set 31058-1".
   * `clientId`, when given, identifies the client's save: a second save with the same id (a retry after a lost
   * reply) adds nothing and returns the original batch with `repeated: true`.
   */
  addBatch(items, source, clientId) {
    if (clientId) {
      const earlier = this.batches.find((b) => b.clientId === clientId);
      if (earlier) return { ...earlier, repeated: true };
    }
    const batch = { id: crypto.randomUUID(), at: new Date().toISOString(), source: String(source || 'manual').slice(0, 80), items };
    if (clientId) batch.clientId = clientId;
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
    fs.writeFileSync(tmp, JSON.stringify({ items: Object.fromEntries(this.items), batches: this.batches, favourites: [...this.favourites] }));
    fs.renameSync(tmp, this.file);
  }
}

module.exports = { InventoryStore };
