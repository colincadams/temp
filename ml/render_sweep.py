"""Render a phone's zig-zag sweep over one table of pieces, for testing the scan pipeline without a phone.

Writes numbered frames plus sweep.json, which holds what ARKit would report for each frame (camera
intrinsics and camera-to-world transform, in ARKit's conventions: metres, Y up, camera looking along its
-Z axis) and the ground truth: every piece on the table with its part, colour and position, plus the true
size of its footprint (`longMm`, `shortMm`: sides of the smallest rectangle around it seen from straight
above; `heightMm`: how far it stands off the table) and its colour as `rgb`.

Each frame is also written as raw pixels at the detector's working resolution (NNNN.rgba, see sweep_frames.py),
which the replay tool reads. With --ids, a second flat-colour pass writes a piece-number map per frame
(NNNN_ids.png, 16-bit: 0 = table, id + 1 = piece), as render_scenes.py does, plus NNNN.ids at working resolution.

    python ml/render_sweep.py --ldraw ml/ldraw --out ml/sweeps/001 --seed 1 --ids
"""
import argparse
import csv
import gzip
import json
import math
import os
import random

import bpy
import numpy as np
from mathutils import Vector
from PIL import Image
from scipy.spatial import ConvexHull

from ldraw import LDrawLibrary
from render import PartFactory, randomise_environment, setup_scene
from render_scenes import decode_ids, id_material, lay_out
from sweep_frames import write_frames

# Blender is Z up in millimetres; ARKit is Y up in metres. A rotation, not a mirror.
TO_ARKIT = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], dtype=np.float64)


def arkit_transform(matrix_world):
    m = np.array(matrix_world)
    out = np.eye(4)
    out[:3, :3] = TO_ARKIT @ m[:3, :3]
    out[:3, 3] = TO_ARKIT @ m[:3, 3] / 1000
    return out


def footprint(obj):
    """Sides of the smallest rectangle around the piece seen from straight above, and its height (mm)."""
    mesh = obj.data
    verts = np.empty(len(mesh.vertices) * 3)
    mesh.vertices.foreach_get("co", verts)
    m = np.array(obj.matrix_world)
    world = verts.reshape(-1, 3) @ m[:3, :3].T + m[:3, 3]
    hull = world[:, :2][ConvexHull(world[:, :2]).vertices]
    best = None
    for a, b in zip(hull, np.roll(hull, -1, axis=0)):   # the smallest rectangle has a side along a hull edge
        length = float(np.hypot(*(b - a)))
        if length < 1e-9:
            continue
        u = (b - a) / length
        along, across = hull @ u, hull @ np.array([-u[1], u[0]])
        sides = (float(along.max() - along.min()), float(across.max() - across.min()))
        if best is None or sides[0] * sides[1] < best[0] * best[1]:
            best = sides
    return max(best), min(best), float(world[:, 2].max() - world[:, 2].min())


def render_ids(scene, objects, table, sun, poses):
    """Second pass: every piece glows in its own flat colour, with no lighting, to give exact outlines."""
    table.data.materials[0] = id_material(0)
    for i, obj in enumerate(objects):
        mat = id_material(i + 1)
        for slot in range(len(obj.data.materials)):
            obj.data.materials[slot] = mat
    sun.data.energy = 0
    scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0
    scene.view_settings.exposure = 0
    scene.render.dither_intensity = 0
    scene.cycles.samples = 1
    scene.cycles.filter_width = 0.01
    scene.render.image_settings.file_format = "PNG"
    for n, (pose, ids_path) in enumerate(poses):
        pose()
        raw = ids_path[: -len("_ids.png")] + "_raw.png"
        scene.render.filepath = raw
        bpy.ops.render.render(write_still=True)
        Image.fromarray(decode_ids(raw)).save(ids_path, format="PNG")
        os.remove(raw)
        print(f"piece map {n + 1}/{len(poses)}", flush=True)


def sweep_path(table_w, table_h, view_h, rng, speed=150.0, interval=0.2):
    """Camera positions (mm) every `interval` seconds along overlapping rows across the table."""
    rows = max(1, math.ceil(table_h / (view_h * 0.6)))
    ys = np.linspace(-table_h / 2 + view_h * 0.3, table_h / 2 - view_h * 0.3, rows) if rows > 1 else [0.0]
    corners = []
    for i, y in enumerate(ys):
        xs = (-table_w / 2, table_w / 2) if i % 2 == 0 else (table_w / 2, -table_w / 2)
        corners += [(xs[0], y), (xs[1], y)]
    points, step = [], speed * interval
    for (x0, y0), (x1, y1) in zip(corners, corners[1:]):
        n = max(1, int(math.hypot(x1 - x0, y1 - y0) / step))
        points += [(x0 + (x1 - x0) * k / n, y0 + (y1 - y0) * k / n) for k in range(n)]
    points.append(corners[-1])
    # A hand is not a rail: wander a little.
    return [(x + rng.uniform(-6, 6), y + rng.uniform(-6, 6)) for x, y in points]


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default="ml/manifest.json")
    ap.add_argument("--ldraw", required=True)
    ap.add_argument("--catalog", default="data")
    ap.add_argument("--out", required=True)
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--table-width", type=float, default=600, help="millimetres")
    ap.add_argument("--table-depth", type=float, default=400, help="millimetres")
    ap.add_argument("--height", type=float, default=320, help="camera height above the table, millimetres")
    ap.add_argument("--image-width", type=int, default=1920)
    ap.add_argument("--image-height", type=int, default=1440)
    ap.add_argument("--samples", type=int, default=16)
    ap.add_argument("--max-classes", type=int, default=600)
    ap.add_argument("--max-frames", type=int, default=None)
    ap.add_argument("--ids", action="store_true", help="also write a piece-number map per frame (a quick second render pass)")
    args = ap.parse_args()

    rng = random.Random(args.seed)
    classes = json.load(open(args.manifest))["classes"][: args.max_classes]
    class_of = {c["part_num"]: c["class_id"] for c in classes}
    with gzip.open(os.path.join(args.catalog, "colors.csv.gz"), "rt", encoding="utf-8") as f:
        palette = {int(r["id"]): {"id": int(r["id"]), "rgb": tuple(int(r["rgb"][i:i + 2], 16) / 255 for i in (0, 2, 4)),
                                  "trans": r["is_trans"] in ("True", "t")} for r in csv.DictReader(f) if int(r["id"]) >= 0}
    common = [palette[i] for i in (0, 1, 2, 4, 14, 15, 19, 25, 28, 70, 71, 72, 272, 320) if i in palette]

    scene, table_mat, sun, camera = setup_scene(args.image_width, args.samples)
    scene.render.resolution_x, scene.render.resolution_y = args.image_width, args.image_height
    factory = PartFactory(LDrawLibrary(args.ldraw))

    pieces, objects = [], []
    for n, (part, colour, pose, x, y) in enumerate(lay_out(factory, classes, palette, common, args.table_width / 2, args.table_depth / 2, rng)):
        obj, centre, radius = factory.place(part, colour, (x, y), rng, pose)
        objects.append(obj)
        position = TO_ARKIT @ np.array([centre.x, centre.y, 0.0]) / 1000
        long_mm, short_mm, height_mm = footprint(obj)
        pieces.append({"id": n, "partNum": part, "classId": class_of[part], "colorId": colour["id"],
                       "x": round(float(position[0]), 5), "z": round(float(position[2]), 5), "radiusMm": round(radius, 1),
                       "longMm": round(long_mm, 1), "shortMm": round(short_mm, 1), "heightMm": round(height_mm, 1),
                       "rgb": "".join(f"{round(c * 255):02x}" for c in colour["rgb"])})
    randomise_environment(scene, table_mat, sun, rng)

    fov = math.radians(63)
    camera.data.sensor_fit = "HORIZONTAL"
    camera.data.angle = fov
    camera.data.clip_start, camera.data.clip_end = 1, 5000
    focal = args.image_width / 2 / math.tan(fov / 2)
    view_h = 2 * args.height * math.tan(fov / 2) * args.image_height / args.image_width

    os.makedirs(args.out, exist_ok=True)
    frames, poses = [], []
    path = sweep_path(args.table_width, args.table_depth, view_h, rng)[: args.max_frames]
    for i, (x, y) in enumerate(path):
        location = Vector((x, y, args.height + rng.uniform(-8, 8)))
        # Held roughly flat: a few degrees of tilt, long side of the frame along the direction of travel.
        rotation = (math.radians(rng.uniform(-5, 5)), math.radians(rng.uniform(-5, 5)), math.radians(rng.uniform(-4, 4)))

        def pose(location=location, rotation=rotation):
            camera.location, camera.rotation_euler = location, rotation
            bpy.context.view_layer.update()

        pose()
        poses.append((pose, os.path.join(args.out, f"{i:04d}_ids.png")))
        name = f"{i:04d}.jpg"
        scene.render.filepath = os.path.join(args.out, name)
        bpy.ops.render.render(write_still=True)
        frames.append({"file": name, "time": round(i * 0.2, 3),
                       "transform": [round(float(v), 6) for v in arkit_transform(camera.matrix_world).T.ravel()]})   # column-major, as simd
        print(f"frame {i + 1}/{len(path)}", flush=True)

    with open(os.path.join(args.out, "sweep.json"), "w") as f:
        json.dump({"width": args.image_width, "height": args.image_height,
                   "fx": focal, "fy": focal, "cx": args.image_width / 2, "cy": args.image_height / 2,
                   "tableY": 0.0, "frames": frames, "pieces": pieces}, f)
    if args.ids:
        render_ids(scene, objects, bpy.data.objects["table"], sun, poses)
    write_frames(args.out)
    print(f"wrote {len(frames)} frames and {len(pieces)} pieces to {args.out}")


if __name__ == "__main__":
    main()
