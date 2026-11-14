"""Train the piece detector on rendered tables.

    python ml/train_detector.py --data ml/scenes --out ml/runs/detector
"""
import argparse
import glob
import math
import os
import random
import time

import numpy as np
import torch
from PIL import Image
from torch.utils.data import DataLoader, Dataset
from torchvision.transforms import v2 as T

from detector import STRIDE, PieceNet, detector_loss, group_instances, match_instances, targets_from_ids
from model import MEAN, STD


class Scenes(Dataset):
    def __init__(self, files, crop, train):
        self.files, self.crop, self.train = files, crop, train
        self.colour = T.ColorJitter(brightness=0.35, contrast=0.35, saturation=0.3, hue=0.04)
        self.blur = T.RandomApply([T.GaussianBlur(5, sigma=(0.2, 1.6))], p=0.35)

    def __len__(self):
        return len(self.files)

    def __getitem__(self, i):
        image = Image.open(self.files[i]).convert("RGB")
        ids = np.asarray(Image.open(self.files[i][:-4] + "_ids.png"))
        if self.train:
            image = self.blur(self.colour(image))
        image = np.array(image)
        if self.train:
            h, w = ids.shape
            y, x = random.randrange(0, h - self.crop + 1, STRIDE), random.randrange(0, w - self.crop + 1, STRIDE)
            image, ids = image[y:y + self.crop, x:x + self.crop], ids[y:y + self.crop, x:x + self.crop]
            k = random.randrange(4)   # the detector does not care which way up the table is
            image, ids = np.rot90(image, k), np.rot90(ids, k)
            if random.random() < 0.5:
                image, ids = image[:, ::-1], ids[:, ::-1]
        ids = np.ascontiguousarray(ids[::STRIDE, ::STRIDE])
        piece, centre, offset = targets_from_ids(ids)
        tensor = (torch.from_numpy(np.ascontiguousarray(image)).permute(2, 0, 1).float() / 255 - torch.tensor(MEAN)[:, None, None]) / torch.tensor(STD)[:, None, None]
        return tensor, torch.from_numpy(piece), torch.from_numpy(centre), torch.from_numpy(offset), torch.from_numpy(ids.astype(np.int64))


@torch.no_grad()
def evaluate(model, loader, device):
    model.eval()
    hits = predicted = real = 0
    for images, _, _, _, ids in loader:
        out = model(images.to(device)).cpu()
        out[:, :2] = torch.sigmoid(out[:, :2])
        for maps, truth in zip(out.numpy(), ids.numpy()):
            h, p, t = match_instances(group_instances(maps), truth)
            hits, predicted, real = hits + h, predicted + p, real + t
    return hits / max(real, 1), hits / max(predicted, 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="ml/scenes")
    ap.add_argument("--out", default="ml/runs/detector")
    ap.add_argument("--encoder", default="mobilenetv3_large_100", help="any timm model that supports features_only")
    ap.add_argument("--no-pretrained", action="store_true")
    ap.add_argument("--crop", type=int, default=320)
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--batch-size", type=int, default=16)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--workers", type=int, default=min(8, os.cpu_count() or 1))
    args = ap.parse_args()

    device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
    files = sorted(glob.glob(os.path.join(args.data, "*.jpg")))
    files = [f for f in files if os.path.exists(f[:-4] + "_ids.png")]
    held_out = max(1, len(files) // 20)
    train_files, val_files = files[:-held_out], files[-held_out:]
    print(f"{len(train_files)} training and {len(val_files)} held-out scenes, device {device}")
    train_loader = DataLoader(Scenes(train_files, args.crop, True), batch_size=args.batch_size, shuffle=True, drop_last=True,
                              num_workers=args.workers, persistent_workers=args.workers > 0)
    val_loader = DataLoader(Scenes(val_files, args.crop, False), batch_size=4, num_workers=args.workers)

    model = PieceNet(args.encoder, pretrained=not args.no_pretrained).to(device)
    optimiser = torch.optim.AdamW(model.parameters(), lr=args.lr, weight_decay=1e-4)
    total = max(1, args.epochs * len(train_loader))
    warmup = max(1, min(len(train_loader), total // 10))
    schedule = torch.optim.lr_scheduler.LambdaLR(
        optimiser, lambda s: (s + 1) / warmup if s < warmup else 0.5 * (1 + math.cos(math.pi * (s - warmup) / max(1, total - warmup))))

    os.makedirs(args.out, exist_ok=True)
    best = -1.0
    for epoch in range(args.epochs):
        model.train()
        started, running, steps = time.time(), 0.0, 0
        for images, piece, centre, offset, _ in train_loader:
            loss = detector_loss(model(images.to(device)), piece.to(device), centre.to(device), offset.to(device))
            optimiser.zero_grad(set_to_none=True)
            loss.backward()
            optimiser.step()
            schedule.step()
            running, steps = running + loss.item(), steps + 1
        recall, precision = evaluate(model, val_loader, device)
        f1 = 2 * recall * precision / max(recall + precision, 1e-9)
        print(f"epoch {epoch + 1}/{args.epochs}  loss {running / max(steps, 1):.3f}  pieces found {recall:.1%}  "
              f"detections that are real pieces {precision:.1%}  F1 {f1:.3f}  {time.time() - started:.0f}s", flush=True)
        if f1 > best:
            best = f1
            torch.save({"state": model.state_dict(), "encoder": args.encoder}, os.path.join(args.out, "best.pt"))
    print(f"best F1 {best:.3f}; saved {os.path.join(args.out, 'best.pt')}")
    print("A piece counts as found when its predicted outline overlaps the true one by at least half. Held-out scenes are rendered too.")


if __name__ == "__main__":
    main()
