"""Write a rendered sweep's frames in the form the replay tool (`swift run brick-replay`) reads.

For each frame NNNN.jpg this writes NNNN.rgba: raw RGBA bytes at the detector's working resolution, downsampled
the way the app does it (`ScanEngine.downsample`: keep every `step`-th pixel of every `step`-th row, where
step = full width // 640, at least 1). If the frame has a piece-number map NNNN_ids.png (render_sweep.py --ids),
it also writes NNNN.ids: the same pixels of that map as raw little-endian 16-bit numbers (0 = table, n + 1 = the
piece with id n in sweep.json).

sweep.json gains `workStep`, `workWidth` and `workHeight`, and each frame gains `rgba` (and `ids`) file names.
Nothing already there changes. render_sweep.py runs this by itself; run it by hand for sweeps rendered before:

    python3 ml/sweep_frames.py ml/sweeps/001
"""
import argparse
import json
import os

import numpy as np
from PIL import Image

WORK_WIDTH = 640   # ScanEngine.workWidth


def work_size(width, height, target=WORK_WIDTH):
    step = max(1, width // target)
    return step, width // step, height // step


def downsample(array, step, width, height):
    return array[: height * step: step, : width * step: step][:height, :width]


def write_frames(folder):
    path = os.path.join(folder, "sweep.json")
    with open(path) as f:
        sweep = json.load(f)
    step, w, h = work_size(sweep["width"], sweep["height"])
    for frame in sweep["frames"]:
        stem = os.path.splitext(frame["file"])[0]
        rgb = np.asarray(Image.open(os.path.join(folder, frame["file"])).convert("RGB"))
        if rgb.shape[:2] != (sweep["height"], sweep["width"]):
            raise SystemExit(f"{frame['file']} is {rgb.shape[1]} x {rgb.shape[0]}, sweep.json says {sweep['width']} x {sweep['height']}")
        small = downsample(rgb, step, w, h)
        rgba = np.concatenate([small, np.full((h, w, 1), 255, np.uint8)], axis=2)
        open(os.path.join(folder, stem + ".rgba"), "wb").write(np.ascontiguousarray(rgba).tobytes())
        frame["rgba"] = stem + ".rgba"
        ids_png = os.path.join(folder, stem + "_ids.png")
        if os.path.exists(ids_png):
            ids = np.asarray(Image.open(ids_png)).astype("<u2")
            open(os.path.join(folder, stem + ".ids"), "wb").write(np.ascontiguousarray(downsample(ids, step, w, h)).tobytes())
            frame["ids"] = stem + ".ids"
    sweep.update(workStep=step, workWidth=w, workHeight=h)
    with open(path + ".tmp", "w") as f:
        json.dump(sweep, f)
    os.replace(path + ".tmp", path)
    print(f"wrote {len(sweep['frames'])} frames at {w} x {h} (every {step} pixels) to {folder}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sweep", help="folder holding sweep.json")
    write_frames(ap.parse_args().sweep)


if __name__ == "__main__":
    main()
