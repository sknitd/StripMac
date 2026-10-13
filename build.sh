#!/bin/bash
# Builds StripMac.app (universal) into ./build. Works with Xcode 15+ or just the Command Line Tools
# (each arch is built separately and merged with lipo, which avoids needing Xcode's xcbuild).
set -euo pipefail
cd "$(dirname "$0")"
BINS=()
for arch in arm64 x86_64; do
  # Separate scratch paths: two arches sharing one build database corrupts it on rebuilds.
  swift build -c release --arch "$arch" --scratch-path ".build/$arch"
  BINS+=("$(swift build -c release --arch "$arch" --scratch-path ".build/$arch" --show-bin-path)/StripMac")
done
APP=build/StripMac.app
rm -rf build && mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
lipo -create "${BINS[@]}" -output "$APP/Contents/MacOS/StripMac"
cp Resources/Info.plist "$APP/Contents/Info.plist"
cp Resources/AppIcon.icns "$APP/Contents/Resources/AppIcon.icns"
codesign --force --deep --sign - "$APP"
(cd build && ditto -c -k --keepParent StripMac.app StripMac.zip)
echo "Built $APP and build/StripMac.zip"
