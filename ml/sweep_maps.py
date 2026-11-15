"""Write the piece detector's output for every frame of a sweep, for `brick-replay --detector maps`.

Each frame NNNN gets NNNN.maps: 4 planes of raw little-endian float32 at half the model's 640 x 480 input
(320 x 240 each, rows top to bottom): piece probability, centre probability, x offset, y offset (offsets in output
pixels). This is exactly what the app's InstanceDetector gets back from Core ML before grouping the pixels into pieces.

    # the trained detector (ml/train_detector.py); the frame is fed as the app does: 640 wide, rows below the
    # frame filled by repeating its last row, scaled to 0..1 and normalised as in training
    python3 ml/sweep_maps.py ml/sweeps/001 --checkpoint ml/runs/detector/best.pt

    # ideal maps made from the frame's piece-number map (render_sweep.py --ids), the training targets themselves:
    # tests the grouping and tracking with a detector that makes no mistakes
    python3 ml/sweep_maps.py ml/sweeps/001 --ideal

Needs the frames at working resolution (NNNN.rgba, written by render_sweep.py or sweep_frames.py).
"""
import argparse
import json
import os

import numpy as np

INPUT_W, INPUT_H, STRIDE = 640, 480, 2   # InstanceDetector's input size and output stride


def pad_rows(array, height):
    """Rows below the frame repeat its last row, as InstanceDetector fills the model's input."""
    if array.shape[0] >= height:
        return array[:height]
    return np.concatenate([array, np.repeat(array[-1:], height - array.shape[0], axis=0)], axis=0)


def ideal_maps(ids):
    from detector import targets_from_ids
    small = np.ascontiguousarray(pad_rows(ids, INPUT_H)[::STRIDE, ::STRIDE])
    piece, centre, offset = targets_from_ids(small)
    return np.concatenate([piece[None], centre[None], offset], axis=0)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("sweep", help="folder holding sweep.json")
    source = ap.add_mutually_exclusive_group(required=True)
    source.add_argument("--checkpoint", help="detector checkpoint from ml/train_detector.py")
    source.add_argument("--ideal", action="store_true", help="ideal maps from the per-frame piece-number maps")
    args = ap.parse_args()

    sweep = json.load(open(os.path.join(args.sweep, "sweep.json")))
    w, h = sweep.get("workWidth"), sweep.get("workHeight")
    if w is None:
        raise SystemExit(f"no working-resolution frames; run: python3 ml/sweep_frames.py {args.sweep}")
    if w != INPUT_W or h > INPUT_H:
        raise SystemExit(f"frames are {w} x {h}; the detector takes {INPUT_W} wide and at most {INPUT_H} high, "
                         "so the app would fall back to the colour detector")

    model = None
    if args.checkpoint:
        import torch
        from detector import PieceNet
        from model import MEAN, STD
        ckpt = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
        model = PieceNet(ckpt["encoder"], pretrained=False)
        model.load_state_dict(ckpt["state"])
        model.eval()
        mean, std = torch.tensor(MEAN).view(1, 3, 1, 1), torch.tensor(STD).view(1, 3, 1, 1)

    for frame in sweep["frames"]:
        stem = os.path.splitext(frame["file"])[0]
        if args.ideal:
            if "ids" not in frame:
                raise SystemExit(f"{frame['file']} has no piece-number map; render the sweep with --ids")
            ids = np.fromfile(os.path.join(args.sweep, frame["ids"]), dtype="<u2").reshape(h, w)
            maps = ideal_maps(ids)
        else:
            rgba = np.fromfile(os.path.join(args.sweep, frame["rgba"]), dtype=np.uint8).reshape(h, w, 4)
            image = pad_rows(rgba[..., :3], INPUT_H).astype(np.float32) / 255
            with torch.no_grad():
                x = (torch.from_numpy(image).permute(2, 0, 1)[None] - mean) / std
                out = model(x)[0]
                maps = torch.cat([torch.sigmoid(out[:2]), out[2:]]).numpy()
        assert maps.shape == (4, INPUT_H // STRIDE, INPUT_W // STRIDE), maps.shape
        maps.astype("<f4").tofile(os.path.join(args.sweep, stem + ".maps"))
    print(f"wrote {len(sweep['frames'])} detector outputs ({'ideal' if args.ideal else args.checkpoint}) to {args.sweep}")


if __name__ == "__main__":
    main()
