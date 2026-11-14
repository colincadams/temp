"""Render whole tables of pieces, many of them touching, with an outline map saying which pixels belong to which piece.

These train the piece detector (ml/train_detector.py), which has to split touching pieces that a simple
colour threshold merges into one blob.

    python ml/render_scenes.py --ldraw ml/ldraw --scenes 3000

Each scene writes NNNNN.jpg (the picture) and NNNNN_ids.png (16-bit: 0 = table, 1..n = piece number).
Finished scenes are skipped, so an interrupted run can be restarted.
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

from ldraw import LDrawLibrary
from render import PartFactory, randomise_environment, setup_scene, srgb_to_linear

LEVELS = 8                # ids are encoded as 8 levels per colour channel: 8**3 - 1 = 511 distinct values
MAX_PIECES = 450


def overlaps(a, b, gap=0.0):
    """Separating-axis test for two convex outlines (n x 2 arrays, counter-clockwise)."""
    for poly in (a, b):
        edges = np.roll(poly, -1, axis=0) - poly
        normals = np.stack([edges[:, 1], -edges[:, 0]], axis=1)
        normals /= np.linalg.norm(normals, axis=1, keepdims=True) + 1e-9
        pa, pb = a @ normals.T, b @ normals.T
        if np.any(pa.min(axis=0) > pb.max(axis=0) + gap) or np.any(pb.min(axis=0) > pa.max(axis=0) + gap):
            return False
    return True


def lay_out(factory, classes, palette, common, half_w, half_h, rng):
    """Choose parts, poses and positions for one table. Returns [(part_num, colour, pose, x, y)]."""
    outlines, yaws, colours = [], [], []
    centres, radii = np.zeros((MAX_PIECES, 2)), np.zeros(MAX_PIECES)
    result = []

    def free(outline, centre, radius):
        n = len(outlines)
        near = np.nonzero(np.hypot(centres[:n, 0] - centre[0], centres[:n, 1] - centre[1]) < radii[:n] + radius + 1)[0]
        return not any(overlaps(outline, outlines[i]) for i in near)

    # From a few scattered pieces to a table covered edge to edge.
    density = rng.random()
    target = rng.randint(8, 80) if density < 0.2 else rng.randint(80, 220) if density < 0.5 else rng.randint(220, MAX_PIECES)
    touch_share = rng.uniform(0.5, 0.9)
    weights = [c["usage"] ** 0.5 for c in classes]
    attempts = 0
    while len(result) < target and attempts < target * 8:
        attempts += 1
        part = rng.choices(classes, weights=weights)[0]
        ids = [int(k) for k in part["colours"] if int(k) in palette]
        colour = palette[rng.choice(ids)] if ids and rng.random() < 0.8 else rng.choice(common)
        try:
            if outlines and rng.random() < touch_share:
                # Slide the new piece up against one already on the table.
                t = rng.randrange(len(outlines))
                t_centre, t_radius, t_yaw = centres[t], radii[t], yaws[t]
                aligned = rng.random() < 0.45   # flush side by side, the hardest case, often in the same colour
                yaw = t_yaw + rng.choice([0, math.pi / 2]) if aligned else None
                if aligned and rng.random() < 0.6:
                    colour = colours[t]
                pose, outline = factory.resting_pose(part["part_num"], rng, yaw)
                radius = float(np.linalg.norm(outline - outline.mean(axis=0), axis=1).max())
                angle = t_yaw + rng.choice([0, 1, 2, 3]) * math.pi / 2 if aligned else rng.uniform(0, math.tau)
                direction = np.array([math.cos(angle), math.sin(angle)])
                start = t_centre - outline.mean(axis=0)
                lo, hi = 0.0, t_radius + radius + 3
                if not free(outline + start + direction * hi, t_centre + direction * hi, radius):
                    continue
                for _ in range(12):   # smallest slide distance that clears everything
                    mid = (lo + hi) / 2
                    if free(outline + start + direction * mid, t_centre + direction * mid, radius):
                        hi = mid
                    else:
                        lo = mid
                offset = start + direction * (hi + rng.choice([0.05, 0.05, 0.3, 1.0]))
                yaw_used = t_yaw if aligned else rng.uniform(0, math.tau)
            else:
                pose, outline = factory.resting_pose(part["part_num"], rng)
                radius = float(np.linalg.norm(outline - outline.mean(axis=0), axis=1).max())
                offset = np.array([rng.uniform(-half_w, half_w), rng.uniform(-half_h, half_h)]) - outline.mean(axis=0)
                yaw_used = rng.uniform(0, math.tau)
        except FileNotFoundError:
            continue
        moved = outline + offset
        centre = moved.mean(axis=0)
        if abs(centre[0]) > half_w * 1.15 or abs(centre[1]) > half_h * 1.15 or not free(moved, centre, radius):
            continue
        n = len(outlines)
        outlines.append(moved); yaws.append(yaw_used); colours.append(colour)
        centres[n], radii[n] = centre, radius
        result.append((part["part_num"], colour, pose, float(offset[0]), float(offset[1])))
    return result


def id_material(index):
    """Flat, self-lit colour that encodes a piece number and survives rendering exactly."""
    mat = bpy.data.materials.new(f"id{index}")
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    nodes.clear()
    emission, output = nodes.new("ShaderNodeEmission"), nodes.new("ShaderNodeOutputMaterial")
    digits = (index % LEVELS, index // LEVELS % LEVELS, index // LEVELS ** 2)
    emission.inputs["Color"].default_value = (*srgb_to_linear(tuple(d / (LEVELS - 1) for d in digits)), 1)
    links.new(emission.outputs["Emission"], output.inputs["Surface"])
    return mat


def decode_ids(path):
    px = np.asarray(Image.open(path).convert("RGB")).astype(np.float32)
    digits = np.rint(px / 255 * (LEVELS - 1)).astype(np.int32)
    return (digits[..., 0] + digits[..., 1] * LEVELS + digits[..., 2] * LEVELS ** 2).astype(np.uint16)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default="ml/manifest.json")
    ap.add_argument("--ldraw", required=True)
    ap.add_argument("--catalog", default="data")
    ap.add_argument("--out", default="ml/scenes")
    ap.add_argument("--scenes", type=int, default=3000)
    ap.add_argument("--first", type=int, default=0, help="first scene number, to split work across processes")
    ap.add_argument("--width", type=int, default=640)
    ap.add_argument("--height", type=int, default=480)
    ap.add_argument("--samples", type=int, default=16)
    ap.add_argument("--max-classes", type=int, default=600, help="draw pieces from this many of the most common shapes")
    args = ap.parse_args()

    classes = json.load(open(args.manifest))["classes"][: args.max_classes]
    with gzip.open(os.path.join(args.catalog, "colors.csv.gz"), "rt", encoding="utf-8") as f:
        palette = {int(r["id"]): {"id": int(r["id"]), "rgb": tuple(int(r["rgb"][i:i + 2], 16) / 255 for i in (0, 2, 4)),
                                  "trans": r["is_trans"] in ("True", "t")} for r in csv.DictReader(f) if int(r["id"]) >= 0}
    common = [palette[i] for i in (0, 1, 2, 4, 14, 15, 19, 25, 28, 70, 71, 72, 272, 320) if i in palette]

    scene, table_mat, sun, camera = setup_scene(args.width, args.samples)
    scene.render.resolution_x, scene.render.resolution_y = args.width, args.height
    scene.render.dither_intensity = 0
    table = bpy.data.objects["table"]
    table_id = id_material(0)
    factory = PartFactory(LDrawLibrary(args.ldraw))
    os.makedirs(args.out, exist_ok=True)

    for n in range(args.first, args.first + args.scenes):
        picture, ids_path = os.path.join(args.out, f"{n:05d}.jpg"), os.path.join(args.out, f"{n:05d}_ids.png")
        if os.path.exists(ids_path):
            continue
        rng = random.Random(n)
        # Phone held roughly flat 25-45 cm above the table, looking down.
        height = rng.uniform(250, 450)
        fov = math.radians(rng.uniform(55, 68))
        half_w = height * math.tan(fov / 2)
        half_h = half_w * args.height / args.width
        tilt, azimuth = rng.uniform(0, math.radians(15)), rng.uniform(0, math.tau)
        camera.location = Vector((math.sin(tilt) * math.cos(azimuth), math.sin(tilt) * math.sin(azimuth), math.cos(tilt))) * height
        camera.rotation_euler = (-camera.location).to_track_quat("-Z", "Y").to_euler()
        camera.rotation_euler.rotate_axis("Z", rng.uniform(0, math.tau))
        camera.data.sensor_fit = "HORIZONTAL"
        camera.data.angle = fov
        camera.data.clip_start, camera.data.clip_end = 1, 5000

        # The table is covered a little beyond the frame, so pieces are cut by its edges.
        objects = [factory.place(part, colour, (x, y), rng, pose)[0]
                   for part, colour, pose, x, y in lay_out(factory, classes, palette, common, half_w * 1.08, half_h * 1.12, rng)]

        randomise_environment(scene, table_mat, sun, rng)
        scene.cycles.samples = args.samples
        scene.cycles.filter_width = 1.5
        scene.render.image_settings.file_format = "JPEG"
        scene.render.filepath = picture
        bpy.ops.render.render(write_still=True)

        # Second pass: every piece glows in its own flat colour, with no lighting, to give exact outlines.
        originals = [list(obj.data.materials) for obj in objects]
        id_mats = []
        for i, obj in enumerate(objects):
            mat = id_material(i + 1)
            id_mats.append(mat)
            for slot in range(len(obj.data.materials)):
                obj.data.materials[slot] = mat
        table.data.materials[0] = table_id
        saved = (sun.data.energy, scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value, scene.view_settings.exposure)
        sun.data.energy = 0
        scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value = 0
        scene.view_settings.exposure = 0
        scene.cycles.samples = 1
        scene.cycles.filter_width = 0.01
        scene.render.image_settings.file_format = "PNG"
        raw = os.path.join(args.out, f"{n:05d}_raw.png")
        scene.render.filepath = raw
        bpy.ops.render.render(write_still=True)
        Image.fromarray(decode_ids(raw)).save(ids_path + ".tmp", format="PNG")
        os.remove(raw)
        os.replace(ids_path + ".tmp", ids_path)

        sun.data.energy, scene.world.node_tree.nodes["Background"].inputs["Strength"].default_value, scene.view_settings.exposure = saved
        table.data.materials[0] = table_mat
        for obj, mats in zip(objects, originals):
            mesh = obj.data
            bpy.data.objects.remove(obj)
            bpy.data.meshes.remove(mesh)
            for mat in mats:
                bpy.data.materials.remove(mat)
        for mat in id_mats:
            bpy.data.materials.remove(mat)
        print(f"scene {n}: {len(objects)} pieces", flush=True)


if __name__ == "__main__":
    main()
