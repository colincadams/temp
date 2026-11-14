"""Convert a trained checkpoint into what the iPhone app loads: a Core ML model and a class list.

    python ml/export.py --checkpoint ml/runs/v1/best.pt --out ios/BrickScan/Model
"""
import argparse
import json
import os

import coremltools as ct
import torch

from model import MEAN, STD, PartNet


class Deployable(torch.nn.Module):
    """Takes pixels in 0..1 and returns the similarity to every shape, so the app needs no preprocessing."""

    def __init__(self, net):
        super().__init__()
        self.net = net
        self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(STD).view(1, 3, 1, 1))

    def forward(self, image):
        return self.net((image - self.mean) / self.std)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--out", default="ios/BrickScan/Model")
    args = ap.parse_args()

    ckpt = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    size = ckpt["image_size"]
    net = PartNet(ckpt["backbone"], len(ckpt["classes"]), size, pretrained=False)
    net.load_state_dict(ckpt["state"])
    model = Deployable(net).eval()
    example = torch.rand(1, 3, size, size)
    traced = torch.jit.trace(model, example)

    mlmodel = ct.convert(
        traced,
        inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="similarity")],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.short_description = "Lego part shape recognition: similarity of a piece crop to each known shape."
    os.makedirs(args.out, exist_ok=True)
    mlmodel.save(os.path.join(args.out, "PartNet.mlpackage"))
    classes = [{"partNum": c["part_num"], "name": c["name"], "members": c["members"], "sizeMm": c["size_mm"]} for c in ckpt["classes"]]
    with open(os.path.join(args.out, "classes.json"), "w") as f:
        json.dump({"imageSize": size, "classes": classes}, f)
    print(f"wrote {args.out}/PartNet.mlpackage and classes.json ({len(classes)} shapes)")


if __name__ == "__main__":
    main()
