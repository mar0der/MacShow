#!/bin/bash
# Builds build/MacShow.app: the SwiftPM executable wrapped in a sandboxed app bundle.
# Usage: scripts/build-app.sh [release|debug]
# Signs with this Mac's "Developer ID Application" identity if there is one, else ad-hoc;
# set SIGN_IDENTITY to choose. A real identity matters even for local builds: macOS
# remembers folder-access approvals by signature, and an ad-hoc signature changes
# with every build, so each rebuild would ask again.
set -euo pipefail
cd "$(dirname "$0")/.."

CONFIG="${1:-release}"
# Release builds are universal (Apple silicon and Intel); debug builds only for this Mac.
ARCHS=()
[ "$CONFIG" = release ] && ARCHS=(--arch arm64 --arch x86_64)
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --product MacShow
BIN_DIR="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

APP=build/MacShow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacShow" "$APP/Contents/MacOS/MacShow"
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Licenses "$APP/Contents/Resources/"  # notices and license texts the bundled libraries require
# SwiftPM resource bundles of dependencies, if any.
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' ! -name '*Tests.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
codesign --force --sign "${SIGN_IDENTITY:--}" --entitlements Resources/MacShow.entitlements "$APP"
echo "$APP"
