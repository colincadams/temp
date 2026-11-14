"""Train the part recognition model on rendered images.

    python ml/train.py --data ml/dataset --manifest ml/manifest.json --out ml/runs/v1

Uses an NVIDIA GPU, Apple Silicon GPU, or CPU, whichever is available. If a run is interrupted,
repeat the command with --resume to continue from the last finished epoch.
"""
import argparse
import csv
import glob
import json
import math
import os
import time
import zlib

import torch
from PIL import Image
from torch.utils.data import DataLoader, Dataset
from torchvision.transforms import v2 as T

from model import MEAN, STD, PartNet, margin_loss


class Crops(Dataset):
    def __init__(self, root, rows, transform):
        self.root, self.rows, self.transform = root, rows, transform

    def __len__(self):
        return len(self.rows)

    def __getitem__(self, i):
        path, label = self.rows[i]
        return self.transform(Image.open(os.path.join(self.root, path)).convert("RGB")), label


def load_rows(root, class_index):
    train, val = [], []
    for labels in sorted(glob.glob(os.path.join(root, "labels-*.csv"))):
        for r in csv.DictReader(open(labels)):
            if int(r["class_id"]) not in class_index:
                continue
            row = (r["file"], class_index[int(r["class_id"])])
            (val if zlib.crc32(r["file"].encode()) % 20 == 0 else train).append(row)   # stable 5% hold-out
    return train, val


def transforms(size):
    to_tensor = [T.ToImage(), T.ToDtype(torch.float32, scale=True), T.Normalize(MEAN, STD)]
    # Colour is measured separately, so the model is taught to ignore lighting and tint and to cope with blur.
    train = T.Compose([
        T.RandomResizedCrop(size, scale=(0.55, 1.0), ratio=(0.8, 1.25)),
        T.RandomHorizontalFlip(p=0.0),   # never mirror: left- and right-handed parts are different parts
        T.ColorJitter(brightness=0.35, contrast=0.35, saturation=0.3, hue=0.03),
        T.RandomGrayscale(p=0.05),
        T.RandomApply([T.GaussianBlur(5, sigma=(0.2, 2.0))], p=0.4),
        *to_tensor,
    ])
    val = T.Compose([T.Resize(size), T.CenterCrop(size), *to_tensor])
    return train, val


@torch.no_grad()
def evaluate(model, loader, device):
    model.eval()
    top1 = top5 = total = 0
    for images, labels in loader:
        cosine = model(images.to(device))
        ranked = cosine.topk(min(5, cosine.shape[1]), dim=1).indices.cpu()
        top1 += (ranked[:, 0] == labels).sum().item()
        top5 += (ranked == labels[:, None]).any(dim=1).sum().item()
        total += len(labels)
    return top1 / max(total, 1), top5 / max(total, 1)


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="ml/dataset")
    ap.add_argument("--manifest", default="ml/manifest.json")
    ap.add_argument("--out", default="ml/runs/v1")
    ap.add_argument("--backbone", default="vit_small_patch14_dinov2.lvd142m", help="any timm model name")
    ap.add_argument("--no-pretrained", action="store_true")
    ap.add_argument("--image-size", type=int, default=224)
    ap.add_argument("--epochs", type=int, default=20)
    ap.add_argument("--batch-size", type=int, default=128)
    ap.add_argument("--lr", type=float, default=1e-4)
    ap.add_argument("--workers", type=int, default=min(8, os.cpu_count() or 1))
    ap.add_argument("--resume", action="store_true", help="continue an interrupted run from the last finished epoch in --out")
    args = ap.parse_args()

    device = "cuda" if torch.cuda.is_available() else "mps" if torch.backends.mps.is_available() else "cpu"
    manifest = {c["class_id"]: c for c in json.load(open(args.manifest))["classes"]}
    present = sorted({int(r["class_id"]) for f in glob.glob(os.path.join(args.data, "labels-*.csv")) for r in csv.DictReader(open(f))})
    class_ids = [c for c in present if c in manifest]
    class_index = {c: i for i, c in enumerate(class_ids)}
    train_rows, val_rows = load_rows(args.data, class_index)
    print(f"{len(class_ids)} classes, {len(train_rows)} training and {len(val_rows)} held-out images, device {device}")

    train_tf, val_tf = transforms(args.image_size)
    train_loader = DataLoader(Crops(args.data, train_rows, train_tf), batch_size=args.batch_size, shuffle=True,
                              num_workers=args.workers, drop_last=True, persistent_workers=args.workers > 0)
    val_loader = DataLoader(Crops(args.data, val_rows, val_tf), batch_size=args.batch_size, num_workers=args.workers)

    model = PartNet(args.backbone, len(class_ids), args.image_size, pretrained=not args.no_pretrained).to(device)
    head = [p for n, p in model.named_parameters() if not n.startswith("backbone.")]
    optimiser = torch.optim.AdamW([{"params": model.backbone.parameters(), "lr": args.lr},
                                   {"params": head, "lr": args.lr * 10}], weight_decay=0.05)
    total_steps = max(1, args.epochs * len(train_loader))
    warmup = min(len(train_loader), total_steps // 10)
    schedule = torch.optim.lr_scheduler.LambdaLR(
        optimiser, lambda s: (s + 1) / max(warmup, 1) if s < warmup else 0.5 * (1 + math.cos(math.pi * (s - warmup) / max(1, total_steps - warmup))))

    os.makedirs(args.out, exist_ok=True)
    best, first_epoch = -1.0, 0
    last_path = os.path.join(args.out, "last.pt")
    if args.resume and os.path.exists(last_path):
        last = torch.load(last_path, map_location=device, weights_only=False)
        if last["class_ids"] != class_ids:
            raise SystemExit("The dataset's shapes differ from the interrupted run's; start a new run in a different --out.")
        model.load_state_dict(last["state"])
        optimiser.load_state_dict(last["optimiser"])
        schedule.load_state_dict(last["schedule"])
        best, first_epoch = last["best"], last["epoch"] + 1
        print(f"resuming after epoch {first_epoch} (best held-out top-1 so far {best:.1%})")
    for epoch in range(first_epoch, args.epochs):
        model.train()
        started, running, seen = time.time(), 0.0, 0
        for images, labels in train_loader:
            images, labels = images.to(device), labels.to(device)
            loss = margin_loss(model(images), labels)
            optimiser.zero_grad(set_to_none=True)
            loss.backward()
            torch.nn.utils.clip_grad_norm_(model.parameters(), 1.0)
            optimiser.step()
            schedule.step()
            running += loss.item() * len(labels)
            seen += len(labels)
        top1, top5 = evaluate(model, val_loader, device)
        print(f"epoch {epoch + 1}/{args.epochs}  loss {running / max(seen, 1):.3f}  held-out top-1 {top1:.1%}  top-5 {top5:.1%}  {time.time() - started:.0f}s", flush=True)
        if top1 > best:
            best = top1
            torch.save({"state": model.state_dict(), "backbone": args.backbone, "image_size": args.image_size,
                        "classes": [manifest[c] for c in class_ids]}, os.path.join(args.out, "best.pt"))
        torch.save({"state": model.state_dict(), "optimiser": optimiser.state_dict(), "schedule": schedule.state_dict(),
                    "epoch": epoch, "best": best, "class_ids": class_ids}, last_path + ".tmp")
        os.replace(last_path + ".tmp", last_path)
    print(f"best held-out top-1 {best:.1%}; saved {os.path.join(args.out, 'best.pt')}")
    print("Held-out images are synthetic too. Measure real accuracy with ml/evaluate.py on photos of your own pieces.")


if __name__ == "__main__":
    main()
