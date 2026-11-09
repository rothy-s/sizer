"""Tests for the foot-measurement pipeline (`foot_geometry_reference.measure_foot`),
the pure-Python spec that the iOS `FootMeasurementGeometry` (Swift) mirrors.

Validates the algorithm the way the app relies on it:
  * accuracy vs KNOWN dimensions on a parametric foot model, across sizes + rotations,
  * rotation invariance (the old AABB inflated length badly when a foot sat at an angle),
  * floor isolation on a real Scaniverse scan cropped like the app's tap+radius capture,
  * rejection of implausible / too-sparse inputs (drives capture rejection in-app).
"""

from __future__ import annotations

import math
import random
from pathlib import Path

import pytest

from foot_geometry_reference import measure_foot

REPO_ROOT = Path(__file__).resolve().parents[2]
REAL_SCAN = REPO_ROOT / "tests" / "fixtures" / "Scaniverse_2026_03_24_232742.obj"


# --- Parametric foot model with known dimensions (ground truth) ---------------

_OUTLINE = [(0.00, 0.50), (0.12, 0.62), (0.30, 0.55), (0.50, 0.62),
            (0.72, 1.00), (0.85, 0.92), (1.00, 0.34)]


def _half_width_frac(t: float) -> float:
    for i in range(len(_OUTLINE) - 1):
        t0, w0 = _OUTLINE[i]
        t1, w1 = _OUTLINE[i + 1]
        if t0 <= t <= t1:
            f = (t - t0) / (t1 - t0)
            return (w0 + f * (w1 - w0)) * 0.5
    return 0.18


def make_foot(length_mm, ball_width_mm, instep_mm, yaw_deg, *,
              up=1, n=4000, floor_n=3000, noise_mm=1.5, seed=7):
    rng = random.Random(seed)
    L = length_mm / 1000.0
    Wb = ball_width_mm / 1000.0
    Ih = instep_mm / 1000.0
    ax = [i for i in range(3) if i != up]
    a0, a1 = ax
    c, s = math.cos(math.radians(yaw_deg)), math.sin(math.radians(yaw_deg))
    pts = []

    def place(la, wa, h):
        p = [0.0, 0.0, 0.0]
        p[a0] = (la * c - wa * s) + rng.uniform(-noise_mm, noise_mm) / 1000.0
        p[a1] = (la * s + wa * c) + rng.uniform(-noise_mm, noise_mm) / 1000.0
        p[up] = h + rng.uniform(-noise_mm, noise_mm) / 1000.0
        return tuple(p)

    for _ in range(n):
        t = rng.random()
        hw = _half_width_frac(t) * Wb
        w = rng.uniform(-hw, hw)
        la = t * L - L / 2.0
        dome = math.sin(math.pi * min(1.0, max(0.0, t))) ** 0.7
        top = Ih * dome
        h = rng.uniform(0.0, top) if top > 0.005 else rng.uniform(0.0, 0.01)
        pts.append(place(la, w, h))

    for _ in range(floor_n):
        pts.append(place(rng.uniform(-0.5, 0.5), rng.uniform(-0.5, 0.5),
                         rng.uniform(-0.004, 0.010)))
    return pts


# --- Accuracy + rotation invariance ------------------------------------------

@pytest.mark.parametrize("length_mm,width_mm,instep_mm", [
    (280, 100, 68), (250, 95, 60), (300, 110, 72), (235, 88, 55), (320, 118, 75),
])
@pytest.mark.parametrize("yaw", [0, 20, 45, 75, 120])
def test_recovers_known_dimensions(length_mm, width_mm, instep_mm, yaw):
    pts = make_foot(length_mm, width_mm, instep_mm, yaw)
    m = measure_foot(pts, up=1)
    assert m is not None
    assert abs(m.length_mm - length_mm) <= 12.0, (m.length_mm, length_mm, yaw)
    assert abs(m.ball_width_mm - width_mm) <= 6.0, (m.ball_width_mm, width_mm, yaw)


def test_rotation_invariance_length_stable():
    """The old AABB blew up at 45 deg; PCA length must barely move with yaw."""
    lengths = []
    for yaw in (0, 15, 30, 45, 60, 75, 90):
        m = measure_foot(make_foot(280, 100, 68, yaw), up=1)
        assert m is not None
        lengths.append(m.length_mm)
    assert max(lengths) - min(lengths) <= 15.0, lengths


# --- Rejection ----------------------------------------------------------------

def test_too_few_points_rejected():
    assert measure_foot([(0, 0, 0), (0.1, 0.05, 0.1)], up=1) is None


def test_floor_only_rejected():
    rng = random.Random(1)
    floor = [(rng.uniform(-0.3, 0.3), rng.uniform(-0.004, 0.01), rng.uniform(-0.3, 0.3))
             for _ in range(3000)]
    assert measure_foot(floor, up=1) is None


# --- Real scan, app-style crop ------------------------------------------------

def _load_obj(path):
    pts = []
    with open(path) as f:
        for line in f:
            if line.startswith("v "):
                p = line.split()
                pts.append((float(p[1]), float(p[2]), float(p[3])))
    return pts


@pytest.mark.skipif(not REAL_SCAN.is_file(), reason="real scan fixture not present")
def test_real_scan_cropped_gives_plausible_foot():
    """Mimic the app: crop a 0.22 m sphere around a tap on the foot, then isolate.
    The whole-room AABB would report ~700 mm; the pipeline must land in foot range."""
    pts = _load_obj(REAL_SCAN)
    vert = sorted(p[1] for p in pts)
    from foot_geometry_reference import _floor_level
    floor = _floor_level(vert)
    mid = [p for p in pts if 30 < (p[1] - floor) * 1000 <= 70]
    cells: dict = {}
    for p in mid:
        cells.setdefault((round(p[0], 2), round(p[2], 2)), []).append(p)
    (sx, sz), cell_pts = max(cells.items(), key=lambda kv: len(kv[1]))
    sy = sum(p[1] for p in cell_pts) / len(cell_pts)
    crop = [p for p in pts if math.dist(p, (sx, sy, sz)) <= 0.22]
    m = measure_foot(crop, up=1, seed=(sx, sz))
    assert m is not None
    assert 150.0 < m.length_mm < 340.0, m.length_mm
    assert 60.0 < m.ball_width_mm < 200.0, m.ball_width_mm
