#!/bin/bash
# Builds a release MacShow.app and packs it into build/MacShow.dmg (with an
# Applications shortcut to drag it onto).
# Signed ad-hoc unless SIGN_IDENTITY is set; see RELEASING.md for notarizing.
set -euo pipefail
cd "$(dirname "$0")/.."

scripts/build-app.sh release
STAGE=build/dmg
rm -rf "$STAGE" build/MacShow.dmg
mkdir -p "$STAGE"
cp -R build/MacShow.app "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname MacShow -srcfolder "$STAGE" -ov -format UDZO build/MacShow.dmg >/dev/null
rm -rf "$STAGE"
[ -n "${SIGN_IDENTITY:-}" ] && codesign --force --sign "$SIGN_IDENTITY" build/MacShow.dmg
# With NOTARY_PROFILE (a notarytool keychain profile), Apple checks the DMG and the ticket is stapled to it.
if [ -n "${NOTARY_PROFILE:-}" ]; then
    xcrun notarytool submit build/MacShow.dmg --keychain-profile "$NOTARY_PROFILE" --wait
    xcrun stapler staple build/MacShow.dmg
fi
echo build/MacShow.dmg
