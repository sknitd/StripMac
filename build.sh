#!/bin/bash
# Builds StripMac.app (universal) into ./build. Requires Xcode 15+ on macOS 14+.
set -euo pipefail
cd "$(dirname "$0")"
swift build -c release --arch arm64 --arch x86_64
BIN=$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)/StripMac
APP=build/StripMac.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN" "$APP/Contents/MacOS/StripMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"
codesign --force --deep --sign - "$APP"
(cd build && ditto -c -k --keepParent StripMac.app StripMac.zip)
echo "Built $APP and build/StripMac.zip"
