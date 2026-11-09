#!/usr/bin/env bash
# FootSizer — verify (or document how to enable) the full Xcode developer toolchain.
# Apple’s standalone "Command Line Tools" install does NOT ship xcodebuild; you need the
# Xcode app and the active developer directory must point at it.
set -euo pipefail

XCODE_DEV="/Applications/Xcode.app/Contents/Developer"

if [[ ! -d "$XCODE_DEV" ]]; then
  echo "error: Xcode is not installed at /Applications/Xcode.app"
  echo "Install **Xcode** from the Mac App Store (not only Command Line Tools), then re-run this script."
  exit 1
fi

current="$(xcode-select -p 2>/dev/null || true)"
echo "Active developer directory: ${current:-<none>}"

if [[ "$current" == "$XCODE_DEV" ]]; then
  echo "OK: Using full Xcode CLI (xcodebuild, simctl, etc.)."
else
  echo ""
  echo "Your shell is not using Xcode’s Developer directory (xcodebuild will fail until you fix this)."
  echo "Run once (requires your password):"
  echo "  sudo xcode-select -s $XCODE_DEV"
  echo ""
  echo "Optional: accept the license if prompted:"
  echo "  sudo xcodebuild -license accept"
  echo ""
fi

echo "---"
if [[ "$current" == "$XCODE_DEV" ]]; then
  xcodebuild -version
else
  echo "(Skipping xcodebuild -version until xcode-select points at Xcode.)"
fi
