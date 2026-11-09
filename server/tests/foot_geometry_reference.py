"""Reference implementation of the on-device foot-measurement pipeline.

This is the *spec* that the iOS `FootMeasurementGeometry` (Swift) mirrors. Keeping a
pure-Python copy lets CI validate the algorithm against real and synthetic point sets
without ARKit. Pure Python (no numpy) so it stays dependency-light and trivially
comparable to the simd-based Swift port.

Pipeline (gravity-aligned input; `up` selects the vertical axis):
  1. Floor plane = tallest histogram bin of the vertical coordinate (lower 60% of range),
     refined by a least-squares plane fit (real floors read 2-4 mm/100 mm off level).
  2. Keep points from floor+FLOOR_BAND_MM up to LEG_CAP_MM (drops floor + attached shin).
     Under a leg column (a 10 mm cell holding points above the cap) keep only points up
     to LEG_SHADOW_CAP_MM: anything higher there is shin or trouser, not foot.
  3. Isolate the foot: morphological opening on a 10 mm grid (drops thin streaks such as
     a trouser edge or a neighbouring foot's rim), then the connected component at the
     tap seed (or the largest one). Sparse clouds fall back to 20 mm-cell clustering.
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
LEG_SHADOW_CAP_MM = 60.0    # height cap inside a leg column (cell with points above LEG_CAP_MM)
ANKLE_SLICE_MM = 35.0       # leg points this far above LEG_CAP_MM mark where the ankle stands
MAX_FLOOR_SLOPE = 0.12      # ignore a fitted floor steeper than this (m/m): not a floor
GRID_CELL_M = 0.01          # isolation grid
TIP_CORRECTION_MM = 26.0    # add back the toe+heel taper lost at the floor-band cut
MIN_POINTS = 80
FUSE_VOXEL_M = 0.005        # sweep fusion voxel
FUSE_MIN_FRAMES = 3         # a voxel must be seen in this many frames to count as surface


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
    floor: float | None = None              # vertical coordinate of the floor level (m)
    # Fitted floor: vertical = a*p[a0] + b*p[a1] + c. Use `height_mm` for heights.
    floor_plane: tuple | None = None
    leg_cells: set = field(default_factory=set)     # 10 mm cells holding points above the leg cap
    # True when the heel end of the length comes from the ankle's footprint rather than
    # from heel points the camera actually saw (the heel sits under the ankle).
    heel_hidden: bool = False
    ankle_cells: set = field(default_factory=set)   # ankle-slice cells joined to the cluster
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

    def height_mm(self, p) -> float:
        """Height of `p` above the fitted floor, in mm."""
        if self.floor_plane is not None:
            a, b, c = self.floor_plane
            return (p[self.up] - (a * p[self.a0] + b * p[self.a1] + c)) * 1000.0
        return (p[self.up] - (self.floor or 0.0)) * 1000.0
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


def _fit_floor_plane(points, up, a0, a1, level):
    """Least-squares plane through the points near `level`: vertical = a*h0 + b*h1 + c.

    Three passes with a tightening inlier band. Falls back to the level plane when the
    fit is degenerate or steeper than MAX_FLOOR_SLOPE.
    """
    a = b = 0.0
    c = level
    for tol in (0.015, 0.008, 0.006):
        sel = [p for p in points if abs(p[up] - (a * p[a0] + b * p[a1] + c)) <= tol]
        n = len(sel)
        if n < 50:
            break
        mx = sum(p[a0] for p in sel) / n
        my = sum(p[a1] for p in sel) / n
        mz = sum(p[up] for p in sel) / n
        sxx = sxy = syy = sxz = syz = 0.0
        for p in sel:
            dx = p[a0] - mx
            dy = p[a1] - my
            dz = p[up] - mz
            sxx += dx * dx
            sxy += dx * dy
            syy += dy * dy
            sxz += dx * dz
            syz += dy * dz
        det = sxx * syy - sxy * sxy
        if abs(det) < 1e-12:
            break
        a = (sxz * syy - syz * sxy) / det
        b = (syz * sxx - sxz * sxy) / det
        c = mz - a * mx - b * my
    if abs(a) > MAX_FLOOR_SLOPE or abs(b) > MAX_FLOOR_SLOPE:
        return 0.0, 0.0, level
    return a, b, c


def _cell(p, a0, a1, cell_m=GRID_CELL_M):
    return (int(math.floor(p[a0] / cell_m)), int(math.floor(p[a1] / cell_m)))


def _neighbours(k):
    return [(k[0] + dx, k[1] + dy) for dx in (-1, 0, 1) for dy in (-1, 0, 1)]


def _isolate_opened(points, a0, a1, seed, bridge=frozenset()):
    """Foot cluster via morphological opening on the 10 mm grid.

    A cell is *core* when at least 7 of its 3x3 block are occupied; cores form connected
    components; the chosen component (nearest the seed, else the most points) is grown
    back by one cell. Structures under ~30 mm wide never form a core, so they drop out.
    `bridge` cells count as occupied without holding points: the ankle stands on the heel,
    so its footprint joins the forefoot to whatever heel points lie behind the leg.
    Returns (points, bridge cells kept); ([], set()) when the cloud is too sparse to have
    any core cell.
    """
    cells: dict = {}
    for i, p in enumerate(points):
        cells.setdefault(_cell(p, a0, a1), []).append(i)
    occupied = set(cells) | set(bridge)
    core = {k for k in occupied if sum(1 for q in _neighbours(k) if q in occupied) >= 7}
    if not core:
        return [], set()

    def component(start):
        seen = {start}
        stack = [start]
        while stack:
            k = stack.pop()
            for q in _neighbours(k):
                if q in core and q not in seen:
                    seen.add(q)
                    stack.append(q)
        return seen

    def grown(comp):
        return {q for k in comp for q in _neighbours(k) if q in occupied}

    if seed is not None:
        sk = (int(math.floor(seed[0] / GRID_CELL_M)), int(math.floor(seed[1] / GRID_CELL_M)))
        # Deterministic tie-break (distance, then cell) so Swift and Python agree.
        start = min(core, key=lambda k: ((k[0] - sk[0]) ** 2 + (k[1] - sk[1]) ** 2, k))
        keep = grown(component(start))
    else:
        keep = set()
        best = -1
        seen: set = set()
        for start in sorted(core):
            if start in seen:
                continue
            comp = component(start)
            seen |= comp
            g = grown(comp)
            count = sum(len(cells.get(k, ())) for k in g)
            if count > best:
                best, keep = count, g
    kept_points = [points[i] for k in sorted(keep) if k in cells for i in cells[k]]
    return kept_points, {k for k in keep if k not in cells}


def fuse_frames(points, frame_index, voxel_m: float = FUSE_VOXEL_M,
                min_frames: int = FUSE_MIN_FRAMES):
    """Fuse a sweep's raw per-frame depth samples into one cloud by consensus.

    Frames taken while the phone moves disagree by 10-25 mm (pose drift, depth noise), so
    a union of all samples turns every surface into a thick slab. Samples are binned into
    `voxel_m` voxels; a voxel survives only when at least `min_frames` different frames
    hit it (fewer for very short sweeps), and contributes the mean of its samples.

    `frame_index[i]` is the frame of `points[i]`; samples of one frame must be contiguous.
    Output order is first-seen voxel order; coordinates are rounded to float32 like Swift.
    """
    from array import array
    n_frames = len(set(frame_index))
    need = min(min_frames, max(1, n_frames // 3))
    vox: dict = {}
    for p, f in zip(points, frame_index):
        k = (int(math.floor(p[0] / voxel_m)), int(math.floor(p[1] / voxel_m)),
             int(math.floor(p[2] / voxel_m)))
        v = vox.get(k)
        if v is None:
            vox[k] = [p[0], p[1], p[2], 1, f, 1]
        else:
            v[0] += p[0]
            v[1] += p[1]
            v[2] += p[2]
            v[3] += 1
            if v[4] != f:
                v[4] = f
                v[5] += 1
    out = []
    for v in vox.values():
        if v[5] >= need:
            c = array("f", [v[0] / v[3], v[1] / v[3], v[2] / v[3]])
            out.append((c[0], c[1], c[2]))
    return out


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
    plane = _fit_floor_plane(points, up, a0, a1, floor)
    st.floor_plane = plane
    pa, pb, pc = plane

    def height(p):
        return (p[up] - (pa * p[a0] + pb * p[a1] + pc)) * 1000.0

    heights = [height(p) for p in points]
    leg_cells = {_cell(p, a0, a1) for p, h in zip(points, heights) if h > leg_cap_mm}
    st.leg_cells = leg_cells
    above = []
    for p, h in zip(points, heights):
        if not floor_band_mm < h <= leg_cap_mm:
            continue
        if h > LEG_SHADOW_CAP_MM and _cell(p, a0, a1) in leg_cells:
            continue
        above.append(p)
    st.above = above
    if len(above) < min_points:
        st.reject_reason = "too_few_above_floor"
        return st

    ankle = {_cell(p, a0, a1) for p, h in zip(points, heights)
             if leg_cap_mm < h <= leg_cap_mm + ANKLE_SLICE_MM}
    band, ankle_kept = _isolate_opened(above, a0, a1, seed, bridge=ankle)
    if len(band) < min_points:
        band, ankle_kept = _isolate(above, a0, a1, 0.02, seed), set()
    st.band = band
    st.ankle_cells = ankle_kept
    n = len(band)
    if n < min_points:
        st.reject_reason = "cluster_too_small"
        return st

    # Ankle cells stand in for the heel under them: each counts as an average cell's worth
    # of points at its centre (integer weight, so Swift and Python agree exactly).
    virt = [((k[0] + 0.5) * GRID_CELL_M, (k[1] + 0.5) * GRID_CELL_M) for k in sorted(ankle_kept)]
    wv = max(1, n // max(1, len({_cell(p, a0, a1) for p in band})))
    total = n + wv * len(virt)

    # PCA in the horizontal plane.
    ma = (sum(p[a0] for p in band) + wv * sum(v[0] for v in virt)) / total
    mb = (sum(p[a1] for p in band) + wv * sum(v[1] for v in virt)) / total
    saa = sab = sbb = 0.0
    for p in band:
        da = p[a0] - ma
        db = p[a1] - mb
        saa += da * da
        sab += da * db
        sbb += db * db
    for v in virt:
        da = v[0] - ma
        db = v[1] - mb
        saa += wv * da * da
        sab += wv * da * db
        sbb += wv * db * db
    saa /= total
    sab /= total
    sbb /= total
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
        proj.append((da * ux + db * uy, da * vx + db * vy, height(p)))

    real_ts = sorted(t for t, _, _ in proj)
    virt_ts = [(v[0] - ma) * ux + (v[1] - mb) * uy for v in virt]
    ts = sorted(real_ts + [t for t in virt_ts for _ in range(wv)])
    tmin = _percentile(ts, 0.005)
    tmax = _percentile(ts, 0.995)
    span = tmax - tmin or 1.0
    length_mm = span * 1000.0 + tip_correction_mm
    st.tmin, st.tmax = tmin, tmax
    # Heel end set by the ankle footprint rather than by points seen on the heel itself?
    st.heel_hidden = (_percentile(real_ts, 0.005) - tmin > 0.005
                      or tmax - _percentile(real_ts, 0.995) > 0.005)

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
