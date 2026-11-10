"""Self-contained HTML report for replayed scans: one page per scan, stage by stage.

Dependency-free (hand-written SVG) so it runs anywhere the reference pipeline does.
Every plot is drawn to scale in millimetres; hover a plot to read coordinates.
"""

from __future__ import annotations

import base64
import html
import math
import re
from pathlib import Path

from .bundle import MESH_FRAME_INDEX

MAX_DOTS = 7000          # per plot; denser clouds are thinned evenly
N_RAMP = 5

_CSS = """
:root{--page:#f9f9f7;--surface:#fcfcfb;--ink:#0b0b0b;--ink2:#52514e;--muted:#898781;
--grid:#e1e0d9;--axis:#c3c2b7;--keep:#2a78d6;--mark:#eb6834;--drop:#c3c2b7;
--r0:#b7d3f6;--r1:#6da7ec;--r2:#2a78d6;--r3:#1c5cab;--r4:#0d366b}
@media (prefers-color-scheme:dark){:root{--page:#0d0d0d;--surface:#1a1a19;--ink:#f0efec;
--ink2:#c3c2b7;--grid:#2c2c2a;--axis:#383835;--keep:#3987e5;--mark:#d95926;--drop:#52514e;
--r0:#184f95;--r1:#256abf;--r2:#3987e5;--r3:#86b6ef;--r4:#cde2fb}}
*{box-sizing:border-box}
body{margin:0;background:var(--page);color:var(--ink);
font:14px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}
main{max-width:1120px;margin:0 auto;padding:24px 16px 64px}
h1{font-size:20px;margin:0 0 2px}h2{font-size:15px;margin:0 0 2px}
a{color:inherit}
.sub{color:var(--ink2);margin:0 0 16px}
.tiles{display:grid;grid-template-columns:repeat(auto-fit,minmax(150px,1fr));gap:12px;margin:16px 0}
.tile{background:var(--surface);border:1px solid var(--grid);border-radius:10px;padding:10px 12px}
.tile .k{color:var(--ink2);font-size:12px}.tile .v{font-size:18px;font-weight:600}
.tile .n{color:var(--ink2);font-size:12px}
.card{background:var(--surface);border:1px solid var(--grid);border-radius:10px;padding:14px;margin:0 0 16px}
.grid2{display:grid;grid-template-columns:repeat(auto-fit,minmax(min(100%,420px),1fr));gap:16px}
.grid2 .card{margin:0}
.grid2 .card.wide{grid-column:1/-1}
.why{color:var(--ink2);margin:0 0 8px;font-size:13px}
.legend{display:flex;flex-wrap:wrap;gap:4px 14px;color:var(--ink2);font-size:12px;margin:0 0 6px}
.legend i{display:inline-block;width:10px;height:10px;border-radius:50%;margin-right:5px;vertical-align:-1px}
svg.plot{display:block;width:100%;height:auto;max-width:100%}
.pts{fill:none;stroke-linecap:round;stroke-width:1.9}
.r0{stroke:var(--r0)}.r1{stroke:var(--r1)}.r2{stroke:var(--r2)}.r3{stroke:var(--r3)}.r4{stroke:var(--r4)}
.keep{stroke:var(--keep)}.drop{stroke:var(--drop)}
.bar.keep{fill:var(--keep);stroke:none}.bar.drop{fill:var(--drop);stroke:none}
.ann{stroke:var(--ink2);stroke-width:1;stroke-dasharray:4 3;fill:none}
.mark{stroke:var(--mark);stroke-width:2;fill:none}
.frame{fill:none;stroke:var(--grid)}
.lbl{fill:var(--ink2);font-size:11px;paint-order:stroke;stroke:var(--surface);stroke-width:3px}
.lbl.strong{fill:var(--ink);font-weight:600}
table{border-collapse:collapse;width:100%}
th,td{text-align:left;padding:6px 10px;border-bottom:1px solid var(--grid);font-variant-numeric:tabular-nums}
th{color:var(--ink2);font-weight:500;font-size:12px}
td.num,th.num{text-align:right}
.checks{margin:0;padding-left:18px}.checks li{margin:2px 0}
.photo{max-width:100%;max-height:360px;border-radius:8px;display:block}
.tablewrap{overflow-x:auto}
#tip{position:fixed;pointer-events:none;background:var(--ink);color:var(--surface);padding:3px 7px;
border-radius:5px;font-size:12px;display:none;z-index:9;white-space:nowrap}
"""

_JS = """
const tip=document.getElementById('tip');
document.querySelectorAll('svg.plot').forEach(s=>{
  s.addEventListener('mousemove',e=>{
    const r=s.getBoundingClientRect(),vb=s.viewBox.baseVal,d=s.dataset;
    const px=(e.clientX-r.left)*vb.width/r.width,py=(e.clientY-r.top)*vb.height/r.height;
    const x=+d.x0+px/+d.sx,y=+d.y0+py/+d.sy;
    tip.textContent=d.xl+' '+x.toFixed(0)+' '+d.xu+' · '+d.yl+' '+y.toFixed(0)+' '+d.yu;
    tip.style.display='block';
    tip.style.left=Math.min(e.clientX+12,innerWidth-tip.offsetWidth-8)+'px';
    tip.style.top=(e.clientY+14)+'px';
  });
  s.addEventListener('mouseleave',()=>tip.style.display='none');
});
"""


def _esc(v) -> str:
    return html.escape(str(v), quote=True)


def _slug(scan_id) -> str:
    """Scan ids come from files; keep report filenames inside the output directory."""
    return re.sub(r"[^A-Za-z0-9._-]", "_", str(scan_id)).lstrip(".") or "scan"


def _thin(seq, cap=MAX_DOTS):
    step = max(1, math.ceil(len(seq) / cap))
    return seq[::step]


class Plot:
    """A to-scale SVG scatter plot. Data units map linearly to pixels on both axes."""

    def __init__(self, x_range, y_range, *, sx, sy=None, flip_y=False,
                 x_label="x", y_label="y", x_unit="mm", y_unit="mm", pad=14):
        self.x0, x1 = x_range
        y0, y1 = y_range
        self.sx = sx
        self.sy = sx if sy is None else sy
        self.pad = pad
        self.flip = flip_y
        self.y_lo, self.y_hi = y0, y1
        self.w = (x1 - self.x0) * self.sx + 2 * pad
        self.h = (y1 - y0) * self.sy + 2 * pad
        self.labels = (x_label, y_label, x_unit, y_unit)
        self.body: list[str] = []

    def X(self, x):
        return self.pad + (x - self.x0) * self.sx

    def Y(self, y):
        if self.flip:
            return self.pad + (self.y_hi - y) * self.sy
        return self.pad + (y - self.y_lo) * self.sy

    def dots(self, pts, cls):
        if not pts:
            return
        d = "".join(f"M{self.X(x):.1f} {self.Y(y):.1f}h.01" for x, y in _thin(pts))
        self.body.append(f'<path class="pts {cls}" d="{d}"/>')

    def hline(self, y, label, strong=False):
        yy = self.Y(y)
        self.body.append(f'<line class="ann" x1="{self.pad}" x2="{self.w - self.pad:.1f}" y1="{yy:.1f}" y2="{yy:.1f}"/>')
        self.text(self.x0, y, label, dx=4, dy=-4, strong=strong)

    def vline(self, x, label, strong=False):
        xx = self.X(x)
        self.body.append(f'<line class="ann" x1="{xx:.1f}" x2="{xx:.1f}" y1="{self.pad}" y2="{self.h - self.pad:.1f}"/>')
        self.body.append(f'<text class="lbl{" strong" if strong else ""}" x="{xx + 4:.1f}" y="{self.pad + 11}">{_esc(label)}</text>')

    def segment(self, xa, ya, xb, yb, cls="ann"):
        self.body.append(f'<line class="{cls}" x1="{self.X(xa):.1f}" y1="{self.Y(ya):.1f}" '
                         f'x2="{self.X(xb):.1f}" y2="{self.Y(yb):.1f}"/>')

    def text(self, x, y, label, dx=0, dy=0, strong=False, anchor="start"):
        self.body.append(f'<text class="lbl{" strong" if strong else ""}" text-anchor="{anchor}" '
                         f'x="{self.X(x) + dx:.1f}" y="{self.Y(y) + dy:.1f}">{_esc(label)}</text>')

    def cross(self, x, y, label):
        cx, cy, r = self.X(x), self.Y(y), 7
        self.body.append(f'<path class="mark" d="M{cx - r:.1f} {cy:.1f}h{2 * r}M{cx:.1f} {cy - r:.1f}v{2 * r}"/>')
        self.body.append(f'<text class="lbl strong" x="{cx + 10:.1f}" y="{cy - 8:.1f}">{_esc(label)}</text>')

    def ring(self, x, y, radius, label):
        self.body.append(f'<circle class="ann" cx="{self.X(x):.1f}" cy="{self.Y(y):.1f}" r="{radius * self.sx:.1f}"/>')
        self.text(x, y, label, dx=-radius * self.sx * 0.7, dy=-radius * self.sy * 0.72)

    def scale_bar(self, length=50):
        x1 = self.w - self.pad - 6
        x0 = x1 - length * self.sx
        y = self.h - self.pad - 6
        self.body.append(f'<path class="mark" style="stroke:var(--ink)" d="M{x0:.1f} {y:.1f}H{x1:.1f}'
                         f'M{x0:.1f} {y - 4:.1f}v8M{x1:.1f} {y - 4:.1f}v8"/>')
        self.body.append(f'<text class="lbl strong" text-anchor="end" x="{x1:.1f}" y="{y - 7:.1f}">{length} mm</text>')

    def bar(self, x, width, y, cls, title):
        top, base = self.Y(y), self.Y(0)
        h = max(0.0, base - top)
        w = max(1.0, width * self.sx - 2)
        self.body.append(f'<rect class="bar {cls}" x="{self.X(x) + 1:.1f}" y="{top:.1f}" width="{w:.1f}" '
                         f'height="{h:.1f}" rx="{min(2, w / 2):.1f}"><title>{_esc(title)}</title></rect>')

    def svg(self, aria) -> str:
        xl, yl, xu, yu = self.labels
        # Data value at pixel 0 and px-per-unit, for the hover readout.
        x_at0 = self.x0 - self.pad / self.sx
        if self.flip:
            y_at0, sy = self.y_hi + self.pad / self.sy, -self.sy
        else:
            y_at0, sy = self.y_lo - self.pad / self.sy, self.sy
        return (f'<svg class="plot" role="img" aria-label="{_esc(aria)}" viewBox="0 0 {self.w:.0f} {self.h:.0f}" '
                f'style="max-width:{self.w:.0f}px" data-x0="{x_at0:.3f}" data-y0="{y_at0:.3f}" '
                f'data-sx="{self.sx}" data-sy="{sy}" data-xl="{_esc(xl)}" data-yl="{_esc(yl)}" '
                f'data-xu="{_esc(xu)}" data-yu="{_esc(yu)}">'
                f'<rect class="frame" x=".5" y=".5" width="{self.w - 1:.0f}" height="{self.h - 1:.0f}" rx="6"/>'
                + "".join(self.body) + "</svg>")


def _legend(items) -> str:
    return '<div class="legend">' + "".join(
        f'<span><i style="background:var(--{var})"></i>{_esc(label)}</span>' for var, label in items
    ) + "</div>"


def _card(title, why, legend, svg, wide=False) -> str:
    return f'<div class="card{" wide" if wide else ""}"><h2>{_esc(title)}</h2><p class="why">{_esc(why)}</p>{legend}{svg}</div>'


def _bounds(vals, margin):
    lo, hi = min(vals), max(vals)
    if hi - lo < 1:
        hi = lo + 1
    return lo - margin, hi + margin


def _fmt(v, digits=1):
    return "—" if v is None else f"{v:.{digits}f}"


def _scan_panels(r) -> str:
    """The stage-by-stage plots for one replay."""
    b, st = r.bundle, r.stages
    if not b.points:
        return '<div class="card"><h2>No points</h2><p class="why">This bundle recorded an empty cloud.</p></div>'
    up, a0, a1 = st.up, st.a0, st.a1
    seed = b.seed
    # Plot origin: the tap when known, else the cloud centre. Everything below is in mm.
    if seed:
        ox, oy = seed
    else:
        ox = sum(p[a0] for p in b.points) / len(b.points)
        oy = sum(p[a1] for p in b.points) / len(b.points)
    floor = st.floor if st.floor is not None else min(p[up] for p in b.points)
    # True top-down view: ARKit (Y up) looks down with +Z toward the viewer; a Z-up frame needs +Y up.
    flip_top = up != 1

    def top(p):
        return ((p[a0] - ox) * 1000.0, (p[a1] - oy) * 1000.0)

    def height(p):
        if st.floor_plane is not None:
            return st.height_mm(p)
        return (p[up] - floor) * 1000.0

    all_top = [top(p) for p in b.points]
    xr = _bounds([x for x, _ in all_top], 12)
    yr = _bounds([y for _, y in all_top], 12)
    span = max(xr[1] - xr[0], yr[1] - yr[0])
    s_top = min(1.6, 470.0 / span)
    cards = []

    # 1 — raw cloud, top-down, coloured by height above the detected floor.
    edges = [r.floor_band_mm, 35.0, 65.0, r.leg_cap_mm]
    buckets = [[] for _ in range(N_RAMP)]
    for p, xy in zip(b.points, all_top):
        h = height(p)
        buckets[sum(1 for e in edges if h > e)].append(xy)
    pl = Plot(xr, yr, sx=s_top, flip_y=flip_top, x_label="across", y_label="along")
    for i, pts in enumerate(buckets):
        pl.dots(pts, f"r{i}")
    if b.meta.get("tap_center") and seed:
        pl.ring(0, 0, float(b.meta.get("crop_radius_m", 0.22)) * 1000.0, "crop sphere")
    if seed:
        pl.cross(0, 0, "tap")
    pl.scale_bar()
    lg = _legend([
        ("r0", f"≤ {edges[0]:.0f} mm (floor)"), ("r1", f"{edges[0]:.0f}–{edges[1]:.0f}"),
        ("r2", f"{edges[1]:.0f}–{edges[2]:.0f}"), ("r3", f"{edges[2]:.0f}–{edges[3]:.0f}"),
        ("r4", f"> {edges[3]:.0f} mm (leg)"),
    ])
    cards.append(_card("1 · Raw cloud, top-down",
                       f"All {len(b.points):,} fused points the engine received, coloured by height above the detected floor.",
                       lg, pl.svg("Raw point cloud seen from above")))

    # 2 — side view: which heights survive the floor/leg cut.
    if st.axis and st.centroid:
        ux, uy = st.axis
        cx, cy = st.centroid

        def along(p):
            return ((p[a0] - cx) * ux + (p[a1] - cy) * uy) * 1000.0
        side_label = "along foot"
    else:
        def along(p):
            return (p[a0] - ox) * 1000.0
        side_label = "across"
    side = [(along(p), height(p)) for p in b.points]
    kept = [xy for xy in side if r.floor_band_mm < xy[1] <= r.leg_cap_mm]
    dropped = [xy for xy in side if not (r.floor_band_mm < xy[1] <= r.leg_cap_mm)]
    sxr = _bounds([x for x, _ in side], 12)
    syr = _bounds([y for _, y in side], 14)
    s_side = min(1.6, 470.0 / max(sxr[1] - sxr[0], 1))
    pl = Plot(sxr, syr, sx=s_side, flip_y=True, x_label=side_label, y_label="height")
    pl.dots(dropped, "drop")
    pl.dots(kept, "keep")
    pl.hline(0, "floor", strong=True)
    pl.hline(r.floor_band_mm, f"floor + {r.floor_band_mm:.0f} mm")
    if syr[1] > r.leg_cap_mm:
        pl.hline(r.leg_cap_mm, f"leg cap {r.leg_cap_mm:.0f} mm")
    pl.scale_bar()
    cards.append(_card("2 · Side view: floor and leg cut",
                       f"Only points between the two cut lines are kept ({len(kept):,} of {len(side):,}).",
                       _legend([("keep", "kept"), ("drop", "dropped (floor or leg)")]),
                       pl.svg("Side view of the cloud with the floor and leg cut lines")))

    # 3 — height histogram: is the floor peak where the floor is?
    hs = [height(p) for p in b.points]
    bin_mm = 5.0
    lo = math.floor(min(hs) / bin_mm) * bin_mm
    nb = max(1, int(math.ceil((max(hs) - lo) / bin_mm)))
    counts = [0] * nb
    for h in hs:
        counts[min(nb - 1, int((h - lo) / bin_mm))] += 1
    peak = max(counts) or 1
    pl = Plot((lo, lo + nb * bin_mm), (0, peak * 1.12), sx=min(6.0, 470.0 / (nb * bin_mm)),
              sy=150.0 / (peak * 1.12), flip_y=True, x_label="height", y_label="points", y_unit="")
    for i, c in enumerate(counts):
        h0 = lo + i * bin_mm
        mid = h0 + bin_mm / 2
        cls = "keep" if r.floor_band_mm < mid <= r.leg_cap_mm else "drop"
        pl.bar(h0, bin_mm, c, cls, f"{h0:.0f} to {h0 + bin_mm:.0f} mm above floor: {c:,} points")
    pl.vline(0, "floor", strong=True)
    cards.append(_card("3 · Height histogram",
                       "The floor starts at the tallest bar in the lower 60% of heights and is then fitted as a tilted plane. A weak or split peak means a bad floor estimate.",
                       _legend([("keep", "heights kept"), ("drop", "heights dropped")]),
                       pl.svg("Histogram of point heights above the detected floor")))

    # 4 — after the cut: which connected cluster was chosen.
    if st.above:
        in_band = {id(p) for p in st.band}
        chosen = [top(p) for p in st.above if id(p) in in_band]
        other = [top(p) for p in st.above if id(p) not in in_band]
        pl = Plot(xr, yr, sx=s_top, flip_y=flip_top, x_label="across", y_label="along")
        pl.dots(other, "drop")
        pl.dots(chosen, "keep")
        if seed:
            pl.cross(0, 0, "tap")
        pl.scale_bar()
        cards.append(_card("4 · Lock-on: chosen cluster",
                           f"Points left after the cut, grouped by touching 20 mm cells. The engine kept {len(chosen):,} and discarded {len(other):,}.",
                           _legend([("keep", "locked-on cluster"), ("drop", "other clusters")]),
                           pl.svg("Top-down view of the cluster the engine locked onto")))

    # 5 — the cluster in its own heel-to-toe frame, with the measured extents.
    if st.axis and st.centroid and st.tmin is not None:
        ux, uy = st.axis
        cx, cy = st.centroid
        tw = []
        for p in st.band:
            da, db = p[a0] - cx, p[a1] - cy
            tw.append(((da * ux + db * uy) * 1000.0, (-da * uy + db * ux) * 1000.0, height(p)))
        txr = _bounds([t for t, _, _ in tw], 16)
        twr = _bounds([w for _, w, _ in tw], 26)
        pl = Plot(txr, twr, sx=min(2.2, 1000.0 / (txr[1] - txr[0])), x_label="along foot", y_label="across foot")
        h_edges = [30.0, 50.0, 70.0]
        hb = [[] for _ in range(4)]
        for t, w, h in tw:
            hb[sum(1 for e in h_edges if h > e)].append((t, w))
        for i, pts in enumerate(hb):
            pl.dots(pts, f"r{i + 1}")
        tmin, tmax = st.tmin * 1000.0, st.tmax * 1000.0
        pl.vline(tmin, "")
        pl.vline(tmax, "")
        y_txt = twr[1] - 6
        pl.text((tmin + tmax) / 2, y_txt,
                f"extent {tmax - tmin:.0f} mm + {r.tip_correction_mm:.0f} mm tip correction = {_fmt(st.length_mm, 0)} mm",
                anchor="middle", strong=True)
        pl.scale_bar()
        lg = _legend([("r1", "≤ 30 mm high"), ("r2", "30–50"), ("r3", "50–70"), ("r4", "> 70 mm")])
        cards.append(_card("5 · Locked-on foot, heel-to-toe aligned",
                           f"This is the shape that gets measured: length {_fmt(st.length_mm, 0)} mm, ball width {_fmt(st.ball_width_mm, 0)} mm. It should look like a footprint.",
                           lg, pl.svg("The isolated cluster rotated so its long axis is horizontal"), wide=True))

    # 6 — fusion: do successive frames land on top of each other?
    fi = b.frame_index
    fusion_top = all_top if b.raw_points is None else [top(p) for p in b.raw_points]
    if len(fusion_top) > 20000:      # raw sweeps hold hundreds of thousands of samples
        step = len(fusion_top) // 20000 + 1
        fusion_top, fi = fusion_top[::step], fi[::step]
    depth_frames = sorted({f for f in fi if f != MESH_FRAME_INDEX})
    if fi and len(depth_frames) > 1:
        groups = [[] for _ in range(N_RAMP)]
        mesh = []
        rank = {f: i for i, f in enumerate(depth_frames)}
        for f, xy in zip(fi, fusion_top):
            if f == MESH_FRAME_INDEX:
                mesh.append(xy)
            else:
                groups[min(N_RAMP - 1, rank[f] * N_RAMP // len(depth_frames))].append(xy)
        pl = Plot(xr, yr, sx=s_top, flip_y=flip_top, x_label="across", y_label="along")
        pl.dots(mesh, "drop")
        for i, pts in enumerate(groups):
            pl.dots(pts, f"r{i}")
        pl.scale_bar()
        items = [("r0", "first frames"), ("r2", "middle"), ("r4", "last frames")]
        if mesh:
            items.append(("drop", "scene-mesh vertices"))
        cards.append(_card("6 · Frame fusion",
                           f"New points contributed by each of {len(depth_frames)} fused frames. Later frames forming a shifted copy of the shape means the phone moved during capture.",
                           _legend(items), pl.svg("Top-down view coloured by the frame each point came from")))

    return '<div class="grid2">' + "".join(cards) + "</div>"


def _page(title, body) -> str:
    return (f'<!doctype html><html lang="en"><head><meta charset="utf-8">'
            f'<meta name="viewport" content="width=device-width,initial-scale=1">'
            f'<title>{_esc(title)}</title><style>{_CSS}</style></head><body><main>{body}</main>'
            f'<div id="tip"></div><script>{_JS}</script></body></html>')


def _tile(k, v, note="") -> str:
    return (f'<div class="tile"><div class="k">{_esc(k)}</div><div class="v">{_esc(v)}</div>'
            f'<div class="n">{_esc(note)}</div></div>')


def scan_html(r) -> str:
    b, st, meta = r.bundle, r.stages, r.bundle.meta
    app = meta.get("measurement") or {}
    truth = meta.get("ground_truth") or {}
    ref = st.measurement

    app_outcome = meta.get("outcome", "—")
    if app_outcome == "rejected" and meta.get("reject_reason"):
        app_outcome += f" ({meta['reject_reason']})"
    replay_outcome = "measured" if ref else f"rejected ({st.reject_reason})"
    parity_label = {"match": "✓ match", "mismatch": "✗ mismatch", "n/a": "n/a"}[r.parity]

    tiles = "".join([
        _tile("On-device result", app_outcome, meta.get("capture_path", "")),
        _tile("Replay result", replay_outcome, "Python reference"),
        _tile("Swift vs Python", parity_label, r.parity_detail),
        _tile("Points", f"{len(b.points):,}", f"{meta.get('frames_fused', '—')} frames fused"),
        _tile("Locked-on cluster", f"{len(st.band):,}" if st.band else "—", "points measured"),
    ])

    def row(label, a, p, t):
        return (f"<tr><td>{label}</td><td class='num'>{_fmt(a)}</td><td class='num'>{_fmt(p)}</td>"
                f"<td class='num'>{_fmt(t)}</td></tr>")
    table = ('<div class="card"><h2>Measurements (mm)</h2><div class="tablewrap"><table><tr><th></th>'
             '<th class="num">On device</th><th class="num">Replay</th><th class="num">Ground truth</th></tr>'
             + row("Length", app.get("length_mm"), st.length_mm, truth.get("length_mm"))
             + row("Ball width", app.get("ball_width_mm"), st.ball_width_mm, truth.get("ball_width_mm"))
             + row("Arch / instep height", app.get("arch_height_mm"), st.instep_mm, None)
             + "</table></div></div>")

    if r.checks:
        checks = ('<div class="card"><h2>⚠ Worth a look</h2><p class="why">Heuristic flags, not verdicts.</p>'
                  '<ul class="checks">' + "".join(f"<li>{_esc(c)}</li>" for c in r.checks) + "</ul></div>")
    else:
        checks = ""

    photo = ""
    if b.photo_path:
        data = base64.b64encode(b.photo_path.read_bytes()).decode("ascii")
        photo = ('<div class="card"><h2>What the camera saw</h2>'
                 f'<img class="photo" alt="Camera photo taken at capture" src="data:image/jpeg;base64,{data}"></div>')

    sub = " · ".join(str(x) for x in [
        meta.get("created_at"), meta.get("device_model"), meta.get("os_version"),
        f"app {meta.get('app_version')}" if meta.get("app_version") else None,
        f"{meta['side']} foot" if meta.get("side") else None,
    ] if x)
    body = (f'<p class="sub"><a href="index.html">← all scans</a></p><h1>{_esc(b.id)}</h1>'
            f'<p class="sub">{_esc(sub)}</p><div class="tiles">{tiles}</div>'
            f'{checks}{table}{photo}{_scan_panels(r)}')
    return _page(b.id, body)


def index_html(replays) -> str:
    rows = []
    for r in replays:
        st, meta = r.stages, r.bundle.meta
        truth = meta.get("ground_truth") or {}
        result = "measured" if st.measurement else f"rejected ({st.reject_reason})"
        rows.append(
            f'<tr><td><a href="{_esc(_slug(r.bundle.id))}.html">{_esc(r.bundle.id)}</a></td>'
            f'<td>{_esc(meta.get("capture_path", "—"))}</td><td>{_esc(meta.get("side") or "—")}</td>'
            f'<td>{_esc(result)}</td><td class="num">{_fmt(st.length_mm)}</td>'
            f'<td class="num">{_fmt(st.ball_width_mm)}</td><td class="num">{_fmt(truth.get("length_mm"))}</td>'
            f'<td class="num">{_fmt(truth.get("ball_width_mm"))}</td>'
            f'<td>{_esc({"match": "✓", "mismatch": "✗ mismatch", "n/a": "n/a"}[r.parity])}</td>'
            f'<td class="num">{len(r.checks)}</td></tr>')
    measured = sum(1 for r in replays if r.stages.measurement)
    mismatched = sum(1 for r in replays if r.parity == "mismatch")
    tiles = "".join([
        _tile("Scans", len(replays)),
        _tile("Locked on", f"{measured} of {len(replays)}", "replay produced a measurement"),
        _tile("Swift vs Python mismatches", mismatched, "should be 0"),
        _tile("Flagged", sum(1 for r in replays if r.checks), "scans with heuristic flags"),
    ])
    body = (f'<h1>Scan replay</h1><p class="sub">Each recorded capture re-run through the Python reference pipeline.</p>'
            f'<div class="tiles">{tiles}</div><div class="card"><div class="tablewrap"><table><tr><th>Scan</th>'
            f'<th>Scanner</th><th>Foot</th><th>Replay</th><th class="num">Length mm</th><th class="num">Width mm</th>'
            f'<th class="num">True length</th><th class="num">True width</th><th>Swift = Python</th>'
            f'<th class="num">Flags</th></tr>{"".join(rows)}</table></div></div>')
    return _page("Scan replay", body)


def write_reports(replays, out_dir: Path) -> Path:
    out_dir.mkdir(parents=True, exist_ok=True)
    for r in replays:
        (out_dir / f"{_slug(r.bundle.id)}.html").write_text(scan_html(r), encoding="utf-8")
    index = out_dir / "index.html"
    index.write_text(index_html(replays), encoding="utf-8")
    return index
