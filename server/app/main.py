from __future__ import annotations

from fastapi import Depends, FastAPI, HTTPException
from fastapi.middleware.cors import CORSMiddleware
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .database import SessionLocal, init_db
from .models_db import FootMeasurementRecord, ShoeModelRecord
from .schemas import MeasurementCreate, MeasurementOut, ShoeRecommendation
from .seed_catalog import seed_if_empty
from .settings import settings
from .sizing import Gender, compute_foot_sizing, fit_score

app = FastAPI(title=settings.api_title, version="1.0.0")

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


async def get_session() -> AsyncSession:
    async with SessionLocal() as session:
        yield session


@app.on_event("startup")
async def on_startup() -> None:
    await init_db()
    async with SessionLocal() as session:
        await seed_if_empty(session)


@app.post("/v1/measurements", response_model=MeasurementOut)
async def create_measurement(
    body: MeasurementCreate,
    session: AsyncSession = Depends(get_session),
) -> MeasurementOut:
    gender = Gender(body.gender)
    left = compute_foot_sizing(body.left.length_mm, body.left.ball_width_mm, gender)
    right = compute_foot_sizing(body.right.length_mm, body.right.ball_width_mm, gender)

    rec = FootMeasurementRecord(
        device_id=body.device_id,
        gender=body.gender,
        left_length_mm=body.left.length_mm,
        left_width_mm=body.left.ball_width_mm,
        left_mondo_mm=left.mondopoint_mm,
        left_us_approx=left.us_size_approx,
        left_width_code=left.width_code.value,
        right_length_mm=body.right.length_mm,
        right_width_mm=body.right.ball_width_mm,
        right_mondo_mm=right.mondopoint_mm,
        right_us_approx=right.us_size_approx,
        right_width_code=right.width_code.value,
    )
    session.add(rec)
    await session.commit()
    await session.refresh(rec)

    return MeasurementOut(
        id=rec.id,
        gender=rec.gender,
        left_mondo_mm=rec.left_mondo_mm,
        left_us_approx=rec.left_us_approx,
        left_width_code=rec.left_width_code,
        right_mondo_mm=rec.right_mondo_mm,
        right_us_approx=rec.right_us_approx,
        right_width_code=rec.right_width_code,
    )


@app.get("/v1/measurements/{measurement_id}/recommendations", response_model=list[ShoeRecommendation])
async def recommendations(
    measurement_id: str,
    session: AsyncSession = Depends(get_session),
    limit: int = 8,
) -> list[ShoeRecommendation]:
    r = await session.get(FootMeasurementRecord, measurement_id)
    if r is None:
        raise HTTPException(status_code=404, detail="Measurement not found")

    gender = Gender(r.gender)
    shoes = (await session.execute(select(ShoeModelRecord))).scalars().all()

    scored: list[tuple[float, ShoeModelRecord]] = []
    for shoe in shoes:
        left = fit_score(
            r.left_length_mm,
            r.left_width_mm,
            gender,
            shoe.mondo_min_mm,
            shoe.mondo_max_mm,
            shoe.width,  # type: ignore[arg-type]
        )
        right = fit_score(
            r.right_length_mm,
            r.right_width_mm,
            gender,
            shoe.mondo_min_mm,
            shoe.mondo_max_mm,
            shoe.width,  # type: ignore[arg-type]
        )
        combined = left + right
        scored.append((combined, shoe))

    scored.sort(key=lambda x: x[0])
    out: list[ShoeRecommendation] = []
    for score, shoe in scored[: max(1, limit)]:
        out.append(
            ShoeRecommendation(
                shoe_id=shoe.id,
                brand=shoe.brand,
                name=shoe.name,
                style=shoe.style,
                mondo_min_mm=shoe.mondo_min_mm,
                mondo_max_mm=shoe.mondo_max_mm,
                width=shoe.width,
                fit_score=round(score, 2),
                notes=shoe.notes,
            )
        )
    return out


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}
