#!/bin/bash
# Sets the app's version to YY.WW.X: the year and ISO week of the release, and
# which release of that week it is (1, 2…, counted from the git tags), so it says
# how fresh a build is. The build number is the same with two digits for each
# part (264401), so it only goes up.
set -euo pipefail
cd "$(dirname "$0")/.."

WEEK="$(date +%g.%V)"  # ISO year, so late-December days in week 1 count as next year
COUNT="$(git tag --list "v$WEEK.*" | wc -l | tr -d ' ')"
VERSION="$WEEK.$((COUNT + 1))"
BUILD="$(date +%g%V)$(printf '%02d' $((COUNT + 1)))"
# Only the two values, keeping the file's layout.
sed -i '' -E \
    -e "/<key>CFBundleShortVersionString<\/key>/{n;s|<string>[^<]*</string>|<string>$VERSION</string>|;}" \
    -e "/<key>CFBundleVersion<\/key>/{n;s|<string>[^<]*</string>|<string>$BUILD</string>|;}" \
    Resources/Info.plist
echo "$VERSION"
