"""Render synthetic training crops of Lego parts with Blender (the `bpy` Python module).

Each image shows one part resting on a table the way it would after being tipped out of a box,
seen from roughly above, with randomised colour, table surface, lighting, camera and neighbouring
pieces, so a model trained on these images copes with real photos.

    python ml/render.py --manifest ml/manifest.json --ldraw /path/to/ldraw --out ml/dataset --per-class 200

Split the work across processes or machines with --first-class / --last-class.
"""
import argparse
import csv
import gzip
import json
import math
import os
import random

import bpy  # must come first: it makes bmesh and mathutils importable
import bmesh
import numpy as np
import trimesh
from mathutils import Matrix, Vector

from ldraw import LDrawLibrary, MAIN_COLOUR


def srgb_to_linear(c):
    return tuple(v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4 for v in c)


def plastic(name, rgb, transparent=False, rng=random):
    mat = bpy.data.materials.new(name)
    mat.use_nodes = True
    bsdf = mat.node_tree.nodes["Principled BSDF"]
    bsdf.inputs["Base Color"].default_value = (*srgb_to_linear(rgb), 1)
    bsdf.inputs["Roughness"].default_value = rng.uniform(0.04, 0.1) if transparent else rng.uniform(0.15, 0.45)
    bsdf.inputs["IOR"].default_value = 1.53
    if transparent:
        bsdf.inputs["Transmission Weight"].default_value = 1.0
    return mat


class PartFactory:
    """Builds Blender meshes for parts and knows how each one tends to rest on a table."""

    def __init__(self, lib):
        self.lib = lib
        self.meshes = {}
        self.poses = {}
        self.radius = {}

    def _prepare(self, part_num):
        verts, faces, colours = self.lib.load_part(part_num)
        mesh = bpy.data.meshes.new(part_num)
        mesh.from_pydata(verts.tolist(), [], faces.tolist())
        codes = sorted(set(colours.tolist()) - {MAIN_COLOUR})
        slot = {MAIN_COLOUR: 0, **{c: i + 1 for i, c in enumerate(codes)}}
        mesh.polygons.foreach_set("material_index", [slot[c] for c in colours.tolist()])
        bm = bmesh.new()
        bm.from_mesh(mesh)
        bmesh.ops.remove_doubles(bm, verts=bm.verts, dist=0.01)
        bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
        bm.to_mesh(mesh)
        bm.free()
        mesh.shade_smooth()
        mesh.set_sharp_from_angle(angle=math.radians(35))
        self.meshes[part_num] = (mesh, codes)

        # Resting orientations and how likely each is, from the convex hull.
        hull = trimesh.Trimesh(verts, faces, process=False).convex_hull
        try:
            transforms, probs = trimesh.poses.compute_stable_poses(hull, center_mass=hull.center_mass, n_samples=1, threshold=0.03)
        except Exception:
            transforms, probs = [], []
        if len(transforms) == 0:
            lift = np.eye(4)
            lift[2, 3] = -verts[:, 2].min()
            transforms, probs = [lift], [1.0]
        self.poses[part_num] = (list(transforms), list(np.asarray(probs) / np.sum(probs)))
        self.radius[part_num] = float(np.linalg.norm(verts - verts.mean(axis=0), axis=1).max())

    def place(self, part_num, colour, xy, rng):
        """Add the part to the scene resting on the table at `xy`. Returns (object, centre, radius)."""
        if part_num not in self.meshes:
            self._prepare(part_num)
        mesh, codes = self.meshes[part_num]
        obj = bpy.data.objects.new(part_num, mesh.copy())
        obj.data.materials.append(plastic("main", colour["rgb"], colour["trans"], rng))
        for code in codes:
            obj.data.materials.append(plastic(f"c{code}", self.lib.fixed_colours.get(code, (0.5, 0.5, 0.5)), rng=rng))
        transforms, probs = self.poses[part_num]
        rest = Matrix(transforms[rng.choices(range(len(probs)), weights=probs)[0]].tolist())
        obj.matrix_world = Matrix.Translation((xy[0], xy[1], 0)) @ Matrix.Rotation(rng.uniform(0, math.tau), 4, "Z") @ rest
        bpy.context.scene.collection.objects.link(obj)
        bpy.context.view_layer.update()
        corners = [obj.matrix_world @ Vector(c) for c in obj.bound_box]
        centre = sum(corners, Vector()) / 8
        return obj, centre, self.radius[part_num]


def setup_scene(resolution, samples):
    bpy.ops.wm.read_factory_settings(use_empty=True)
    scene = bpy.context.scene
    scene.render.engine = "CYCLES"
    scene.cycles.samples = samples
    scene.cycles.use_denoising = False
    scene.cycles.max_bounces = 6
    scene.render.resolution_x = scene.render.resolution_y = resolution
    scene.render.image_settings.file_format = "JPEG"
    scene.render.image_settings.quality = 92
    scene.view_settings.view_transform = "Standard"
    scene.world = bpy.data.worlds.new("world")
    scene.world.use_nodes = True

    table = bpy.data.meshes.new("table")
    size = 2000
    table.from_pydata([(-size, -size, 0), (size, -size, 0), (size, size, 0), (-size, size, 0)], [], [(0, 1, 2, 3)])
    table_obj = bpy.data.objects.new("table", table)
    table_mat = bpy.data.materials.new("table")
    table_mat.use_nodes = True
    table.materials.append(table_mat)
    scene.collection.objects.link(table_obj)

    sun = bpy.data.objects.new("sun", bpy.data.lights.new("sun", "SUN"))
    scene.collection.objects.link(sun)
    camera = bpy.data.objects.new("camera", bpy.data.cameras.new("camera"))
    scene.collection.objects.link(camera)
    scene.camera = camera
    return scene, table_mat, sun, camera


def randomise_environment(scene, table_mat, sun, rng):
    # Table: mostly light and plain, sometimes dark or coloured, with slight mottling.
    kind = rng.random()
    if kind < 0.55:
        v = rng.uniform(0.7, 0.98)
        base = (v + rng.uniform(-0.04, 0.04), v + rng.uniform(-0.03, 0.03), v + rng.uniform(-0.06, 0.03))
    elif kind < 0.75:
        v = rng.uniform(0.03, 0.3)
        base = (v, v, v)
    else:
        base = (rng.uniform(0.2, 0.9), rng.uniform(0.2, 0.85), rng.uniform(0.15, 0.8))
    base = tuple(min(1, max(0, c)) for c in base)
    nodes, links = table_mat.node_tree.nodes, table_mat.node_tree.links
    bsdf = nodes["Principled BSDF"]
    bsdf.inputs["Roughness"].default_value = rng.uniform(0.35, 0.95)
    noise = nodes.get("Noise Texture") or nodes.new("ShaderNodeTexNoise")
    ramp = nodes.get("Mix") or nodes.new("ShaderNodeMix")
    ramp.data_type = "RGBA"
    noise.inputs["Scale"].default_value = rng.uniform(0.005, 0.3)
    lin = srgb_to_linear(base)
    ramp.inputs["A"].default_value = (*lin, 1)
    ramp.inputs["B"].default_value = (*(c * rng.uniform(0.75, 1.0) for c in lin), 1)
    links.new(noise.outputs["Fac"], ramp.inputs["Factor"])
    links.new(ramp.outputs["Result"], bsdf.inputs["Base Color"])

    # Light: one soft key light from a random direction plus ambient fill, both with a random tint.
    elevation, azimuth = rng.uniform(math.radians(30), math.radians(88)), rng.uniform(0, math.tau)
    sun.rotation_euler = (math.pi / 2 - elevation, 0, azimuth)
    sun.data.energy = rng.uniform(1.0, 4.5)
    sun.data.angle = rng.uniform(math.radians(3), math.radians(60))
    warmth = rng.uniform(-0.12, 0.12)
    sun.data.color = (1 + warmth, 1, 1 - warmth)
    background = scene.world.node_tree.nodes["Background"]
    background.inputs["Strength"].default_value = rng.uniform(0.3, 1.3)
    fill = rng.uniform(-0.08, 0.08)
    background.inputs["Color"].default_value = (1 + fill, 1, 1 - fill, 1)
    scene.view_settings.exposure = rng.uniform(-0.7, 0.5)


def aim_camera(camera, centre, radius, rng):
    """Phone held roughly flat 25-45 cm above the table; the crop around a piece is a narrow field of view."""
    tilt, azimuth = rng.uniform(0, math.radians(35)), rng.uniform(0, math.tau)
    distance = rng.uniform(250, 450)
    direction = Vector((math.sin(tilt) * math.cos(azimuth), math.sin(tilt) * math.sin(azimuth), math.cos(tilt)))
    target = centre + Vector((rng.uniform(-0.15, 0.15) * radius, rng.uniform(-0.15, 0.15) * radius, 0))
    camera.location = target + direction * distance
    camera.rotation_euler = (target - camera.location).to_track_quat("-Z", "Y").to_euler()
    camera.rotation_euler.rotate_axis("Z", rng.uniform(0, math.tau))
    fill = rng.uniform(0.5, 0.85)   # fraction of the frame the piece spans
    camera.data.sensor_fit = "HORIZONTAL"
    camera.data.angle = 2 * math.atan(radius / fill / distance)
    camera.data.clip_start, camera.data.clip_end = 1, 5000


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--manifest", default="ml/manifest.json")
    ap.add_argument("--ldraw", required=True)
    ap.add_argument("--catalog", default="data", help="folder with Rebrickable colors.csv.gz")
    ap.add_argument("--out", default="ml/dataset")
    ap.add_argument("--per-class", type=int, default=200)
    ap.add_argument("--first-class", type=int, default=0)
    ap.add_argument("--last-class", type=int, default=None)
    ap.add_argument("--resolution", type=int, default=224)
    ap.add_argument("--samples", type=int, default=24)
    ap.add_argument("--device", choices=["CPU", "GPU"], default="CPU")
    ap.add_argument("--seed", type=int, default=0)
    args = ap.parse_args()

    classes = json.load(open(args.manifest))["classes"]
    selected = classes[args.first_class: args.last_class]
    with gzip.open(os.path.join(args.catalog, "colors.csv.gz"), "rt", encoding="utf-8") as f:
        palette = {int(r["id"]): {"id": int(r["id"]), "rgb": tuple(int(r["rgb"][i:i + 2], 16) / 255 for i in (0, 2, 4)),
                                  "trans": r["is_trans"] in ("True", "t")} for r in csv.DictReader(f) if int(r["id"]) >= 0}
    common = [palette[i] for i in (0, 1, 2, 4, 14, 15, 19, 25, 28, 70, 71, 72, 272, 320) if i in palette]

    lib = LDrawLibrary(args.ldraw)
    scene, table_mat, sun, camera = setup_scene(args.resolution, args.samples)
    if args.device == "GPU":
        prefs = bpy.context.preferences.addons["cycles"].preferences
        prefs.compute_device_type = "METAL" if os.uname().sysname == "Darwin" else "OPTIX"
        prefs.get_devices()
        for d in prefs.devices:
            d.use = True
        scene.cycles.device = "GPU"
    factory = PartFactory(lib)
    os.makedirs(args.out, exist_ok=True)
    labels_path = os.path.join(args.out, f"labels-{args.first_class}.csv")
    with open(labels_path, "w", newline="") as f:
        out = csv.writer(f)
        out.writerow(["file", "class_id", "part_num", "color_id"])
        for c in selected:
            rng = random.Random(args.seed * 100003 + c["class_id"])
            folder = os.path.join(args.out, "images", str(c["class_id"]))
            os.makedirs(folder, exist_ok=True)
            ids = [int(k) for k in c["colours"] if int(k) in palette]
            weights = [c["colours"][str(k)] ** 0.5 for k in ids]   # flatten so rare colours still appear
            for n in range(args.per_class):
                colour = palette[rng.choices(ids, weights=weights)[0]] if ids and rng.random() < 0.85 else rng.choice(common)
                placed = [factory.place(c["part_num"], colour, (0, 0), rng)]
                _, centre, radius = placed[0]
                # Neighbours crowd the edges of the crop, as on a real table.
                for _ in range(rng.choice([0, 0, 1, 2, 3])):
                    other = rng.choice(classes[:400])
                    angle = rng.uniform(0, math.tau)
                    try:
                        gap = (radius + factory.radius.get(other["part_num"], 15)) * rng.uniform(1.0, 1.7)
                        placed.append(factory.place(other["part_num"], rng.choice(common), (math.cos(angle) * gap, math.sin(angle) * gap), rng))
                    except FileNotFoundError:
                        pass
                randomise_environment(scene, table_mat, sun, rng)
                aim_camera(camera, centre, radius, rng)
                rel = os.path.join("images", str(c["class_id"]), f"{n:05d}.jpg")
                scene.render.filepath = os.path.join(args.out, rel)
                bpy.ops.render.render(write_still=True)
                out.writerow([rel, c["class_id"], c["part_num"], colour["id"]])
                for obj, _, _ in placed:
                    mesh = obj.data
                    for mat in list(mesh.materials):
                        bpy.data.materials.remove(mat)
                    bpy.data.objects.remove(obj)
                    bpy.data.meshes.remove(mesh)
            f.flush()
            print(f"class {c['class_id']} {c['part_num']}: {args.per_class} images", flush=True)


if __name__ == "__main__":
    main()
