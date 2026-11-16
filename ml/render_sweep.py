"""Render a phone's zig-zag sweep over one table of pieces, for testing the scan pipeline without a phone.

Writes numbered frames plus sweep.json, which holds what ARKit would report for each frame (camera
intrinsics and camera-to-world transform, in ARKit's conventions: metres, Y up, camera looking along its
-Z axis) and the ground truth: every piece on the table with its part, colour and position, plus the true
size of its footprint (`longMm`, `shortMm`: sides of the smallest rectangle around it seen from straight
above; `heightMm`: how far it stands off the table) and its colour as `rgb`.

Each frame is also written as raw pixels at the detector's working resolution (NNNN.rgba, see sweep_frames.py),
which the replay tool reads. With --ids, a second flat-colour pass writes a piece-number map per frame
(NNNN_ids.png, 16-bit: 0 = table, id + 1 = piece), as render_scenes.py does, plus NNNN.ids at working resolution.

With --depth (which implies --ids), a third pass renders Blender's depth and writes what a LiDAR iPhone's ARKit
`sceneDepth` would give for each frame: NNNN.depth (256 x 192 little-endian float32, metres along the camera's
viewing axis, rows top to bottom, same orientation and field of view as the picture) and NNNN.conf (256 x 192 bytes,
ARConfidenceLevel: 0 low, 1 medium, 2 high), with LiDAR-like noise; see `phone_depth` for the noise model.

With --tall the table is laid out with many tall pieces instead: shapes weighted towards those whose smallest
extent is large, some long pieces stood on end, and some bricks and plates stacked two or three high (a stack is
one piece in the truth, as the scan would see it).

    python ml/render_sweep.py --ldraw ml/ldraw --out ml/sweeps/001 --seed 1 --ids --depth
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
from scipy.ndimage import gaussian_filter, maximum_filter, minimum_filter
from scipy.spatial import ConvexHull

from ldraw import LDrawLibrary
from render import PartFactory, randomise_environment, setup_scene, srgb_to_linear
from render_scenes import decode_ids, id_material, lay_out, overlaps
from sweep_frames import write_frames

# Blender is Z up in millimetres; ARKit is Y up in metres. A rotation, not a mirror.
TO_ARKIT = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], dtype=np.float64)


def arkit_transform(matrix_world):
    m = np.array(matrix_world)
    out = np.eye(4)
    out[:3, :3] = TO_ARKIT @ m[:3, :3]
    out[:3, 3] = TO_ARKIT @ m[:3, 3] / 1000
    return out


def footprint(objs):
    """Sides of the smallest rectangle around the piece (one object, or a stack) seen from straight above, and its height (mm)."""
    parts = []
    for obj in objs:
        mesh = obj.data
        verts = np.empty(len(mesh.vertices) * 3)
        mesh.vertices.foreach_get("co", verts)
        m = np.array(obj.matrix_world)
        parts.append(verts.reshape(-1, 3) @ m[:3, :3].T + m[:3, 3])
    world = np.concatenate(parts)
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


def render_ids(scene, objects, piece_of_object, table, sun, poses):
    """Second pass: every piece glows in its own flat colour, with no lighting, to give exact outlines."""
    table.data.materials[0] = id_material(0)
    for obj, piece in zip(objects, piece_of_object):
        mat = id_material(piece + 1)
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


def lay_out_tall(factory, classes, palette, common, half_w, half_h, rng):
    """A table with many tall pieces standing apart (0.5 to 4 mm gaps): [(part, colour, [poses], x, y, kind)].

    Shapes are drawn with weight usage^0.5 * (smallest extent / 4.8 mm)^2 (the manifest's third `size_mm`), so
    bricks, cones and barrels are common. A long piece (longest side at least 2.5 times the next) is stood on end
    with probability 0.4 (kind "upright"); a brick or plate is stacked two or three high with probability 0.3
    (kind "stack", one piece in the truth); the rest lie as they fall ("resting").
    """
    sized = [c for c in classes if c.get("size_mm")]
    weights = [c["usage"] ** 0.5 * (c["size_mm"][2] / 4.8) ** 2 for c in sized]
    target = rng.randint(45, 70)
    outlines, result = [], []
    attempts = 0
    while len(result) < target and attempts < target * 30:
        attempts += 1
        part = rng.choices(sized, weights=weights)[0]
        ids = [int(k) for k in part["colours"] if int(k) in palette]
        colour = palette[rng.choice(ids)] if ids and rng.random() < 0.8 else rng.choice(common)
        size, name = part["size_mm"], part.get("name", "")
        try:
            pose, _ = factory.resting_pose(part["part_num"], rng)
        except FileNotFoundError:
            continue
        hull = factory.hulls[part["part_num"]]
        kind, poses = "resting", [pose]
        r = rng.random()
        yaw = rng.uniform(0, math.tau)
        spin = np.eye(4)
        spin[:2, :2] = [[math.cos(yaw), -math.sin(yaw)], [math.sin(yaw), math.cos(yaw)]]
        if size[0] >= 2.5 * size[1] and r < 0.4:
            # Stood on end: the longest local axis turned upright.
            axis = int(np.argmax(hull.max(axis=0) - hull.min(axis=0)))
            turn = np.eye(4)
            if axis == 0:
                turn[:3, :3] = [[0, 0, -1], [0, 1, 0], [1, 0, 0]]
            elif axis == 1:
                turn[:3, :3] = [[1, 0, 0], [0, 0, -1], [0, 1, 0]]
            pose = spin @ turn
            pose[2, 3] = -(hull @ pose[:3, :3].T)[:, 2].min()
            kind, poses = "upright", [pose]
        elif (name.startswith("Brick ") or name.startswith("Plate ")) and 0.4 <= r < 0.7:
            # Studs up, two or three high; each layer sits on the studs of the one below.
            pose = spin.copy()
            pose[2, 3] = -hull[:, 2].min()
            layer = float(hull[:, 2].max() - hull[:, 2].min()) - 1.6
            poses = []
            for k in range(rng.choice([2, 2, 3])):
                lifted = pose.copy()
                lifted[2, 3] += k * layer
                poses.append(lifted)
            kind = "stack"
        points = (hull @ poses[0][:3, :3].T + poses[0][:3, 3])[:, :2]
        outline = points[ConvexHull(points).vertices]
        radius = float(np.linalg.norm(outline - outline.mean(axis=0), axis=1).max())
        if radius * 2 > min(half_w, half_h):
            continue
        centre = np.array([rng.uniform(-half_w + radius, half_w - radius), rng.uniform(-half_h + radius, half_h - radius)])
        moved = outline - outline.mean(axis=0) + centre
        if any(overlaps(moved, other, rng.uniform(0.5, 4.0)) for other in outlines):
            continue
        outlines.append(moved)
        offset = centre - outline.mean(axis=0)
        result.append((part["part_num"], colour, poses, float(offset[0]), float(offset[1]), kind))
    return result


DEPTH_W, DEPTH_H = 256, 192   # ARKit sceneDepth


def depth_material():
    """Emits the camera-space depth (distance along the viewing axis, in scene units = mm) as its brightness."""
    mat = bpy.data.materials.new("depth")
    mat.use_nodes = True
    nodes, links = mat.node_tree.nodes, mat.node_tree.links
    nodes.clear()
    camera, emission, output = nodes.new("ShaderNodeCameraData"), nodes.new("ShaderNodeEmission"), nodes.new("ShaderNodeOutputMaterial")
    emission.inputs["Color"].default_value = (1, 1, 1, 1)
    links.new(camera.outputs["View Z Depth"], emission.inputs["Strength"])
    links.new(emission.outputs["Emission"], output.inputs["Surface"])
    return mat


def phone_depth(z, ids, transform, intrinsics, piece_rgb, piece_trans, rng):
    """What ARKit's sceneDepth would report for one frame, made from the exact depth `z` (metres, full resolution).

    Noise model, a coarse imitation of an iPhone Pro's LiDAR depth:
    - Resolution: 256 x 192 over the picture's field of view. Each depth pixel is the box average of the exact
      depth under it, so pixels straddling a piece's edge mix piece and table ("flying pixels").
    - Noise: standard deviation 1 cm at 30 cm, growing with the square of the distance (10 mm * (d / 0.3 m)^2),
      made of independent per-pixel noise (weight 0.8) plus a smooth, spatially correlated part (weight 0.6,
      blurred over about 3 depth pixels), so averaging neighbouring pixels does not remove all of it. Fresh noise
      every frame.
    - Confidence (ARConfidenceLevel): high by default; medium where the exact depth varies by more than 3 mm within
      about one depth pixel (edges), low where it varies by more than 8 mm (steps). Dark pieces (linear luminance
      under 0.03, e.g. black) get 1.5 times the noise and half their pixels drop to medium. Transparent pieces are
      partly seen through (depth 60% of the way to the table behind) and are low confidence. 4% of the remaining
      high pixels drop to medium at random. 0.5% of pixels are gross outliers (3-15 cm off) marked low, and 0.1%
      are outliers (2-8 cm off) still marked high, so whatever reads the map must use robust statistics.
    """
    h, w = z.shape
    box = np.asarray(Image.fromarray(z.astype(np.float32), mode="F").resize((DEPTH_W, DEPTH_H), Image.BOX), dtype=np.float64)
    xs = np.clip(np.rint((np.arange(DEPTH_W) + 0.5) * w / DEPTH_W - 0.5).astype(int), 0, w - 1)
    ys = np.clip(np.rint((np.arange(DEPTH_H) + 0.5) * h / DEPTH_H - 0.5).astype(int), 0, h - 1)
    spread = (maximum_filter(z, size=5) - minimum_filter(z, size=5))[np.ix_(ys, xs)]
    piece = ids[np.ix_(ys, xs)].astype(np.int64)   # 0 = table, n + 1 = piece n

    # Depth of the table behind each depth pixel, for the see-through of transparent pieces (table at world y = 0).
    fx, fy, cx, cy = intrinsics
    u, v = np.meshgrid((np.arange(DEPTH_W) + 0.5) * w / DEPTH_W - 0.5, (np.arange(DEPTH_H) + 0.5) * h / DEPTH_H - 0.5)
    m = np.asarray(transform, dtype=np.float64).reshape(4, 4).T   # sweep.json holds it by columns
    rays = np.stack([(u - cx) / fx, -(v - cy) / fy, -np.ones_like(u)], axis=-1) @ m[:3, :3].T
    down = rays[..., 1] < -1e-6
    table = np.where(down, -m[1, 3] / np.where(down, rays[..., 1], -1), box)   # camera-space z of each ray is -1

    lum = np.ones(len(piece_rgb) + 1)
    trans = np.zeros(len(piece_rgb) + 1, dtype=bool)
    for i, (rgb, t) in enumerate(zip(piece_rgb, piece_trans)):
        r, g, b = srgb_to_linear(rgb)
        lum[i + 1] = 0.2126 * r + 0.7152 * g + 0.0722 * b
        trans[i + 1] = t
    dark = lum[piece] < 0.03
    clear = trans[piece]

    surface = np.where(clear, box + 0.6 * (table - box), box)
    sigma = 0.010 * (surface / 0.30) ** 2 * np.where(dark, 1.5, 1.0)
    smooth = gaussian_filter(rng.standard_normal((DEPTH_H, DEPTH_W)), 3)
    smooth /= smooth.std() + 1e-12
    depth = surface + sigma * (0.8 * rng.standard_normal((DEPTH_H, DEPTH_W)) + 0.6 * smooth)

    conf = np.full((DEPTH_H, DEPTH_W), 2, dtype=np.uint8)
    conf[spread > 0.003] = 1
    conf[spread > 0.008] = 0
    conf[dark & (rng.random((DEPTH_H, DEPTH_W)) < 0.5) & (conf > 1)] = 1
    conf[clear] = 0
    conf[(rng.random((DEPTH_H, DEPTH_W)) < 0.04) & (conf > 1)] = 1
    gross = rng.random((DEPTH_H, DEPTH_W)) < 0.005
    depth[gross] += rng.choice([-1, 1], gross.sum()) * rng.uniform(0.03, 0.15, gross.sum())
    conf[gross] = 0
    sneaky = (rng.random((DEPTH_H, DEPTH_W)) < 0.001) & ~gross
    depth[sneaky] += rng.choice([-1, 1], sneaky.sum()) * rng.uniform(0.02, 0.08, sneaky.sum())
    return np.maximum(depth, 0.01).astype("<f4"), conf


def render_depth(scene, objects, table, poses, frames, intrinsics, pieces, palette, out, seed):
    """Third pass: exact depth from Blender, turned into the phone's 256 x 192 depth and confidence maps."""
    mat = depth_material()
    table.data.materials[0] = mat
    for obj in objects:
        for slot in range(len(obj.data.materials)):
            obj.data.materials[slot] = mat
    scene.cycles.samples = 1
    scene.cycles.use_denoising = False
    scene.cycles.filter_width = 0.01
    scene.render.dither_intensity = 0
    scene.view_settings.exposure = 0
    scene.render.image_settings.file_format = "OPEN_EXR"
    scene.render.image_settings.color_depth = "32"
    scene.render.image_settings.color_mode = "RGB"
    width, height = scene.render.resolution_x, scene.render.resolution_y
    piece_rgb = [tuple(int(p["rgb"][i:i + 2], 16) / 255 for i in (0, 2, 4)) for p in pieces]
    piece_trans = [palette[p["colorId"]]["trans"] if p["colorId"] in palette else False for p in pieces]
    noise = np.random.default_rng(10_000 + seed)   # apart from the layout's random numbers, so the pictures do not change
    for n, ((pose, ids_path), frame) in enumerate(zip(poses, frames)):
        pose()
        exr = ids_path[: -len("_ids.png")] + "_z.exr"
        scene.render.filepath = exr
        bpy.ops.render.render(write_still=True)
        image = bpy.data.images.load(exr)
        pixels = np.empty(width * height * image.channels, dtype=np.float32)
        image.pixels.foreach_get(pixels)
        bpy.data.images.remove(image)
        os.remove(exr)
        z = pixels.reshape(height, width, -1)[::-1, :, 0].astype(np.float64) / 1000   # rows bottom to top; mm to metres
        ids = np.asarray(Image.open(ids_path)).astype(np.int64)
        depth, conf = phone_depth(z, ids, frame["transform"], intrinsics, piece_rgb, piece_trans, noise)
        depth.tofile(os.path.join(out, frame["depth"]))
        conf.tofile(os.path.join(out, frame["confidence"]))
        print(f"depth map {n + 1}/{len(poses)}", flush=True)


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


def add_motion_blur(folder, shutter, share, seed):
    """Smear some frames as the camera's motion during a long exposure would, and record each frame's smear.

    An approximation applied to the rendered frames, not Blender's motion blur: the sweep's camera also jitters its
    tilt independently from frame to frame, which Blender would turn into a large, unphysical rotational smear. For a
    camera translating over a flat table, the picture moves as a whole by focal length x displacement / height, so
    the smear is a box blur of that length along that direction (pieces stand at most a few centimetres above the
    table, so parallax changes the length by under 10% at 32 cm). The displacement is the camera's velocity at the
    frame (from its neighbours' positions) times `shutter` seconds.

    A random `share` of the frames (chosen with their own generator, so the scene is the same as without blur) get the
    long exposure; the rest stay sharp. sweep.json gains `blurPx` per frame: the smear in full-resolution pixels.
    Runs before write_frames, so the replay's NNNN.rgba carry the blur; the piece maps (--ids) stay sharp.
    """
    from scipy.ndimage import shift as shift_image

    path = os.path.join(folder, "sweep.json")
    with open(path) as f:
        sweep = json.load(f)
    frames = sweep["frames"]
    chosen = set(random.Random(seed * 7919 + 17).sample(range(len(frames)), round(len(frames) * share)))
    positions = [np.array(fr["transform"][12:15]) for fr in frames]
    for i, frame in enumerate(frames):
        frame["blurPx"] = 0.0
        if i not in chosen or len(frames) < 2:
            continue
        a, b = max(0, i - 1), min(len(frames) - 1, i + 1)
        velocity = (positions[b] - positions[a]) / max(1e-6, frames[b]["time"] - frames[a]["time"])
        m = np.array(frame["transform"]).reshape(4, 4)   # rows are the matrix's columns
        right, up = m[0, :3], m[1, :3]
        depth = positions[i][1] - sweep["tableY"]
        step = velocity * shutter * sweep["fx"] / depth  # full-resolution pixels the picture moves during the exposure
        dx, dy = -float(step @ right), float(step @ up)   # image x grows right, y grows down
        length = math.hypot(dx, dy)
        if length < 0.5:
            continue
        image = np.asarray(Image.open(os.path.join(folder, frame["file"])).convert("RGB")).astype(np.float32)
        n = max(2, math.ceil(length) + 1)
        out = np.zeros_like(image)
        for t in np.linspace(-0.5, 0.5, n):
            out += shift_image(image, (t * dy, t * dx, 0), order=1, mode="nearest")
        Image.fromarray(np.clip(out / n + 0.5, 0, 255).astype(np.uint8)).save(os.path.join(folder, frame["file"]), quality=92)
        frame["blurPx"] = round(length, 2)
    with open(path, "w") as f:
        json.dump(sweep, f)
    print(f"motion blur: {len(chosen)} of {len(frames)} frames smeared, up to {max(fr['blurPx'] for fr in frames):.1f} px")


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
    ap.add_argument("--depth", action="store_true", help="also write the LiDAR depth and confidence maps ARKit would give (implies --ids)")
    ap.add_argument("--tall", action="store_true", help="lay the table out with many tall pieces: tall shapes, pieces on end, stacks")
    ap.add_argument("--motion-blur", type=float, default=0, metavar="SECONDS",
                    help="exposure time of the blurred frames: smear them by the camera's motion during it (see add_motion_blur)")
    ap.add_argument("--blur-share", type=float, default=0.3, help="share of frames given the long exposure (with --motion-blur)")
    args = ap.parse_args()
    args.ids = args.ids or args.depth

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

    half_w, half_h = args.table_width / 2, args.table_depth / 2
    if args.tall:
        layout = lay_out_tall(factory, classes, palette, common, half_w, half_h, rng)
    else:
        layout = [(part, colour, [pose], x, y, None) for part, colour, pose, x, y in lay_out(factory, classes, palette, common, half_w, half_h, rng)]
    pieces, objects, piece_of_object = [], [], []
    for n, (part, colour, layer_poses, x, y, kind) in enumerate(layout):
        stack = []
        for pose in layer_poses:
            obj, centre_k, radius = factory.place(part, colour, (x, y), rng, pose)
            stack.append(obj)
            objects.append(obj)
            piece_of_object.append(n)
            if len(stack) == 1:
                centre = centre_k
        position = TO_ARKIT @ np.array([centre.x, centre.y, 0.0]) / 1000
        long_mm, short_mm, height_mm = footprint(stack)
        piece = {"id": n, "partNum": part, "classId": class_of[part], "colorId": colour["id"],
                 "x": round(float(position[0]), 5), "z": round(float(position[2]), 5), "radiusMm": round(radius, 1),
                 "longMm": round(long_mm, 1), "shortMm": round(short_mm, 1), "heightMm": round(height_mm, 1),
                 "rgb": "".join(f"{round(c * 255):02x}" for c in colour["rgb"])}
        if kind is not None:
            piece["pose"] = kind
            if kind == "stack":
                piece["stack"] = len(stack)
        pieces.append(piece)
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
        if args.depth:
            frames[-1].update(depth=f"{i:04d}.depth", confidence=f"{i:04d}.conf")
        print(f"frame {i + 1}/{len(path)}", flush=True)

    meta = {"width": args.image_width, "height": args.image_height,
            "fx": focal, "fy": focal, "cx": args.image_width / 2, "cy": args.image_height / 2,
            "tableY": 0.0, "frames": frames, "pieces": pieces}
    if args.depth:
        meta.update(depthWidth=DEPTH_W, depthHeight=DEPTH_H)
    with open(os.path.join(args.out, "sweep.json"), "w") as f:
        json.dump(meta, f)
    if args.ids:
        render_ids(scene, objects, piece_of_object, bpy.data.objects["table"], sun, poses)
    if args.depth:
        render_depth(scene, objects, bpy.data.objects["table"], poses, frames, (focal, focal, args.image_width / 2, args.image_height / 2),
                     pieces, palette, args.out, args.seed)
    if args.motion_blur > 0:
        add_motion_blur(args.out, args.motion_blur, args.blur_share, args.seed)
    write_frames(args.out)
    print(f"wrote {len(frames)} frames and {len(pieces)} pieces to {args.out}")


if __name__ == "__main__":
    main()
