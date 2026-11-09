"""Reference implementation of the on-device foot-measurement pipeline.

This is the *spec* that the iOS `FootMeasurementGeometry` (Swift) mirrors. Keeping a
pure-Python copy lets CI validate the algorithm against real and synthetic point sets
without ARKit. Pure Python (no numpy) so it stays dependency-light and trivially
comparable to the simd-based Swift port.

Pipeline (gravity-aligned input; `up` selects the vertical axis):
  1. Floor plane = tallest histogram bin of the vertical coordinate (lower 60% of range).
  2. Keep points from floor+FLOOR_BAND_MM up to LEG_CAP_MM (drops floor + attached shin).
  3. Isolate the foot: connected component containing the tap seed (or largest component).
  4. PCA in the horizontal plane -> long axis (heel->toe), rotation-invariant.
  5. length  = principal-axis extent (robust percentiles) + TIP_CORRECTION_MM (taper inset).
     width   = max secondary-axis extent within the forefoot region (the "ball").
     instep  = 95th-percentile dorsal height over the midfoot region.
"""

from __future__ import annotations

import math
from dataclasses import dataclass, field

# Tuned + validated against a parametric foot model (known ground truth) across sizes
# 235-320 mm and yaw 0-120 deg: width within 3 mm 98% of the time, length within 6 mm 85%.
FLOOR_BAND_MM = 10.0        # cut this far above the floor plane (clears noisy floor slab)
LEG_CAP_MM = 95.0           # ignore points taller than this (attached ankle/shin)
TIP_CORRECTION_MM = 26.0    # add back the toe+heel taper lost at the floor-band cut
MIN_POINTS = 80


@dataclass(frozen=True)
class FootMeasurement:
    length_mm: float
    ball_width_mm: float
    instep_mm: float
    n_points: int          # points in the isolated foot cluster (lock-on confidence)


@dataclass
class FootStages:
    """Every intermediate result of the pipeline, for replaying and inspecting a scan.

    `measure_foot` is `measure_foot_stages(...).measurement`; this exists so tooling
    (`server/scanlab`) can show *where* a capture stopped looking like a foot.
    """
    up: int
    a0: int                                 # horizontal axis indices
    a1: int
    n_input: int
    floor: float | None = None              # vertical coordinate of the floor plane (m)
    above: list = field(default_factory=list)   # points kept by the floor/leg height band
    band: list = field(default_factory=list)    # the isolated foot cluster
    centroid: tuple | None = None           # (a0, a1) mean of the cluster
    axis: tuple | None = None               # unit long-axis direction in (a0, a1)
    tmin: float | None = None               # robust extent along the long axis (m)
    tmax: float | None = None
    length_mm: float | None = None          # computed even when rejected as implausible
    ball_width_mm: float | None = None
    instep_mm: float | None = None
    measurement: FootMeasurement | None = None
    reject_reason: str | None = None        # None when a measurement was produced


def _percentile(sorted_vals: list[float], q: float) -> float:
    if not sorted_vals:
        return 0.0
    idx = q * (len(sorted_vals) - 1)
    lo = int(math.floor(idx))
    hi = int(math.ceil(idx))
    if lo == hi:
        return sorted_vals[lo]
    frac = idx - lo
    return sorted_vals[lo] * (1 - frac) + sorted_vals[hi] * frac


def _floor_level(sorted_vert: list[float], bin_mm: float = 5.0) -> float:
    lo, hi = sorted_vert[0], sorted_vert[-1]
    span = hi - lo
    if span <= 0:
        return lo
    nbins = max(4, int(span * 1000.0 / bin_mm))
    step = span / nbins
    counts = [0] * nbins
    for v in sorted_vert:
        b = min(nbins - 1, int((v - lo) / step))
        counts[b] += 1
    limit = max(1, int(nbins * 0.6))
    peak = max(range(limit), key=lambda i: counts[i])
    return lo + (peak + 0.5) * step


def _grid(points, a0, a1, cell_m):
    cells: dict[tuple[int, int], list[int]] = {}
    for i, p in enumerate(points):
        key = (int(math.floor(p[a0] / cell_m)), int(math.floor(p[a1] / cell_m)))
        cells.setdefault(key, []).append(i)
    return cells


def _component(cells, start):
    seen = {start}
    stack = [start]
    comp = []
    while stack:
        c = stack.pop()
        comp.append(c)
        cx, cy = c
        for dx in (-1, 0, 1):
            for dy in (-1, 0, 1):
                nb = (cx + dx, cy + dy)
                if nb in cells and nb not in seen:
                    seen.add(nb)
                    stack.append(nb)
    return comp


def _isolate(points, a0, a1, cell_m, seed):
    cells = _grid(points, a0, a1, cell_m)
    if not cells:
        return []
    if seed is not None:
        key = (int(math.floor(seed[0] / cell_m)), int(math.floor(seed[1] / cell_m)))
        if key not in cells:
            key = min(cells, key=lambda k: (k[0] - key[0]) ** 2 + (k[1] - key[1]) ** 2)
        comp = _component(cells, key)
    else:
        seen: set = set()
        best: list = []
        for start in cells:
            if start in seen:
                continue
            comp = _component(cells, start)
            seen.update(comp)
            idxs = [i for c in comp for i in cells[c]]
            if len(idxs) > len(best):
                best = idxs
        return [points[i] for i in best]
    return [points[i] for c in comp for i in cells[c]]


def measure_foot(points, up: int = 1, seed=None,
                 floor_band_mm: float = FLOOR_BAND_MM,
                 leg_cap_mm: float = LEG_CAP_MM,
                 tip_correction_mm: float = TIP_CORRECTION_MM,
                 min_points: int = MIN_POINTS) -> FootMeasurement | None:
    """Measure a foot from a (roughly foot-local) gravity-aligned point set.

    `points` is a sequence of (x, y, z) in meters. `up` is the vertical axis index
    (ARKit world Y=1; CoreMotion .xArbitraryZVertical Z=2). `seed` is an optional
    (horizontal_a, horizontal_b) tap point used to pick the foot the user aimed at.
    Returns None if no plausible foot cluster is found (drives capture rejection).
    """
    return measure_foot_stages(
        points, up=up, seed=seed, floor_band_mm=floor_band_mm, leg_cap_mm=leg_cap_mm,
        tip_correction_mm=tip_correction_mm, min_points=min_points,
    ).measurement


def measure_foot_stages(points, up: int = 1, seed=None,
                        floor_band_mm: float = FLOOR_BAND_MM,
                        leg_cap_mm: float = LEG_CAP_MM,
                        tip_correction_mm: float = TIP_CORRECTION_MM,
                        min_points: int = MIN_POINTS) -> FootStages:
    """Run the pipeline and keep every intermediate stage (see `FootStages`).

    Same arguments as `measure_foot`. On rejection, `reject_reason` says which step
    gave up and the stages computed up to that point are still populated.
    """
    ax = [i for i in range(3) if i != up]
    a0, a1 = ax
    st = FootStages(up=up, a0=a0, a1=a1, n_input=len(points))

    if len(points) < min_points:
        st.reject_reason = "too_few_points"
        return st

    vert = sorted(p[up] for p in points)
    floor = _floor_level(vert)
    st.floor = floor

    above = [p for p in points
             if floor_band_mm < (p[up] - floor) * 1000.0 <= leg_cap_mm]
    st.above = above
    if len(above) < min_points:
        st.reject_reason = "too_few_above_floor"
        return st

    band = _isolate(above, a0, a1, 0.02, seed)
    st.band = band
    n = len(band)
    if n < min_points:
        st.reject_reason = "cluster_too_small"
        return st

    # PCA in the horizontal plane.
    ma = sum(p[a0] for p in band) / n
    mb = sum(p[a1] for p in band) / n
    saa = sab = sbb = 0.0
    for p in band:
        da = p[a0] - ma
        db = p[a1] - mb
        saa += da * da
        sab += da * db
        sbb += db * db
    saa /= n
    sab /= n
    sbb /= n
    tr = saa + sbb
    det = saa * sbb - sab * sab
    disc = max(0.0, tr * tr / 4 - det)
    lam1 = tr / 2 + math.sqrt(disc)
    if abs(sab) > 1e-12:
        ux, uy = lam1 - sbb, sab
    else:
        ux, uy = (1.0, 0.0) if saa >= sbb else (0.0, 1.0)
    ulen = math.hypot(ux, uy) or 1.0
    ux, uy = ux / ulen, uy / ulen
    vx, vy = -uy, ux
    st.centroid = (ma, mb)
    st.axis = (ux, uy)

    proj = []
    for p in band:
        da = p[a0] - ma
        db = p[a1] - mb
        proj.append((da * ux + db * uy, da * vx + db * vy, (p[up] - floor) * 1000.0))

    ts = sorted(t for t, _, _ in proj)
    tmin = _percentile(ts, 0.005)
    tmax = _percentile(ts, 0.995)
    span = tmax - tmin or 1.0
    length_mm = span * 1000.0 + tip_correction_mm
    st.tmin, st.tmax = tmin, tmax

    def width_in(lo_frac, hi_frac):
        lo = tmin + lo_frac * span
        hi = tmin + hi_frac * span
        ws = [w for t, w, _ in proj if lo <= t <= hi]
        return (max(ws) - min(ws)) * 1000.0 if len(ws) > 5 else 0.0

    # Forefoot region at whichever end reads as the ball (take the larger).
    ball_width_mm = max(width_in(0.45, 0.95), width_in(0.05, 0.55))

    mid_lo = tmin + 0.35 * span
    mid_hi = tmin + 0.60 * span
    mid_h = sorted(h for t, _, h in proj if mid_lo <= t <= mid_hi)
    instep_mm = _percentile(mid_h, 0.95) if mid_h else 0.0
    st.length_mm, st.ball_width_mm, st.instep_mm = length_mm, ball_width_mm, instep_mm

    if not (120.0 < length_mm < 400.0 and 40.0 < ball_width_mm < 200.0):
        st.reject_reason = "implausible_size"
        return st
    st.measurement = FootMeasurement(
        length_mm=length_mm,
        ball_width_mm=ball_width_mm,
        instep_mm=instep_mm,
        n_points=n,
    )
    return st
