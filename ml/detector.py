"""Piece detector: separates every piece on the table, including pieces that touch.

For each pixel the network predicts whether it is part of a piece, how close it is to a piece's centre,
and the offset from the pixel to the centre of the piece it belongs to. Pieces are then recovered by
finding the centre peaks and giving each piece-pixel to the peak its offset points at. Two touching
pieces share an edge but not a centre, which is what lets this split them.
"""
import numpy as np
import timm
import torch
import torch.nn as nn
import torch.nn.functional as F

STRIDE = 2   # the output maps are half the input resolution


class PieceNet(nn.Module):
    def __init__(self, encoder: str = "mobilenetv3_large_100", pretrained: bool = True, width: int = 64):
        super().__init__()
        self.encoder = timm.create_model(encoder, features_only=True, pretrained=pretrained)
        channels = self.encoder.feature_info.channels()
        self.lateral = nn.ModuleList(nn.Conv2d(c, width, 1) for c in channels)
        self.smooth = nn.ModuleList(nn.Sequential(nn.Conv2d(width, width, 3, padding=1, bias=False), nn.BatchNorm2d(width), nn.ReLU(inplace=True))
                                    for _ in channels)
        self.head = nn.Sequential(nn.Conv2d(width, width, 3, padding=1, bias=False), nn.BatchNorm2d(width), nn.ReLU(inplace=True),
                                  nn.Conv2d(width, 4, 1))

    def forward(self, images):
        """[B,4,H/2,W/2]: piece logit, centre logit, x offset, y offset (offsets in output pixels)."""
        features = self.encoder(images)
        y = self.lateral[-1](features[-1])
        for i in range(len(features) - 2, -1, -1):
            y = self.smooth[i](self.lateral[i](features[i]) + F.interpolate(y, size=features[i].shape[-2:], mode="nearest"))
        return self.head(y)


def detector_loss(out, piece, centre, offset):
    """`piece` and `centre` are [B,H,W] targets in 0..1; `offset` is [B,2,H,W]."""
    piece_loss = F.binary_cross_entropy_with_logits(out[:, 0], piece)
    # Centre peaks are a tiny fraction of the image, so errors near them are weighted up.
    centre_loss = (((torch.sigmoid(out[:, 1]) - centre) ** 2) * (1 + 30 * centre)).mean()
    mask = piece[:, None]
    offset_loss = (F.smooth_l1_loss(out[:, 2:], offset, reduction="none") * mask).sum() / (mask.sum() * 2 + 1)
    return piece_loss + 4 * centre_loss + 0.2 * offset_loss


def targets_from_ids(ids: np.ndarray):
    """Training targets at output resolution from a piece-number map that is already at output resolution."""
    h, w = ids.shape
    ids = ids.astype(np.int64)
    piece = (ids > 0).astype(np.float32)
    flat = ids.ravel()
    size = int(ids.max()) + 1
    count = np.bincount(flat, minlength=size).astype(np.float32)
    ys, xs = np.mgrid[0:h, 0:w].astype(np.float32)
    cx = np.bincount(flat, weights=xs.ravel(), minlength=size) / np.maximum(count, 1)
    cy = np.bincount(flat, weights=ys.ravel(), minlength=size) / np.maximum(count, 1)
    offset = np.stack([(cx[ids] - xs) * piece, (cy[ids] - ys) * piece]).astype(np.float32)
    centre = np.zeros((h, w), dtype=np.float32)
    for i in np.nonzero(count[1:])[0] + 1:
        sigma = 1.0 + 0.12 * np.sqrt(count[i])   # bigger pieces get broader peaks
        r = int(3 * sigma) + 1
        x0, x1 = max(0, int(cx[i]) - r), min(w, int(cx[i]) + r + 1)
        y0, y1 = max(0, int(cy[i]) - r), min(h, int(cy[i]) + r + 1)
        g = np.exp(-((xs[y0:y1, x0:x1] - cx[i]) ** 2 + (ys[y0:y1, x0:x1] - cy[i]) ** 2) / (2 * sigma ** 2))
        centre[y0:y1, x0:x1] = np.maximum(centre[y0:y1, x0:x1], g)
    return piece, centre, offset


def group_instances(maps: np.ndarray, piece_threshold=0.5, peak_threshold=0.3, min_area=6):
    """Turn network output [4,H,W] (piece and centre already passed through a sigmoid) into a piece-number map.

    The iPhone app implements the same steps in InstanceDetector.swift; keep the two in step.
    """
    piece, centre, dx, dy = maps
    h, w = piece.shape
    mask = piece > piece_threshold
    # Peaks: strongest value in their 3 x 3 neighbourhood.
    padded = np.pad(centre, 1, constant_values=-1)
    neighbourhood = np.max([padded[1 + a:1 + a + h, 1 + b:1 + b + w] for a in (-1, 0, 1) for b in (-1, 0, 1)], axis=0)
    # A peak may lie off the piece itself: the centre of a ring or a window frame is a hole.
    py, px = np.nonzero((centre >= neighbourhood) & (centre > peak_threshold))
    order = np.argsort(-centre[py, px])
    peaks = []
    for i in order:   # a broad peak can have several maxima: keep the strongest within 2.5 pixels
        if all((px[i] - qx) ** 2 + (py[i] - qy) ** 2 > 6.25 for qx, qy in peaks):
            peaks.append((px[i], py[i]))
    ids = np.zeros((h, w), dtype=np.int32)
    if not peaks:
        return ids
    ys, xs = np.nonzero(mask)
    voted = np.stack([xs + dx[ys, xs], ys + dy[ys, xs]], axis=1)
    nearest = np.argmin(((voted[:, None, :] - np.asarray(peaks, dtype=np.float32)[None]) ** 2).sum(axis=2), axis=1)
    ids[ys, xs] = nearest + 1
    for i, n in enumerate(np.bincount(ids.ravel(), minlength=len(peaks) + 1)):
        if i and n < min_area:
            ids[ids == i] = 0
    return ids


def _on_border(ids, size):
    edge = np.concatenate([ids[0], ids[-1], ids[:, 0], ids[:, -1]])
    out = np.zeros(size, dtype=bool)
    out[edge] = True
    return out


def score_instances(predicted: np.ndarray, truth: np.ndarray, iou_threshold=0.5):
    """Compare predicted pieces with the true ones, the way the app experiences them.

    A piece counts as found when a predicted outline overlaps it by at least half (intersection over union).
    Pieces cut by the frame edge are left out on both sides, because the app ignores those and waits for a
    frame showing the whole piece. Returns counts: found/total for pieces standing apart and for pieces
    touching a neighbour, plus how many predictions matched nothing.
    """
    predicted, truth = predicted.astype(np.int64), truth.astype(np.int64)
    np_, nt = int(predicted.max()) + 1, int(truth.max()) + 1
    inter = np.bincount((predicted * nt + truth).ravel(), minlength=np_ * nt).reshape(np_, nt)
    p_area, t_area = inter.sum(axis=1), inter.sum(axis=0)
    p_border, t_border = _on_border(predicted, np_), _on_border(truth, nt)

    # A true piece touches a neighbour if any of its pixels sits next to a different piece.
    touching = np.zeros(nt, dtype=bool)
    for a, b in ((truth[:, :-1], truth[:, 1:]), (truth[:-1], truth[1:])):
        differ = (a != b) & (a > 0) & (b > 0)
        touching[a[differ]] = True
        touching[b[differ]] = True

    out = {"apart_found": 0, "apart_total": 0, "touching_found": 0, "touching_total": 0, "false": 0, "predicted": 0}
    matched = np.zeros(np_, dtype=bool)
    for t in range(1, nt):
        if t_area[t] == 0:
            continue
        best = int(np.argmax(inter[1:, t])) + 1 if np_ > 1 else 0
        hit = best > 0 and inter[best, t] / (p_area[best] + t_area[t] - inter[best, t]) >= iou_threshold
        if hit:
            matched[best] = True
        if t_border[t]:
            continue
        kind = "touching" if touching[t] else "apart"
        out[kind + "_total"] += 1
        out[kind + "_found"] += int(hit)
    for p in range(1, np_):
        if p_area[p] and not p_border[p]:
            out["predicted"] += 1
            out["false"] += int(not matched[p])
    return out
