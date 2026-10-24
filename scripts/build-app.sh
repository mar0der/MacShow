#!/bin/bash
# Builds build/MacShow.app: the SwiftPM executable wrapped in a sandboxed app bundle.
# Usage: scripts/build-app.sh [release|debug]
# Signs ad-hoc by default; set SIGN_IDENTITY to a "Developer ID Application: …" identity to sign for distribution.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
# Release builds are universal (Apple silicon and Intel); debug builds only for this Mac.
ARCHS=()
[ "$CONFIG" = release ] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" "${ARCHS[@]}" --product MacShow
BIN_DIR="$(swift build -c "$CONFIG" "${ARCHS[@]}" --show-bin-path)"

APP=build/MacShow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacShow" "$APP/Contents/MacOS/MacShow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Licenses "$APP/Contents/Resources/"  # notices and license texts the bundled libraries require
# SwiftPM resource bundles of dependencies, if any.
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' ! -name '*Tests.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

codesign --force --sign "${SIGN_IDENTITY:--}" --entitlements Resources/MacShow.entitlements "$APP"
echo "$APP"
