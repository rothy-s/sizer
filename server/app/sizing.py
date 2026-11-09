"""
Industry-standard foot measurements used in footwear:

- **Mondopoint (ISO 9407)**: Foot length in millimeters is the primary Mondopoint value.
  Shoe size is often expressed as length in mm with 5 mm steps for manufacturing.

- **Ball girth / width**: Ball width (widest part of forefoot) is commonly used with
  length to assign width letters (US: AA–EEEE). We classify width relative to length
  using proportional bands similar to Brannock-style narrow/standard/wide.

This module converts measured mm into Mondopoint labels, US approximate sizes,
and width codes for matching against lasts.
"""

from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Literal


class Gender(str, Enum):
    mens = "mens"
    womens = "womens"


class WidthCode(str, Enum):
    """US-style width relative to length (simplified bands)."""

    narrow = "narrow"  # 2A / A range
    standard = "standard"  # B–D range depending on gender
    wide = "wide"  # E / EE+ range


# Mondopoint (mm) midpoint -> US size (common retail mapping; approximate)
# ISO 19407 provides official tables; this is a representative subset for app matching.
_MONDO_TO_US_MENS: list[tuple[int, float]] = [
    (215, 4.5),
    (220, 5),
    (225, 5.5),
    (230, 6),
    (235, 6.5),
    (240, 7),
    (245, 7.5),
    (250, 8),
    (255, 8.5),
    (260, 9),
    (265, 9.5),
    (270, 10),
    (275, 10.5),
    (280, 11),
    (285, 11.5),
    (290, 12),
    (295, 12.5),
    (300, 13),
    (305, 13.5),
    (310, 14),
]

_MONDO_TO_US_WOMENS: list[tuple[int, float]] = [
    (215, 5),
    (220, 5.5),
    (225, 6),
    (230, 6.5),
    (235, 7),
    (240, 7.5),
    (245, 8),
    (250, 8.5),
    (255, 9),
    (260, 9.5),
    (265, 10),
    (270, 10.5),
    (275, 11),
    (280, 11.5),
    (285, 12),
]


def mondopoint_size(foot_length_mm: float) -> int:
    """Mondopoint label as integer mm (round to nearest 5 mm for display)."""
    return int(round(foot_length_mm / 5.0) * 5)


def approximate_us_size(foot_length_mm: float, gender: Gender) -> float:
    table = _MONDO_TO_US_MENS if gender is Gender.mens else _MONDO_TO_US_WOMENS
    if foot_length_mm <= table[0][0]:
        return table[0][1]
    if foot_length_mm >= table[-1][0]:
        slope = (table[-1][1] - table[-2][1]) / (table[-1][0] - table[-2][0])
        return table[-1][1] + slope * (foot_length_mm - table[-1][0])
    for i in range(len(table) - 1):
        a0, s0 = table[i]
        a1, s1 = table[i + 1]
        if a0 <= foot_length_mm <= a1:
            t = (foot_length_mm - a0) / (a1 - a0)
            return s0 + t * (s1 - s0)
    return table[-1][1]


def width_code(foot_length_mm: float, ball_width_mm: float, gender: Gender) -> WidthCode:
    """
    Heuristic width band: ratio of ball width to length vs typical medium last.
    Medium reference ~0.36–0.39 for adults; narrow lower, wide higher.
    """
    if foot_length_mm <= 0:
        return WidthCode.standard
    ratio = ball_width_mm / foot_length_mm
    # Slightly different proportions by gender for typical lasts
    if gender is Gender.womens:
        if ratio < 0.355:
            return WidthCode.narrow
        if ratio > 0.395:
            return WidthCode.wide
        return WidthCode.standard
    if ratio < 0.350:
        return WidthCode.narrow
    if ratio > 0.390:
        return WidthCode.wide
    return WidthCode.standard


# --- Arch height (dorsal instep proxy) ---------------------------------------


class ArchClass(str, Enum):
    low = "low"
    medium = "medium"
    high = "high"


def arch_class(instep_mm: float, foot_length_mm: float) -> ArchClass:
    """Dorsal instep height relative to foot length -> low / medium / high.
    Mirrors the iOS `SizeConversion.archClass`. Typical ratios cluster ~0.22-0.28."""
    if foot_length_mm <= 0 or instep_mm <= 0:
        return ArchClass.medium
    r = instep_mm / foot_length_mm
    if r < 0.225:
        return ArchClass.low
    if r > 0.275:
        return ArchClass.high
    return ArchClass.medium


# --- Multi-country size conversion (mirrors iOS SizeConversion) ---------------

LAST_ALLOWANCE_MM = 16.9  # 2/3 inch last allowance (Barleycorn)


def convert_sizes(foot_length_mm: float, gender: Gender) -> dict[str, float | int]:
    """Approximate US/UK/EU/CM plus Mondopoint from foot length. US anchors on the
    interpolation tables above; the rest use standard footwear formulas."""
    us = round(approximate_us_size(foot_length_mm, gender), 1)
    uk = round(us - (1 if gender is Gender.mens else 2), 1)
    eu = round(1.5 * (foot_length_mm + LAST_ALLOWANCE_MM) / 10.0, 1)
    cm = round(foot_length_mm / 10.0, 1)
    return {"us": us, "uk": uk, "eu": eu, "cm": cm, "mondo": mondopoint_size(foot_length_mm)}


@dataclass(frozen=True)
class FootSizingResult:
    mondopoint_mm: int
    us_size_approx: float
    width_code: WidthCode
    arch_class: ArchClass
    sizes: dict[str, float | int]


def compute_foot_sizing(
    foot_length_mm: float,
    ball_width_mm: float,
    gender: Gender,
    instep_mm: float = 0.0,
) -> FootSizingResult:
    return FootSizingResult(
        mondopoint_mm=mondopoint_size(foot_length_mm),
        us_size_approx=round(approximate_us_size(foot_length_mm, gender), 1),
        width_code=width_code(foot_length_mm, ball_width_mm, gender),
        arch_class=arch_class(instep_mm, foot_length_mm),
        sizes=convert_sizes(foot_length_mm, gender),
    )


def fit_score(
    foot_length_mm: float,
    ball_width_mm: float,
    gender: Gender,
    shoe_mondo_min: int,
    shoe_mondo_max: int,
    shoe_width: Literal["narrow", "standard", "wide"],
) -> float:
    """
    Lower is better. Combines length distance from range and width mismatch penalty.
    """
    mondo = mondopoint_size(foot_length_mm)
    if mondo < shoe_mondo_min:
        length_penalty = (shoe_mondo_min - mondo) * 2.0
    elif mondo > shoe_mondo_max:
        length_penalty = (mondo - shoe_mondo_max) * 2.0
    else:
        center = (shoe_mondo_min + shoe_mondo_max) / 2.0
        length_penalty = abs(float(mondo) - center) * 0.06

    wc = width_code(foot_length_mm, ball_width_mm, gender)
    wmap = {
        WidthCode.narrow: "narrow",
        WidthCode.standard: "standard",
        WidthCode.wide: "wide",
    }
    if wmap[wc] == shoe_width:
        width_penalty = 0.0
    elif (
        (wc is WidthCode.standard and shoe_width != "standard")
        or (wc is WidthCode.narrow and shoe_width == "wide")
        or (wc is WidthCode.wide and shoe_width == "narrow")
    ):
        width_penalty = 8.0
    else:
        width_penalty = 3.0

    return length_penalty + width_penalty
