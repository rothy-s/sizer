"""On-disk scan bundle format — the Python mirror of `ScanRecorder.swift`.

    <bundle>/meta.json        snake_case metadata (see `ScanBundleMeta` in Swift)
    <bundle>/points.f32       little-endian float32 x,y,z triples, meters
    <bundle>/frame_index.u8   per point: frame it came from (255 = scene-mesh vertex)
    <bundle>/photo.jpg        optional camera photo

Schema 1: `points.f32` is the engine input (already fused on the device).
Schema 2: `points.f32` holds the raw per-frame depth samples of a sweep; the engine input
is `fuse_frames(points, frame_index)`. `read_bundle` does that fusion, so `points` is
always the engine input and `raw_points` keeps what was recorded.
"""

from __future__ import annotations

import json
import sys
from array import array
from dataclasses import dataclass
from pathlib import Path

SCHEMA_VERSION = 1
RAW_FRAMES_SCHEMA_VERSION = 2
SUPPORTED_SCHEMAS = (SCHEMA_VERSION, RAW_FRAMES_SCHEMA_VERSION)
MESH_FRAME_INDEX = 255


@dataclass
class ScanBundle:
    path: Path
    meta: dict
    points: list            # [(x, y, z)] in meters — the engine input
    frame_index: bytes      # per recorded point, or empty when not recorded
    raw_points: list | None = None   # schema 2: per-frame samples before fusion

    @property
    def id(self) -> str:
        return self.meta.get("id") or self.path.name

    @property
    def up(self) -> int:
        return int(self.meta.get("vertical_axis", 1))

    @property
    def seed(self):
        seed = self.meta.get("seed")
        return tuple(seed) if seed else None

    @property
    def photo_path(self) -> Path | None:
        p = self.path / "photo.jpg"
        return p if p.exists() else None


def _floats_from_le_bytes(raw: bytes) -> array:
    vals = array("f")
    vals.frombytes(raw)
    if sys.byteorder == "big":
        vals.byteswap()
    return vals


def read_bundle(path) -> ScanBundle:
    path = Path(path)
    meta = json.loads((path / "meta.json").read_text())
    version = meta.get("schema_version")
    if version not in SUPPORTED_SCHEMAS:
        raise ValueError(f"{path.name}: unsupported schema_version {version!r} (reader supports {SUPPORTED_SCHEMAS})")

    raw = (path / "points.f32").read_bytes()
    if len(raw) % 12:
        raise ValueError(f"{path.name}: points.f32 is {len(raw)} bytes, not a multiple of 12")
    flat = _floats_from_le_bytes(raw)
    points = [(flat[i], flat[i + 1], flat[i + 2]) for i in range(0, len(flat), 3)]
    declared = meta.get("point_count")
    if declared is not None and declared != len(points):
        raise ValueError(f"{path.name}: meta says {declared} points, points.f32 has {len(points)}")

    fi_path = path / "frame_index.u8"
    frame_index = fi_path.read_bytes() if fi_path.exists() else b""
    if frame_index and len(frame_index) != len(points):
        raise ValueError(f"{path.name}: frame_index.u8 has {len(frame_index)} entries for {len(points)} points")
    if version == RAW_FRAMES_SCHEMA_VERSION:
        from foot_geometry_reference import fuse_frames
        fused = fuse_frames(points, frame_index)
        return ScanBundle(path=path, meta=meta, points=fused, frame_index=frame_index, raw_points=points)
    return ScanBundle(path=path, meta=meta, points=points, frame_index=frame_index)


def write_bundle(root, meta: dict, points, frame_index: bytes = b"", photo: bytes | None = None) -> Path:
    """Write a bundle under `root/<meta['id']>/` (used for fixtures and synthetic scans)."""
    meta = dict(meta)
    meta.setdefault("schema_version", SCHEMA_VERSION)
    meta["point_count"] = len(points)
    meta["has_photo"] = photo is not None
    path = Path(root) / meta["id"]
    path.mkdir(parents=True, exist_ok=True)

    flat = array("f", [c for p in points for c in p])
    if sys.byteorder == "big":
        flat.byteswap()
    (path / "points.f32").write_bytes(flat.tobytes())
    (path / "frame_index.u8").write_bytes(bytes(frame_index))
    if photo is not None:
        (path / "photo.jpg").write_bytes(photo)
    (path / "meta.json").write_text(json.dumps(meta, indent=2, sort_keys=True))
    return path


def find_bundles(paths) -> list[Path]:
    """Expand files/directories into bundle directories (those containing a meta.json)."""
    found: list[Path] = []
    for raw in paths:
        p = Path(raw)
        if (p / "meta.json").exists():
            found.append(p)
        elif p.is_dir():
            found.extend(sorted(c.parent for c in p.rglob("meta.json")))
        else:
            raise FileNotFoundError(f"{p} is not a scan bundle or a directory of bundles")
    return found
