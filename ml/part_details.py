"""Part details the phone needs to finish a scan without the server: name, picture and colours.

`ml/export.py` adds these to `classes.json`. They are read from the Rebrickable catalog CSVs the
server uses (`data/*.csv.gz`, see lib/catalog.js), counted the same way, so the phone's colour ranking
(BrickCore `ColorRanking`) gives the same answer as the server's `colorsForPart` for the colours kept.

Run on its own to inspect the result or measure its size:

    python ml/part_details.py --data data 3001 3023 3069b
    python ml/part_details.py --data data --classes ml/manifest.json --out /tmp/details.json

Format added to classes.json:

    "colors": [{"id": 4, "name": "Red", "rgb": "C91A09", "isTrans": false}, ...]   # every colour referenced below
    "classes": [{..., "details": {"name": "Brick 2 x 4", "img": "https://...", "colors": [[4, 1532], [1, 980], ...]}}]

`details.colors` lists [colour id, number of set inventory rows with the part in that colour], most common
first, at most `max_colors` of them. A class whose part is not in the catalog has no `details`.
"""
import argparse
import csv
import gzip
import io
import json
import os
import sys

IMG_PREFIX = "https://cdn.rebrickable.com/media/parts/"
DEFAULT_MAX_COLORS = 40


def _rows(data_dir, name):
    """Data rows (lists of fields) of `name`.csv.gz, or `name`.csv when there is no gzipped copy."""
    gz = os.path.join(data_dir, f"{name}.csv.gz")
    if os.path.exists(gz):
        f = gzip.open(gz, "rt", encoding="utf-8", newline="")
    else:
        f = io.open(os.path.join(data_dir, f"{name}.csv"), "r", encoding="utf-8", newline="")
    with f:
        reader = csv.reader(f)
        next(reader, None)  # header
        for row in reader:
            if row:
                yield row


def _is_true(text):
    return text in ("True", "t")


def load_part_details(data_dir, part_nums, max_colors=DEFAULT_MAX_COLORS):
    """Name, picture and colours of each part in `part_nums`.

    Counts follow lib/catalog.js: one inventory per set (the lowest version, the first listed on a tie), every
    row of it including spares, colours not in colors.csv skipped. The picture is the one the server shows
    for the part's most common colour.

    Returns (details, colors): `details` maps part number to {"name", "img", "colors": [[id, uses], ...]} for the
    parts found in the catalog; `colors` is the colour table for every id referenced, sorted by id.
    """
    wanted = set(part_nums)

    colors = {}
    for row in _rows(data_dir, "colors"):
        cid = int(row[0])
        colors[cid] = {"id": cid, "name": row[1], "rgb": row[2], "isTrans": _is_true(row[3])}

    names = {}
    for row in _rows(data_dir, "parts"):
        if row[0] in wanted:
            names[row[0]] = row[1]

    set_nums = None
    sets_file = os.path.join(data_dir, "sets.csv.gz")
    if os.path.exists(sets_file) or os.path.exists(os.path.join(data_dir, "sets.csv")):
        set_nums = {row[0] for row in _rows(data_dir, "sets")}

    best = {}  # set number -> (version, inventory id)
    for row in _rows(data_dir, "inventories"):
        inv_id, version, set_num = int(row[0]), int(row[1]), row[2]
        if set_nums is not None and set_num not in set_nums:
            continue
        cur = best.get(set_num)
        if cur is None or version < cur[0]:
            best[set_num] = (version, inv_id)
    inventories = {inv_id for _, inv_id in best.values()}

    uses = {}       # part -> {colour id: rows}; dicts keep first-seen order, which breaks ties as the server does
    key_img = {}    # (part, colour id) -> first picture
    part_img = {}   # part -> first picture in any colour
    for row in _rows(data_dir, "inventory_parts"):
        part = row[1]
        if part not in wanted or int(row[0]) not in inventories:
            continue
        cid = int(row[2])
        if cid not in colors:
            continue
        per_part = uses.setdefault(part, {})
        per_part[cid] = per_part.get(cid, 0) + 1
        img = row[5] if len(row) > 5 else ""
        if img.startswith(IMG_PREFIX):
            key_img.setdefault((part, cid), img)
            part_img.setdefault(part, img)

    details, used_colors = {}, set()
    for part in part_nums:
        if part in details or (part not in names and part not in uses):
            continue
        counts = uses.get(part, {})
        order = {cid: i for i, cid in enumerate(counts)}
        ranked = sorted(counts.items(), key=lambda kv: (-kv[1], order[kv[0]]))[:max_colors]
        img = None
        if ranked:
            img = key_img.get((part, ranked[0][0]))
        img = img or part_img.get(part)
        details[part] = {"name": names.get(part, part), "img": img, "colors": [[cid, n] for cid, n in ranked]}
        used_colors.update(cid for cid, _ in ranked)
    return details, [colors[cid] for cid in sorted(used_colors)]


def add_details(classes, data_dir, max_colors=DEFAULT_MAX_COLORS):
    """Add `details` to each class (a dict with "partNum"), in place. Returns the colour table for classes.json."""
    details, colors = load_part_details(data_dir, [c["partNum"] for c in classes], max_colors)
    for c in classes:
        if c["partNum"] in details:
            c["details"] = details[c["partNum"]]
    return colors


def main():
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("parts", nargs="*", help="part numbers")
    ap.add_argument("--data", default="data", help="folder with the Rebrickable catalog CSVs")
    ap.add_argument("--classes", help="a classes.json or manifest.json whose classes to describe")
    ap.add_argument("--max-colors", type=int, default=DEFAULT_MAX_COLORS)
    ap.add_argument("--out", help="write {classes, colors} here instead of printing it")
    args = ap.parse_args()

    if args.classes:
        with open(args.classes) as f:
            raw = json.load(f)["classes"]
        classes = [{"partNum": c.get("partNum", c.get("part_num"))} for c in raw]
    else:
        classes = [{"partNum": p} for p in args.parts]
    colors = add_details(classes, args.data, args.max_colors)
    text = json.dumps({"classes": classes, "colors": colors}, separators=(",", ":"))
    if args.out:
        with open(args.out, "w") as f:
            f.write(text)
        found = sum(1 for c in classes if "details" in c)
        print(f"wrote {args.out}: {found} of {len(classes)} parts described, {len(text)} bytes", file=sys.stderr)
    else:
        print(text)


if __name__ == "__main__":
    main()
