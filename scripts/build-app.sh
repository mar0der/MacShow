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
# Constant values for App Intents (Siri and Shortcuts), turned into metadata below.
INTENT_FLAGS=(-Xswiftc -emit-const-values -Xswiftc -Xfrontend -Xswiftc -const-gather-protocols-file
              -Xswiftc -Xfrontend -Xswiftc "$PWD/scripts/support/app-intents-protocols.json")
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --product MacShow "${INTENT_FLAGS[@]}"
swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --product macshow-mcp
BIN_DIR="$(swift build -c "$CONFIG" ${ARCHS[@]+"${ARCHS[@]}"} --show-bin-path)"

APP=build/MacShow.app
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BIN_DIR/MacShow" "$APP/Contents/MacOS/MacShow"
cp "$BIN_DIR/macshow-mcp" "$APP/Contents/MacOS/macshow-mcp"  # the agent bridge, started by MCP apps
cp Resources/Info.plist "$APP/Contents/Info.plist"
[ -f Resources/AppIcon.icns ] && cp Resources/AppIcon.icns "$APP/Contents/Resources/"
cp -R Resources/Licenses "$APP/Contents/Resources/"  # notices and license texts the bundled libraries require
cp -R Resources/Localization/*.lproj "$APP/Contents/Resources/"  # translations (scripts/check-translations.sh)

# Metadata.appintents: what Siri and Shortcuts read. Xcode makes it; a package
# build has to run Apple's processor itself, on the compiler's constant values.
VARIANT="$(tr '[:lower:]' '[:upper:]' <<< "${CONFIG:0:1}")${CONFIG:1}"
OBJECTS="$(find .build -type d -path "*/MacShow.build/$VARIANT/MacShow-p.build/Objects-normal/arm64" | head -1)"
INTENTS_TMP="$(mktemp -d)"
find "$PWD/Sources/MacShow" -name '*.swift' > "$INTENTS_TMP/sources.txt"
find "$PWD/$OBJECTS" -name '*.swiftconstvalues' > "$INTENTS_TMP/constvals.txt"
xcrun appintentsmetadataprocessor --quiet-warnings --output "$APP/Contents/Resources" \
    --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swift)")")")" --module-name MacShow \
    --sdk-root "$(xcrun --sdk macosx --show-sdk-path)" --xcode-version "$(xcodebuild -version | awk '/Build version/{print $3}')" \
    --platform-family macOS --deployment-target 14.0 --target-triple arm64-apple-macos14.0 \
    --source-file-list "$INTENTS_TMP/sources.txt" --swift-const-vals-list "$INTENTS_TMP/constvals.txt" > /dev/null 2>&1 \
    || echo "warning: no App Intents metadata (Siri and Shortcuts won't see MacShow)"
rm -rf "$INTENTS_TMP"
# SwiftPM resource bundles of dependencies, if any.
find "$BIN_DIR" -maxdepth 1 -name '*.bundle' ! -name '*Tests.bundle' -exec cp -R {} "$APP/Contents/Resources/" \;

if [ -z "${SIGN_IDENTITY:-}" ]; then
    SIGN_IDENTITY="$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: .*\)"/\1/p' | head -1)"
fi
# The bridge first (it runs outside the sandbox, started by other apps), then the app around it.
codesign --force --sign "${SIGN_IDENTITY:--}" "$APP/Contents/MacOS/macshow-mcp"
codesign --force --sign "${SIGN_IDENTITY:--}" --entitlements Resources/MacShow.entitlements "$APP"
echo "$APP"
