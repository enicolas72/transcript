#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
cd "$SCRIPT_DIR"

echo "Building Transcript..."
swift build -c release 2>&1

# Locate the built binary
BINARY=$(swift build -c release --show-bin-path)/Transcript

# Assemble .app bundle
APP_DIR="$SCRIPT_DIR/Transcript.app"
rm -rf "$APP_DIR"
mkdir -p "$APP_DIR/Contents/MacOS"
mkdir -p "$APP_DIR/Contents/Resources"

cp "$BINARY" "$APP_DIR/Contents/MacOS/Transcript"
cp "$SCRIPT_DIR/Resources/Info.plist" "$APP_DIR/Contents/Info.plist"

echo "Built: $APP_DIR"
echo "Launching..."
open "$APP_DIR"
