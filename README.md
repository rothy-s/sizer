# FootSizer

## What you have

### 1. API (`server/`)

- **FastAPI** app with SQLite (`footsizer.db`) via SQLAlchemy async.
- **`POST /v1/measurements`** — stores left/right **heel–longest-toe length (mm)** and **ball (forefoot) width (mm)**, plus derived **Mondopoint (ISO 9407–style length in mm, 5 mm steps)**, **approximate US size** (table-based, gender-specific), and **narrow / standard / wide** from length–width ratio (Brannock-style bands).
- **`GET /v1/measurements/{id}/recommendations`** — ranks seeded **shoe lasts** by Mondopoint range fit, width match, and a small penalty for being off the center of the size range.
- **Run locally:** `cd server && ./run.sh` (listens on `0.0.0.0:8765` so a phone can reach your Mac).

### 2. iOS app (`ios/FootSizer/`)

- **SwiftUI** app with **`FootSizer.xcodeproj`** (open in Xcode on a Mac with Xcode installed).
- **LiDAR path:** `ARWorldTrackingConfiguration` + **`sceneReconstruction = .mesh`**. Tap on a foot, then **Capture** — the app finds mesh near the camera ray, clusters vertices in a **20 cm** sphere, and takes the horizontal **AABB** so **longer span ≈ foot length** and **shorter ≈ ball width** (reasonable for feet on the floor with **Y up**).
- **Manual entry** for length/ball width if you’re on Simulator or a non-LiDAR device.
- **API base URL** in the form (saved in UserDefaults). For a **physical device**, use your Mac’s LAN IP, e.g. `http://192.168.1.10:8765` (not `127.0.0.1`). **ATS** allows local networking via `NSAllowsLocalNetworkUsage`-style allowance in `Info.plist`.
- **Signing:** set your **Team** in the target; bundle id is `com.example.FootSizer` (change if you like).

### 3. Industry-aligned measurements (in code)

- **Mondopoint length (mm)** as the primary stored length.
- **Ball width (mm)** for width class and matching to **narrow / standard / wide** lasts.
- Comments in `server/app/sizing.py` describe Mondopoint and how width is used.

## Limitations (honest)

- **LiDAR mesh** includes whatever is in the scene; accuracy is best with **only the foot in the cluster**, good light, and **tap centered on the foot**. For production you’d add segmentation, calibration, or a guided template.
- **US size** is **approximate**; retail should follow **ISO 19407** conversion tables and brand-specific lasts.
- The **shoe list** is **sample data** in `server/app/seed_catalog.py` — replace with your real catalog and last specs.

## Quick test (server)

```bash
cd server && ./run.sh
```

Then open **`ios/FootSizer/FootSizer.xcodeproj`** in Xcode, run on a **LiDAR** iPhone/iPad, set the API URL to your machine, scan or enter measurements, and submit.

## Tests

**Server** (from `server/`):

```bash
python3 -m pip install -r requirements-dev.txt
python3 -m pytest tests/ -v
```

Uses a dedicated SQLite file at `server/tests/test_api.sqlite` (ignored by git).

**iOS** (in Xcode): select the **FootSizerTests** target and press **⌘U**, or run tests from the Test navigator. Tests cover JSON encode/decode and `FootSizingLocal` math; they run in the simulator and do not exercise ARKit.

## Next steps (optional)

- Replace the seed catalog with your production database.
- Tighten mesh sampling (e.g. floor plane + ROI).
- Add optional authentication on `POST /v1/measurements`.
