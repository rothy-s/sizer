"""Replay recorded scan bundles through the reference pipeline and write a report.

    python -m scanlab.replay path/to/Scans            # every bundle under a directory
    python -m scanlab.replay Scans/scan-2026... --out reports

Prints one line per scan and writes `<out>/<scan id>.html` plus `<out>/index.html`.
"""

from __future__ import annotations

import argparse
import sys
from dataclasses import dataclass, field
from pathlib import Path

from foot_geometry_reference import (
    FLOOR_BAND_MM,
    LEG_CAP_MM,
    TIP_CORRECTION_MM,
    FootStages,
    measure_foot_stages,
)

from .bundle import ScanBundle, find_bundles, read_bundle

PARITY_TOLERANCE_MM = 0.5


@dataclass
class Replay:
    bundle: ScanBundle
    stages: FootStages
    floor_band_mm: float
    leg_cap_mm: float
    tip_correction_mm: float
    parity: str                     # "match" | "mismatch" | "n/a"
    parity_detail: str
    checks: list = field(default_factory=list)   # heuristic warnings, plain sentences


def _parity(meta: dict, stages: FootStages) -> tuple[str, str]:
    """Does the Python reference agree with what the Swift engine reported on-device?"""
    outcome = meta.get("outcome")
    app = meta.get("measurement")
    ref = stages.measurement
    if outcome not in ("measured", "rejected"):
        return "n/a", "bundle has no on-device outcome"
    if outcome == "rejected":
        if ref is None:
            return "match", "both rejected"
        return "mismatch", "app rejected the scan but the reference measures it"
    if ref is None or not app:
        return "mismatch", f"app measured the scan but the reference rejects it ({stages.reject_reason})"
    diffs = {
        "length": app["length_mm"] - ref.length_mm,
        "width": app["ball_width_mm"] - ref.ball_width_mm,
        "arch": app.get("arch_height_mm", 0.0) - ref.instep_mm,
    }
    worst = max(diffs, key=lambda k: abs(diffs[k]))
    if abs(diffs[worst]) <= PARITY_TOLERANCE_MM:
        return "match", f"within {PARITY_TOLERANCE_MM} mm"
    return "mismatch", f"{worst} differs by {diffs[worst]:+.1f} mm (app − reference)"


def _checks(bundle: ScanBundle, st: FootStages, floor_band_mm: float) -> list[str]:
    """Heuristic sanity checks. These flag things worth looking at; they are not verdicts."""
    out: list[str] = []
    meta = bundle.meta
    n = len(bundle.points)
    if st.floor is not None and n:
        near = sum(1 for p in bundle.points if abs(st.height_mm(p)) <= floor_band_mm)
        if near / n < 0.15:
            out.append(f"Only {near / n:.0%} of points lie within {floor_band_mm:.0f} mm of the "
                       "detected floor — the floor plane may be misplaced.")
    if st.above and st.band and len(st.band) / len(st.above) < 0.5:
        out.append(f"The locked-on cluster holds only {len(st.band) / len(st.above):.0%} of the "
                   "points above the floor — it may have locked onto the wrong object.")
    if st.heel_hidden:
        out.append("The heel is hidden behind the leg, so the length only covers toe to ankle "
                   "and is too short. Width is unaffected.")
    if st.length_mm and st.ball_width_mm:
        aspect = st.length_mm / st.ball_width_mm
        if not 2.1 <= aspect <= 3.1:
            out.append(f"Length ÷ width is {aspect:.2f}; feet are usually 2.1–3.1, so this "
                       "cluster is probably not a clean foot.")
    frames = meta.get("frames") or []
    if meta.get("capture_path") == "truedepth":
        missing = sum(1 for f in frames if not f.get("attitude_quat"))
        if missing:
            out.append(f"{missing} of {len(frames)} TrueDepth frames had no motion attitude, so "
                       "those points were not gravity-aligned.")
        if meta.get("seed") is None:
            out.append("TrueDepth passes no tap seed, so the engine took the largest cluster.")
    return out


def replay(bundle: ScanBundle) -> Replay:
    """Re-run the capture with the constants the app recorded, falling back to current ones."""
    algo = bundle.meta.get("algorithm") or {}
    floor_band = float(algo.get("floor_band_mm", FLOOR_BAND_MM))
    leg_cap = float(algo.get("leg_cap_mm", LEG_CAP_MM))
    tip = float(algo.get("tip_correction_mm", TIP_CORRECTION_MM))
    stages = measure_foot_stages(
        bundle.points, up=bundle.up, seed=bundle.seed,
        floor_band_mm=floor_band, leg_cap_mm=leg_cap, tip_correction_mm=tip,
    )
    parity, detail = _parity(bundle.meta, stages)
    return Replay(
        bundle=bundle, stages=stages, floor_band_mm=floor_band, leg_cap_mm=leg_cap,
        tip_correction_mm=tip, parity=parity, parity_detail=detail,
        checks=_checks(bundle, stages, floor_band),
    )


def summary_line(r: Replay) -> str:
    st = r.stages
    if st.measurement:
        result = (f"{st.measurement.length_mm:6.1f} × {st.measurement.ball_width_mm:5.1f} mm  "
                  f"arch {st.measurement.instep_mm:4.1f}  ({st.measurement.n_points} pts)")
    else:
        result = f"REJECTED: {st.reject_reason}"
    path = r.bundle.meta.get("capture_path", "?")
    return f"{r.bundle.id:34s} {path:9s} {result:52s} parity={r.parity}  checks={len(r.checks)}"


def main(argv=None) -> int:
    ap = argparse.ArgumentParser(prog="python -m scanlab.replay", description=__doc__.splitlines()[0])
    ap.add_argument("paths", nargs="+", help="scan bundle directories, or directories containing them")
    ap.add_argument("--out", default="scan-reports", help="report directory (default: ./scan-reports)")
    ap.add_argument("--no-report", action="store_true", help="only print the summary table")
    args = ap.parse_args(argv)

    bundle_dirs = find_bundles(args.paths)
    if not bundle_dirs:
        print("no scan bundles found", file=sys.stderr)
        return 1

    replays: list[Replay] = []
    failed = 0
    for d in bundle_dirs:
        try:
            replays.append(replay(read_bundle(d)))
        except (ValueError, OSError, KeyError) as exc:
            failed += 1
            print(f"skipping {d}: {exc}", file=sys.stderr)
            continue
        print(summary_line(replays[-1]))

    if replays and not args.no_report:
        from .report import write_reports
        index = write_reports(replays, Path(args.out))
        print(f"\nreport: {index}")
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
