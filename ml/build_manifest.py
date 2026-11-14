"""Choose which part shapes the recognition model learns, most common first.

Printed and re-moulded versions of a part are merged into one shape class: they are
the same physical shape, and the app's set matching treats them as interchangeable.

    python ml/build_manifest.py --catalog data --ldraw /path/to/ldraw --out ml/manifest.json
"""
import argparse
import csv
import gzip
import json
import os
from collections import Counter, defaultdict

import numpy as np

from ldraw import LDrawLibrary

SKIP_CATEGORIES = {"Stickers", "Non-Buildable Figures (Duplo, Fabuland, etc)", "Non-LEGO", "Other", "Duplo, Quatro and Primo",
                   "Minidoll Heads", "Minidoll Upper Body", "Minidoll Lower Body", "Minifigs", "Minifig Upper Body",
                   "Minifig Lower Body", "Minifig Heads", "Minifig Headwear", "Minifig Heads Special"}


def rows(catalog, name):
    with gzip.open(os.path.join(catalog, f"{name}.csv.gz"), "rt", encoding="utf-8", newline="") as f:
        yield from csv.DictReader(f)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--catalog", default="data")
    ap.add_argument("--ldraw", required=True)
    ap.add_argument("--out", default="ml/manifest.json")
    ap.add_argument("--max-classes", type=int, default=3000)
    ap.add_argument("--min-year", type=int, default=1990, help="ignore sets older than this when counting usage")
    args = ap.parse_args()

    lib = LDrawLibrary(args.ldraw)
    categories = {r["id"]: r["name"] for r in rows(args.catalog, "part_categories")}
    parts = {r["part_num"]: r for r in rows(args.catalog, "parts")}

    parent = {p: p for p in parts}
    def find(x):
        while parent[x] != x:
            parent[x] = parent[parent[x]]
            x = parent[x]
        return x
    for r in rows(args.catalog, "part_relationships"):
        if r["rel_type"] in "PTM" and r["child_part_num"] in parent and r["parent_part_num"] in parent:
            parent[find(r["child_part_num"])] = find(r["parent_part_num"])

    set_year = {r["set_num"]: int(r["year"]) for r in rows(args.catalog, "sets")}
    inventories = {r["id"]: r["set_num"] for r in rows(args.catalog, "inventories") if r["version"] == "1"}
    usage, colours = Counter(), defaultdict(Counter)
    for r in rows(args.catalog, "inventory_parts"):
        set_num = inventories.get(r["inventory_id"])
        if set_num is None or set_year.get(set_num, 0) < args.min_year or r["part_num"] not in parts:
            continue
        qty = int(r["quantity"])
        usage[r["part_num"]] += qty
        colours[find(r["part_num"])][int(r["color_id"])] += qty

    groups = defaultdict(list)
    for p in parts:
        groups[find(p)].append(p)

    total = sum(usage.values())
    classes, skipped_no_model = [], 0
    for root, members in groups.items():
        count = sum(usage[m] for m in members)
        if count == 0:
            continue
        # Represent the shape by its most used member that has a 3D model, preferring unprinted ones.
        candidates = sorted((m for m in members if lib.has_part(m)), key=lambda m: ("pr" in m or "pat" in m, -usage[m]))
        if categories.get(parts[root]["part_cat_id"]) in SKIP_CATEGORIES:
            continue
        if not candidates:
            skipped_no_model += count
            continue
        classes.append({"part_num": candidates[0], "name": parts[candidates[0]]["name"], "members": sorted(members),
                        "usage": count, "colours": dict(colours[root].most_common(40))})
    classes.sort(key=lambda c: -c["usage"])
    classes = classes[: args.max_classes]

    # Physical size of each shape: sorted bounding-box extents in millimetres.
    for i, c in enumerate(classes):
        verts, _, _ = lib.load_part(c["part_num"])
        c["class_id"] = i
        c["size_mm"] = [round(float(v), 1) for v in sorted(np.ptp(verts, axis=0), reverse=True)]

    covered = sum(c["usage"] for c in classes)
    with open(args.out, "w") as f:
        json.dump({"classes": classes}, f)
    print(f"{len(classes)} shape classes cover {covered / total:.1%} of all pieces in sets since {args.min_year}")
    print(f"pieces whose shape has no 3D model: {skipped_no_model / total:.1%}")
    for k in (250, 500, 1000, 2000):
        if k <= len(classes):
            print(f"  top {k}: {sum(c['usage'] for c in classes[:k]) / total:.1%}")


if __name__ == "__main__":
    main()
