"""Minimal LDraw part loader: resolves sub-files and returns a triangle mesh in millimetres, Z up."""
from __future__ import annotations

import os
import re
from functools import lru_cache

import numpy as np

LDU_MM = 0.4
MAIN_COLOUR = 16   # "inherit": the colour the part is moulded in
EDGE_COLOUR = 24
# LDraw is -Y up; rotate (not mirror) into Z up so left- and right-handed parts stay distinct.
TO_Z_UP = np.array([[1, 0, 0], [0, 0, 1], [0, -1, 0]], dtype=np.float64)


class LDrawLibrary:
    def __init__(self, root: str, hi_res: bool = True):
        self.root = root
        self.index: dict[str, str] = {}
        # Later directories win, so high-resolution primitives replace the standard ones.
        for sub in ["models", "p/8", "p", "parts/s", "parts"]:
            self._scan(sub, prefix={"p/8": "8/", "parts/s": "s/"}.get(sub, ""))
        if hi_res:
            for name in list(self._names("p/48")):
                self.index[name] = os.path.join(root, "p/48", name)   # e.g. "stud.dat" -> p/48/stud.dat if present
        self._scan("p/48", prefix="48/")
        self.fixed_colours = self._load_colours()
        self._cache: dict[str, tuple[np.ndarray, np.ndarray]] = {}

    def _names(self, sub):
        path = os.path.join(self.root, sub)
        return [f.lower() for f in os.listdir(path) if f.lower().endswith(".dat")] if os.path.isdir(path) else []

    def _scan(self, sub, prefix=""):
        path = os.path.join(self.root, sub)
        if not os.path.isdir(path):
            return
        for f in os.listdir(path):
            if f.lower().endswith(".dat"):
                self.index[prefix + f.lower()] = os.path.join(path, f)

    def _load_colours(self) -> dict[int, tuple[float, float, float]]:
        out = {}
        path = os.path.join(self.root, "LDConfig.ldr")
        if os.path.exists(path):
            for line in open(path, encoding="utf-8", errors="replace"):
                m = re.search(r"!COLOUR\s+\S+\s+CODE\s+(\d+)\s+VALUE\s+#([0-9A-Fa-f]{6})", line)
                if m:
                    v = int(m.group(2), 16)
                    out[int(m.group(1))] = ((v >> 16) / 255, ((v >> 8) & 255) / 255, (v & 255) / 255)
        return out

    def has_part(self, part_num: str) -> bool:
        return os.path.exists(os.path.join(self.root, "parts", f"{part_num}.dat"))

    def _geometry(self, name: str, depth: int = 0) -> tuple[np.ndarray, np.ndarray]:
        """Triangles [n,3,3] in the file's own LDU coordinates and a colour code per triangle."""
        key = name.lower().replace("\\", "/")
        if key in self._cache:
            return self._cache[key]
        path = self.index.get(key)
        tris, cols = [], []
        if path and depth < 40:
            for line in open(path, encoding="utf-8", errors="replace"):
                t = line.split()
                if not t:
                    continue
                kind = t[0]
                try:
                    if kind == "1" and len(t) >= 15:
                        colour = _colour(t[1])
                        v = np.array(t[2:14], dtype=np.float64)
                        sub_t, sub_c = self._geometry(" ".join(t[14:]), depth + 1)
                        if len(sub_t):
                            tris.append(sub_t @ v[3:].reshape(3, 3).T + v[:3])
                            cols.append(np.where(sub_c == MAIN_COLOUR, colour, sub_c))
                    elif kind == "3" and len(t) >= 11:
                        tris.append(np.array(t[2:11], dtype=np.float64).reshape(1, 3, 3))
                        cols.append(np.array([_colour(t[1])]))
                    elif kind == "4" and len(t) >= 14:
                        q = np.array(t[2:14], dtype=np.float64).reshape(4, 3)
                        tris.append(np.stack([q[[0, 1, 2]], q[[0, 2, 3]]]))
                        cols.append(np.array([_colour(t[1])] * 2))
                except ValueError:
                    continue
        result = (np.concatenate(tris) if tris else np.zeros((0, 3, 3)),
                  np.concatenate(cols) if cols else np.zeros((0,), dtype=np.int64))
        self._cache[key] = result
        return result

    def load_part(self, part_num: str):
        """Returns (vertices [n*3,3] mm Z-up, faces [n,3], colour code per face). Colour 16 means the part's own colour."""
        tris, cols = self._geometry(f"{part_num}.dat")
        if not len(tris):
            raise FileNotFoundError(f"No LDraw geometry for part {part_num}")
        verts = (tris.reshape(-1, 3) @ TO_Z_UP.T) * LDU_MM
        faces = np.arange(len(verts)).reshape(-1, 3)
        cols = np.where(cols == EDGE_COLOUR, MAIN_COLOUR, cols)
        return verts.astype(np.float32), faces, cols


def _colour(token: str) -> int:
    return int(token, 16) if token.lower().startswith("0x") else int(token)
