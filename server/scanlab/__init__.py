"""Scan lab: read recorded scan bundles from the iOS app and replay them offline.

A bundle is what `ScanRecorder.swift` writes for every capture (accepted or rejected):
the exact point cloud the on-device engine saw, plus metadata and a photo. Replaying it
through the pure-Python reference pipeline (`tests/foot_geometry_reference.py`) shows
where a capture stopped looking like a foot.

    python -m scanlab.replay path/to/Scans
"""

import sys
from pathlib import Path

# The reference pipeline lives with the tests that validate it; make it importable.
_TESTS_DIR = str(Path(__file__).resolve().parents[1] / "tests")
if _TESTS_DIR not in sys.path:
    sys.path.insert(0, _TESTS_DIR)
