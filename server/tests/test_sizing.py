"""Unit tests for sizing helpers (no database)."""

from app.sizing import (
    ArchClass,
    Gender,
    WidthCode,
    approximate_us_size,
    arch_class,
    compute_foot_sizing,
    convert_sizes,
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


def test_width_code_mens_standard_and_wide() -> None:
    assert width_code(270.0, 100.0, Gender.mens) is WidthCode.standard  # ratio ~0.37
    assert width_code(270.0, 112.0, Gender.mens) is WidthCode.wide  # ratio > 0.39


def test_width_code_womens_narrow_standard_wide() -> None:
    assert width_code(250.0, 88.0, Gender.womens) is WidthCode.narrow  # ratio < 0.355
    assert width_code(250.0, 92.0, Gender.womens) is WidthCode.standard  # 0.355–0.395
    assert width_code(250.0, 100.0, Gender.womens) is WidthCode.wide  # ratio > 0.395


def test_width_code_nonpositive_length_is_standard() -> None:
    assert width_code(0.0, 100.0, Gender.mens) is WidthCode.standard
    assert width_code(-5.0, 80.0, Gender.womens) is WidthCode.standard


def test_fit_score_prefers_matching_width() -> None:
    s1 = fit_score(270.0, 100.0, Gender.mens, 265, 275, "standard")
    s2 = fit_score(270.0, 100.0, Gender.mens, 265, 275, "wide")
    assert s1 < s2


def test_approximate_us_size_monotonic() -> None:
    a = approximate_us_size(250.0, Gender.mens)
    b = approximate_us_size(270.0, Gender.mens)
    assert b > a


def test_approximate_us_size_table_midpoints() -> None:
    """Known rows from _MONDO_TO_US_MENS / _MONDO_TO_US_WOMENS (Mondopoint mm -> US)."""
    assert approximate_us_size(270.0, Gender.mens) == 10.0
    assert approximate_us_size(270.0, Gender.womens) == 10.5
    assert approximate_us_size(240.0, Gender.mens) == 7.0
    assert approximate_us_size(240.0, Gender.womens) == 7.5


def test_approximate_us_size_interpolates_between_table_rows() -> None:
    # Midway between 260->9 and 265->9.5 (mens)
    assert approximate_us_size(262.5, Gender.mens) == 9.25


def test_approximate_us_size_below_table_clamps_to_first_row() -> None:
    assert approximate_us_size(200.0, Gender.mens) == 4.5


def test_approximate_us_size_above_table_extrapolates_linearly() -> None:
    # Past last mens row 310->14; slope 0.5 per 5mm from 305-310
    out = approximate_us_size(320.0, Gender.mens)
    assert out == 14.0 + 0.1 * (320.0 - 310.0)


def test_arch_class_bands() -> None:
    # ratio = instep / length
    assert arch_class(55.0, 280.0) is ArchClass.low     # 0.196
    assert arch_class(70.0, 280.0) is ArchClass.medium  # 0.250
    assert arch_class(85.0, 280.0) is ArchClass.high    # 0.304


def test_arch_class_unknown_is_medium() -> None:
    assert arch_class(0.0, 280.0) is ArchClass.medium
    assert arch_class(70.0, 0.0) is ArchClass.medium


def test_convert_sizes_consistent_for_270_mens() -> None:
    s = convert_sizes(270.0, Gender.mens)
    assert s["mondo"] == 270
    assert s["us"] == 10.0
    assert s["uk"] == 9.0            # US men - 1
    assert s["cm"] == 27.0
    assert 42.0 <= s["eu"] <= 44.0   # Paris-point ~43


def test_convert_sizes_womens_uk_offset() -> None:
    s = convert_sizes(240.0, Gender.womens)
    assert s["us"] == 7.5
    assert s["uk"] == 5.5            # US women - 2


def test_compute_foot_sizing_includes_arch_and_sizes() -> None:
    r = compute_foot_sizing(270.0, 100.0, Gender.mens, instep_mm=70.0)
    assert r.arch_class is ArchClass.medium
    assert r.sizes["us"] == 10.0
    assert set(r.sizes) == {"us", "uk", "eu", "cm", "mondo"}
