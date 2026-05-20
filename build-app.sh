#!/bin/bash
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building TapTap..."
swift build --disable-sandbox -c release

BINARY=".build/arm64-apple-macosx/release/TapTap"
APP="TapTap.app"
CONTENTS="$APP/Contents"
MACOS="$CONTENTS/MacOS"
RESOURCES="$CONTENTS/Resources"

rm -rf "$APP"
mkdir -p "$MACOS" "$RESOURCES"

cp "$BINARY" "$MACOS/TapTap"
cp "Sources/TapTap/Info.plist" "$CONTENTS/Info.plist"

# Ad-hoc sign so macOS treats this as a proper code-signed bundle.
# This reduces how often the Accessibility permission becomes stale after rebuilds.
codesign --force --deep --sign - "$APP"

echo "Created $APP"
echo ""
echo "To run:  open TapTap.app"
echo "To install: cp -r TapTap.app /Applications/"
