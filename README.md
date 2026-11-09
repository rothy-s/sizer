# FootSizer

## Foot sizing context (Brannock & Mondopoint)

A **Brannock device** measures foot **length**, **width**, and **arch length** (heel-to-ball) to determine appropriate shoe sizing. **Mondopoint** is an international standard (**ISO 9407:1991**) that indicates average foot **length** and **width** in millimeters.

Using a Brannock device properly means **standing** so the foot has full weight distribution, and prioritizing **arch length**—where the shoe flexes—over total **heel-to-toe** length when interpreting size.

## What you have

### 1. API (`server/`)

- **FastAPI** app with SQLite (`footsizer.db`) via SQLAlchemy async.
- **`POST /v1/measurements`** — stores left/right **heel–longest-toe length (mm)**, **ball (forefoot) width (mm)**, and **arch/instep height (mm)**, plus derived **Mondopoint (ISO 9407–style length in mm, 5 mm steps)**, **approximate US size**, **narrow / standard / wide**, **arch class (low / medium / high)**, and a **multi-country size breakdown (US / UK / EU / CM / Mondopoint)** per foot.
- **`GET /v1/measurements/{id}/recommendations`** — ranks seeded **shoe lasts** by Mondopoint range fit, width match, and a small penalty for being off the center of the size range.
- **Run locally:** `cd server && ./run.sh` (listens on `0.0.0.0:8765` so a phone can reach your Mac).

### 2. iOS app (`ios/FootSizer/`)

- **Full Xcode CLI** (`xcodebuild`, Simulator, etc.) requires the **Xcode app** from the App Store—not only Apple’s standalone Command Line Tools. After installing Xcode, point the active developer directory at it and verify:
  ```bash
  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer
  xcodebuild -version
  ```
  The repo includes **`ios/scripts/use-xcode-cli.sh`**; run it to confirm your setup (it prints the exact `xcode-select` command if needed).
  **CLI build** (after Xcode is active): `ios/scripts/build.sh` (defaults to **iOS Simulator**; set `DESTINATION` to override).
- **SwiftUI** app with **`FootSizer.xcodeproj`** (open in Xcode on a Mac with Xcode installed).
- **Foot lock-on (both capture paths):** the fused point cloud is run through `FootMeasurementGeometry`, which **removes the floor plane** (histogram-peak of the vertical axis), **isolates the foot** as the connected component containing your tap (dropping the floor, the other foot, and the leg above a height cap), orients it by **PCA** in the horizontal plane (so a foot at an angle no longer inflates length), then derives **heel-to-toe length** (principal-axis extent + taper correction), **ball width** (widest forefoot extent), and **arch/instep height**. Only the locked-on foot cluster is drawn back (green), and a capture is **rejected** if no clean foot can be isolated. The algorithm has a pure-Python reference spec at `server/tests/foot_geometry_reference.py`; both are validated against a parametric foot model (width within ~3 mm, length within ~6 mm across sizes and rotations) and a real Scaniverse scan.
- **LiDAR path:** `ARWorldTrackingConfiguration` + scene reconstruction. Tap on a foot, then **Capture** — dense **back-camera** depth + mesh fusion (vertical axis = ARKit world **Y**).
- **TrueDepth path** (iPhones with Face ID / front depth): optional **Scan with TrueDepth (front)** — `AVCaptureDepthDataOutput` on the **builtInTrueDepthCamera**, fused over several frames, points rotated into a **CoreMotion** gravity-aligned frame (vertical axis = **Z**). Easiest with a **mirror** so you can see the screen while aiming at your feet.
- **Results screen:** after both feet are measured, **See measurements & sizes** opens a stylized, on-device results view — per-foot size with a **country/size-system toggle (US / UK / EU / CM / Mondopoint)**, a **heel-to-toe ruler**, a **ball-width 3A…3E letter scale**, and an **arch-height (low/medium/high)** gauge. Renders entirely offline; the server round-trip is optional (shoe recommendations).
- **Manual entry** for length/ball width if you’re on Simulator or a non-LiDAR device.
- **API base URL** in the form (saved in UserDefaults). For a **physical device**, use your Mac’s LAN IP, e.g. `http://192.168.1.10:8765` (not `127.0.0.1`). **ATS** allows local networking via `NSAllowsLocalNetworkUsage`-style allowance in `Info.plist`.
- **Signing:** set your **Team** in the target; bundle id is `com.example.FootSizer` (change if you like).

### 3. Industry-aligned measurements (in code)

- **Mondopoint length (mm)** as the primary stored length.
- **Ball width (mm)** for width class and matching to **narrow / standard / wide** lasts.
- Comments in `server/app/sizing.py` describe Mondopoint and how width is used.

## Limitations (honest)

- **Foot isolation** removes the floor and keeps the tapped foot's connected component, but it is **geometric, not semantic** — accuracy is still best with the **foot flat on the floor**, good light, and the **tap on the foot**. A foot heavily overlapped by the leg at an angle (as in the raw Scaniverse fixture) can still inflate width. For production you'd add a learned foot-shape model, calibration, or a guided template.
- **Absolute length** carries a small calibration offset (`TIP_CORRECTION_MM`) from the floor-band cut; it's tuned to a parametric model and should be **calibrated against real reference feet** for a specific device.
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

`server/tests/test_mesh_foot_measurement.py` validates the pipeline: it builds **parametric feet with known dimensions** across sizes and rotations and asserts accuracy + rotation-invariance, and checks rejection of floor-only / too-sparse inputs.

The pipeline reference spec is `server/tests/foot_geometry_reference.py`; the iOS `FootMeasurementGeometry` mirrors it. The real **Scaniverse** export lives at **`tests/fixtures/Scaniverse_2026_03_24_232742.obj`** (+ matching **`.mtl`**) and is run through an app-style tap-and-crop in the tests to confirm floor isolation yields a plausible foot.

**iOS** (in Xcode): select the **FootSizerTests** target and press **⌘U**, or run tests from the Test navigator. Tests cover JSON encode/decode, `FootSizingLocal` math, and **`FootMeasurementGeometry`** against synthetic 3-D feet with known dimensions across rotations, plus rejection cases (no ARKit). AR capture is not exercised in CI. Launch the app with `-previewResults 1` to open the results screen directly with sample data.

## Next steps (optional)

- Replace the seed catalog with your production database.
- Tighten mesh sampling (e.g. floor plane + ROI).
- Add optional authentication on `POST /v1/measurements`.
