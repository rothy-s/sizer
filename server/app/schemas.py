from typing import Optional

from pydantic import BaseModel, Field


class FootSideIn(BaseModel):
    length_mm: float = Field(..., gt=0, description="Heel to longest toe (Mondopoint length axis), mm")
    ball_width_mm: float = Field(..., gt=0, description="Widest forefoot (ball) width, mm")


class MeasurementCreate(BaseModel):
    gender: str = Field(..., pattern="^(mens|womens)$")
    device_id: Optional[str] = None
    left: FootSideIn
    right: FootSideIn


class MeasurementOut(BaseModel):
    id: str
    gender: str
    left_mondo_mm: int
    left_us_approx: float
    left_width_code: str
    right_mondo_mm: int
    right_us_approx: float
    right_width_code: str


class ShoeRecommendation(BaseModel):
    shoe_id: str
    brand: str
    name: str
    style: str
    mondo_min_mm: int
    mondo_max_mm: int
    width: str
    fit_score: float
    notes: Optional[str] = None
