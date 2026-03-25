"""
Configure a dedicated SQLite file for API tests before ``app`` is imported.
"""

from __future__ import annotations

import os
from pathlib import Path

import pytest
from starlette.testclient import TestClient

# Must run before importing app.* (engine binds to database URL at import time).
_test_db = Path(__file__).resolve().parent / "test_api.sqlite"
if _test_db.exists():
    _test_db.unlink()
os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{_test_db}"

from app.main import app  # noqa: E402


@pytest.fixture
def api_client() -> TestClient:
    """Runs FastAPI lifespan (startup) so DB is initialized."""
    with TestClient(app) as client:
        yield client
