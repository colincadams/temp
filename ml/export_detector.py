"""Convert the trained piece detector for the iPhone app.

    python ml/export_detector.py --checkpoint ml/runs/detector/best.pt
"""
import argparse
import os

import coremltools as ct
import torch

from detector import PieceNet
from model import MEAN, STD

WIDTH, HEIGHT = 640, 480   # the app pads its camera frame to this size


class Deployable(torch.nn.Module):
    """Pixels in 0..1 go in; piece and centre probabilities plus offsets come out as one [1,4,H/2,W/2] array."""

    def __init__(self, net):
        super().__init__()
        self.net = net
        self.register_buffer("mean", torch.tensor(MEAN).view(1, 3, 1, 1))
        self.register_buffer("std", torch.tensor(STD).view(1, 3, 1, 1))

    def forward(self, image):
        out = self.net((image - self.mean) / self.std)
        return torch.cat([torch.sigmoid(out[:, :2]), out[:, 2:]], dim=1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--checkpoint", required=True)
    ap.add_argument("--out", default="ios/BrickScan/Sources/Model")
    args = ap.parse_args()

    ckpt = torch.load(args.checkpoint, map_location="cpu", weights_only=False)
    net = PieceNet(ckpt["encoder"], pretrained=False)
    net.load_state_dict(ckpt["state"])
    model = Deployable(net).eval()
    example = torch.rand(1, 3, HEIGHT, WIDTH)
    mlmodel = ct.convert(
        torch.jit.trace(model, example),
        inputs=[ct.ImageType(name="image", shape=example.shape, scale=1 / 255.0, color_layout=ct.colorlayout.RGB)],
        outputs=[ct.TensorType(name="maps")],
        minimum_deployment_target=ct.target.iOS17,
        compute_precision=ct.precision.FLOAT16,
    )
    mlmodel.short_description = "Lego piece detector: per-pixel piece, centre and centre-offset maps."
    os.makedirs(args.out, exist_ok=True)
    mlmodel.save(os.path.join(args.out, "PieceNet.mlpackage"))
    print(f"wrote {args.out}/PieceNet.mlpackage")


if __name__ == "__main__":
    main()
