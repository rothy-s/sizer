#!/usr/bin/env bash
# Build FootSizer from the command line (requires full Xcode, not only CLT).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PROJECT="$ROOT/ios/FootSizer/FootSizer.xcodeproj"
SCHEME="${SCHEME:-FootSizer}"

# Use full Xcode if installed, even when `xcode-select` still points at Command Line Tools.
export DEVELOPER_DIR="${DEVELOPER_DIR:-/Applications/Xcode.app/Contents/Developer}"
# Default: Simulator (usually builds without a paid signing team). Override, e.g.:
#   DESTINATION='generic/platform=iOS' ./build.sh
DESTINATION="${DESTINATION:-generic/platform=iOS Simulator}"

if ! command -v xcodebuild >/dev/null 2>&1; then
  echo "error: xcodebuild not found. Install Xcode from the App Store, then run:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  exit 1
fi

if ! xcodebuild -version >/dev/null 2>&1; then
  echo "error: xcodebuild failed. Point the active developer directory at Xcode:" >&2
  echo "  sudo xcode-select -s /Applications/Xcode.app/Contents/Developer" >&2
  echo "Or run: $ROOT/ios/scripts/use-xcode-cli.sh" >&2
  exit 1
fi

echo "Building scheme=$SCHEME destination=$DESTINATION"
exec xcodebuild \
  -project "$PROJECT" \
  -scheme "$SCHEME" \
  -destination "$DESTINATION" \
  -configuration Debug \
  build
