from __future__ import annotations

import uuid
from datetime import datetime
from typing import Optional

from sqlalchemy import DateTime, Float, Integer, String, Text
from sqlalchemy.orm import Mapped, mapped_column

from .database import Base


class FootMeasurementRecord(Base):
    __tablename__ = "foot_measurements"

    id: Mapped[str] = mapped_column(String(36), primary_key=True, default=lambda: str(uuid.uuid4()))
    created_at: Mapped[datetime] = mapped_column(DateTime, default=datetime.utcnow)
    device_id: Mapped[Optional[str]] = mapped_column(String(128), nullable=True)
    gender: Mapped[str] = mapped_column(String(16))

    left_length_mm: Mapped[float] = mapped_column(Float)
    left_width_mm: Mapped[float] = mapped_column(Float)
    left_arch_mm: Mapped[float] = mapped_column(Float, default=0.0)
    left_mondo_mm: Mapped[int] = mapped_column(Integer)
    left_us_approx: Mapped[float] = mapped_column(Float)
    left_width_code: Mapped[str] = mapped_column(String(32))
    left_arch_class: Mapped[str] = mapped_column(String(16), default="medium")

    right_length_mm: Mapped[float] = mapped_column(Float)
    right_width_mm: Mapped[float] = mapped_column(Float)
    right_arch_mm: Mapped[float] = mapped_column(Float, default=0.0)
    right_mondo_mm: Mapped[int] = mapped_column(Integer)
    right_us_approx: Mapped[float] = mapped_column(Float)
    right_width_code: Mapped[str] = mapped_column(String(32))
    right_arch_class: Mapped[str] = mapped_column(String(16), default="medium")


class ShoeModelRecord(Base):
    __tablename__ = "shoe_models"

    id: Mapped[str] = mapped_column(
        String(36), primary_key=True, default=lambda: str(uuid.uuid4())
    )
    brand: Mapped[str] = mapped_column(String(128))
    name: Mapped[str] = mapped_column(String(256))
    style: Mapped[str] = mapped_column(String(64))
    mondo_min_mm: Mapped[int] = mapped_column(Integer)
    mondo_max_mm: Mapped[int] = mapped_column(Integer)
    width: Mapped[str] = mapped_column(String(32))
    notes: Mapped[Optional[str]] = mapped_column(Text, nullable=True)
