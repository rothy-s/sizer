"""Example shoe lasts for demonstration; replace with your retail catalog."""

from sqlalchemy.ext.asyncio import AsyncSession

from .models_db import ShoeModelRecord


async def seed_if_empty(session: AsyncSession) -> None:
    from sqlalchemy import select

    r = await session.execute(select(ShoeModelRecord).limit(1))
    if r.scalar_one_or_none() is not None:
        return

    samples = [
        ShoeModelRecord(
            brand="Example Athletics",
            name="Stride Runner 3",
            style="running",
            mondo_min_mm=255,
            mondo_max_mm=265,
            width="standard",
            notes="Neutral last, medium volume.",
        ),
        ShoeModelRecord(
            brand="Example Athletics",
            name="Court Flex",
            style="court",
            mondo_min_mm=250,
            mondo_max_mm=260,
            width="narrow",
            notes="Sleeker forefoot; best for lower ball width.",
        ),
        ShoeModelRecord(
            brand="TrailWorks",
            name="Ridge Hiker Pro",
            style="hiking",
            mondo_min_mm=260,
            mondo_max_mm=275,
            width="wide",
            notes="Roomy toe box; wide-friendly.",
        ),
        ShoeModelRecord(
            brand="Urban Step",
            name="Daily Loafer",
            style="casual",
            mondo_min_mm=240,
            mondo_max_mm=255,
            width="standard",
            notes="Dress-casual last.",
        ),
        ShoeModelRecord(
            brand="SprintLine",
            name="Velocity Spike",
            style="track",
            mondo_min_mm=265,
            mondo_max_mm=275,
            width="narrow",
            notes="Snug racing fit.",
        ),
        ShoeModelRecord(
            brand="ComfortFirst",
            name="Recovery Slide",
            style="recovery",
            mondo_min_mm=235,
            mondo_max_mm=285,
            width="wide",
            notes="Open design; generous width.",
        ),
    ]
    for s in samples:
        session.add(s)
    await session.commit()
