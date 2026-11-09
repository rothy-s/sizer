"""HTTP API tests."""

from __future__ import annotations

from starlette.testclient import TestClient


def test_health(api_client: TestClient) -> None:
    r = api_client.get("/health")
    assert r.status_code == 200
    assert r.json()["status"] == "ok"


def test_create_measurement(api_client: TestClient) -> None:
    body = {
        "gender": "mens",
        "device_id": "test-device",
        "left": {"length_mm": 270.0, "ball_width_mm": 100.0, "arch_height_mm": 70.0},
        "right": {"length_mm": 268.0, "ball_width_mm": 99.0, "arch_height_mm": 55.0},
    }
    r = api_client.post("/v1/measurements", json=body)
    assert r.status_code == 200
    data = r.json()
    assert "id" in data
    assert data["gender"] == "mens"
    assert data["left_mondo_mm"] == 270
    assert data["right_mondo_mm"] == 270
    # Arch class + multi-country sizes are returned.
    assert data["left_arch_class"] == "medium"   # 70/270 ≈ 0.259
    assert data["right_arch_class"] == "low"      # 55/268 ≈ 0.205
    assert data["left_sizes"]["us"] == 10.0
    assert set(data["left_sizes"]) == {"us", "uk", "eu", "cm", "mondo"}


def test_create_measurement_without_arch_defaults(api_client: TestClient) -> None:
    """arch_height_mm is optional (manual entry omits it)."""
    body = {
        "gender": "womens",
        "left": {"length_mm": 240.0, "ball_width_mm": 92.0},
        "right": {"length_mm": 240.0, "ball_width_mm": 92.0},
    }
    r = api_client.post("/v1/measurements", json=body)
    assert r.status_code == 200
    assert r.json()["left_arch_class"] == "medium"


def test_recommendations_after_create(api_client: TestClient) -> None:
    body = {
        "gender": "womens",
        "left": {"length_mm": 240.0, "ball_width_mm": 92.0},
        "right": {"length_mm": 241.0, "ball_width_mm": 93.0},
    }
    created = api_client.post("/v1/measurements", json=body)
    assert created.status_code == 200
    mid = created.json()["id"]

    r = api_client.get(f"/v1/measurements/{mid}/recommendations", params={"limit": 5})
    assert r.status_code == 200
    items = r.json()
    assert isinstance(items, list)
    assert len(items) >= 1
    assert "fit_score" in items[0]
    assert "shoe_id" in items[0]


def test_recommendations_404(api_client: TestClient) -> None:
    r = api_client.get("/v1/measurements/00000000-0000-0000-0000-000000000000/recommendations")
    assert r.status_code == 404
