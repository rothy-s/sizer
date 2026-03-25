"""Unit tests for sizing helpers (no database)."""

from app.sizing import (
    Gender,
    WidthCode,
    approximate_us_size,
    compute_foot_sizing,
    fit_score,
    mondopoint_size,
    width_code,
)


def test_mondopoint_rounds_to_five_mm() -> None:
    assert mondopoint_size(268.0) == 270
    assert mondopoint_size(262.0) == 260


def test_compute_foot_sizing_mens() -> None:
    r = compute_foot_sizing(270.0, 100.0, Gender.mens)
    assert r.mondopoint_mm == 270
    assert r.width_code is WidthCode.standard


def test_width_code_narrow() -> None:
    wc = width_code(270.0, 90.0, Gender.mens)
    assert wc is WidthCode.narrow


def test_fit_score_prefers_matching_width() -> None:
    s1 = fit_score(270.0, 100.0, Gender.mens, 265, 275, "standard")
    s2 = fit_score(270.0, 100.0, Gender.mens, 265, 275, "wide")
    assert s1 < s2


def test_approximate_us_size_monotonic() -> None:
    a = approximate_us_size(250.0, Gender.mens)
    b = approximate_us_size(270.0, Gender.mens)
    assert b > a
