"""Measure accuracy on real photos: a folder of crops arranged as <dir>/<part_num>/*.jpg.

    python ml/evaluate.py --checkpoint ml/runs/v1/best.pt --photos ml/real
"""
import argparse
import glob
import os

import torch
from PIL import Image

from model import PartNet
from train import transforms


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--photos", required=True)
    args = ap.parse_args()

    ckpt = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    model = PartNet(ckpt["backbone"], len(ckpt["classes"]), ckpt["image_size"], pretrained=False)
    model.load_state_dict(ckpt["state"])
    model.eval()
    index = {m: i for i, c in enumerate(ckpt["classes"]) for m in c["members"]}
    _, tf = transforms(ckpt["image_size"])

    top1 = top5 = total = skipped = 0
    for folder in sorted(glob.glob(os.path.join(args.photos, "*"))):
        label = index.get(os.path.basename(folder))
        files = [f for f in glob.glob(os.path.join(folder, "*")) if f.lower().endswith((".jpg", ".jpeg", ".png"))]
        if label is None:
            skipped += len(files)
            continue
        for f in files:
            with torch.no_grad():
                ranked = model(tf(Image.open(f).convert("RGB"))[None]).topk(5).indices[0].tolist()
            top1 += ranked[0] == label
            top5 += label in ranked
            total += 1
    print(f"{total} photos: top-1 {top1 / max(total, 1):.1%}, top-5 {top5 / max(total, 1):.1%}  ({skipped} skipped: part not in the model)")


if __name__ == "__main__":
    main()
