#!/bin/bash
# Build AgyQuotaBar.app (pure Swift/AppKit, no external dependencies).
# Usage: ./build.sh [output-dir]   (default: ./build)
set -euo pipefail
cd "$(dirname "$0")"

OUT="${1:-build}"
APP="$OUT/AgyQuotaBar.app"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"

swiftc -O \
  -framework AppKit -framework CoreText -framework Foundation \
  main.swift -o "$APP/Contents/MacOS/AgyQuotaBar"
cp Info.plist "$APP/Contents/Info.plist"

# Ad-hoc signature so macOS will run the locally built app.
codesign --force --deep --sign - "$APP"

echo "Built: $APP"
