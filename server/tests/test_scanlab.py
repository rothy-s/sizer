"""Scan bundles (written by the iOS `ScanRecorder`) and their offline replay.

The byte-layout test uses the same literal bytes as `ScanRecorderTests` in the iOS
unit tests: together they pin the Swift writer and this Python reader to one format.
"""

from __future__ import annotations

import json

import pytest

from foot_geometry_reference import measure_foot, measure_foot_stages
from scanlab.bundle import MESH_FRAME_INDEX, find_bundles, read_bundle, write_bundle
from scanlab.replay import main, replay
from scanlab.report import write_reports
from test_mesh_foot_measurement import make_foot


def _meta(scan_id="scan-test", **over):
    meta = {
        "id": scan_id,
        "created_at": "2026-11-09T00:00:00Z",
        "capture_path": "lidar",
        "vertical_axis": 1,
        "seed": [0.0, 0.0],
        "tap_center": [0.0, 0.03, 0.0],
        "crop_radius_m": 0.22,
        "frames_fused": 2,
        "frames": [{"index": 0, "point_count": 1}, {"index": 1, "point_count": 1}],
        "algorithm": {"version": "1", "floor_band_mm": 10.0, "leg_cap_mm": 95.0, "tip_correction_mm": 26.0},
        "outcome": "measured",
    }
    meta.update(over)
    return meta


def _foot_bundle(tmp_path, scan_id="scan-foot", **over):
    pts = make_foot(270, 100, 64, 30)
    m = measure_foot(pts, up=1, seed=(0.0, 0.0))
    assert m is not None
    over.setdefault("measurement", {
        "length_mm": m.length_mm, "ball_width_mm": m.ball_width_mm, "arch_height_mm": m.instep_mm,
    })
    frame_index = bytes(i % 3 if i % 50 else MESH_FRAME_INDEX for i in range(len(pts)))
    return write_bundle(tmp_path, _meta(scan_id, **over), pts, frame_index=frame_index)


def test_reads_the_byte_layout_the_swift_recorder_writes(tmp_path):
    d = tmp_path / "scan-bytes"
    d.mkdir()
    (d / "points.f32").write_bytes(bytes([
        0x00, 0x00, 0x80, 0x3F, 0x00, 0x00, 0x00, 0x40, 0x00, 0x00, 0x40, 0x40,   # 1, 2, 3
        0x00, 0x00, 0x00, 0xBF, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x80, 0x3E,   # -0.5, 0, 0.25
    ]))
    (d / "frame_index.u8").write_bytes(bytes([0, 255]))
    (d / "meta.json").write_text(json.dumps({
        "schema_version": 1, "id": "scan-bytes", "vertical_axis": 2, "point_count": 2,
    }))
    b = read_bundle(d)
    assert b.points == [(1.0, 2.0, 3.0), (-0.5, 0.0, 0.25)]
    assert list(b.frame_index) == [0, MESH_FRAME_INDEX]
    assert b.up == 2 and b.seed is None and b.photo_path is None


def test_write_then_read_round_trips(tmp_path):
    pts = [(0.125, -0.5, 2.0), (1.5, 0.25, -3.0)]
    d = write_bundle(tmp_path, _meta(), pts, frame_index=b"\x00\x01", photo=b"jpeg")
    b = read_bundle(d)
    assert b.points == pts
    assert b.meta["point_count"] == 2 and b.meta["has_photo"] is True
    assert b.photo_path is not None and b.seed == (0.0, 0.0)


def test_rejects_unknown_schema_and_corrupt_points(tmp_path):
    d = write_bundle(tmp_path, _meta("scan-future", schema_version=99), [(0, 0, 0)])
    with pytest.raises(ValueError, match="schema_version"):
        read_bundle(d)
    d = write_bundle(tmp_path, _meta("scan-short"), [(0, 0, 0)])
    (d / "points.f32").write_bytes(b"\x00" * 7)
    with pytest.raises(ValueError, match="multiple of 12"):
        read_bundle(d)


def test_find_bundles_skips_incomplete_directories(tmp_path):
    write_bundle(tmp_path, _meta("scan-b"), [(0, 0, 0)])
    write_bundle(tmp_path, _meta("scan-a"), [(0, 0, 0)])
    (tmp_path / "scan-partial").mkdir()
    assert [p.name for p in find_bundles([tmp_path])] == ["scan-a", "scan-b"]
    assert [p.name for p in find_bundles([tmp_path / "scan-b"])] == ["scan-b"]
    with pytest.raises(FileNotFoundError):
        find_bundles([tmp_path / "nope"])


def test_stages_agree_with_measure_foot():
    pts = make_foot(280, 100, 68, 45)
    st = measure_foot_stages(pts, up=1)
    assert st.measurement == measure_foot(pts, up=1)
    assert st.reject_reason is None
    assert 0 < len(st.band) <= len(st.above) < len(pts)
    assert measure_foot_stages(pts[:10], up=1).reject_reason == "too_few_points"


def test_replay_matches_the_recorded_on_device_result(tmp_path):
    r = replay(read_bundle(_foot_bundle(tmp_path)))
    assert r.stages.measurement is not None
    assert r.parity == "match", r.parity_detail
    assert r.checks == []


def test_replay_flags_swift_python_disagreement(tmp_path):
    off = replay(read_bundle(_foot_bundle(
        tmp_path, "scan-off",
        measurement={"length_mm": 250.0, "ball_width_mm": 100.0, "arch_height_mm": 60.0})))
    assert off.parity == "mismatch" and "length" in off.parity_detail
    rejected = replay(read_bundle(_foot_bundle(
        tmp_path, "scan-rej", outcome="rejected", reject_reason="no_lock_on", measurement=None)))
    assert rejected.parity == "mismatch"


def test_replay_uses_the_constants_recorded_with_the_scan(tmp_path):
    base = replay(read_bundle(_foot_bundle(tmp_path, "scan-base")))
    algo = {"version": "1", "floor_band_mm": 10.0, "leg_cap_mm": 95.0, "tip_correction_mm": 0.0}
    no_tip = replay(read_bundle(_foot_bundle(tmp_path, "scan-notip", algorithm=algo)))
    assert base.stages.length_mm - no_tip.stages.length_mm == pytest.approx(26.0)


def test_report_and_cli(tmp_path, capsys):
    scans = tmp_path / "Scans"
    _foot_bundle(scans, "scan-good")
    write_bundle(scans, _meta("scan-<empty>", outcome="rejected", reject_reason="too_few_points"), [])
    out = tmp_path / "reports"

    assert main([str(scans), "--out", str(out)]) == 0
    printed = capsys.readouterr().out
    assert "scan-good" in printed and "REJECTED: too_few_points" in printed

    index = (out / "index.html").read_text()
    assert "scan-good.html" in index
    good = (out / "scan-good.html").read_text()
    assert good.count("<svg") == 6 and "Frame fusion" in good
    # Ids come from files: they must be escaped and must not escape the output directory.
    assert "scan-<empty>" not in index and (out / "scan-_empty_.html").exists()

    replays = [replay(read_bundle(d)) for d in find_bundles([scans])]
    assert write_reports(replays, tmp_path / "again").name == "index.html"
