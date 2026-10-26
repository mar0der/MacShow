#!/bin/bash
# Rebuilds MacShow's FFmpeg (Vendor/MPVKit/FFmpeg): MPVKit's own build of the same
# version, with macshow-ffmpeg.patch (a few more decoders for old files; no mpv,
# which MacShow takes from MPVKit as is). macOS only, Apple silicon and Intel.
# Run it after changing the MPVKit version in Vendor/MPVKit/Package.swift.
set -euo pipefail
cd "$(dirname "$0")/.."
TAG="1.1.0-n9.0.2"
WORK="$(mktemp -d)"
git clone --depth 1 --branch "$TAG" https://github.com/mpvkit/MPVKit.git "$WORK/MPVKit"
patch -d "$WORK/MPVKit" -p1 < Vendor/MPVKit/macshow-ffmpeg.patch
(cd "$WORK/MPVKit" && make build platform=macos)
for library in Libavcodec Libavdevice Libavfilter Libavformat Libavutil Libswresample Libswscale; do
    cp "$WORK/MPVKit/dist/release/$library.xcframework.zip" Vendor/MPVKit/FFmpeg/
done
rm -rf "$WORK"
echo "Vendor/MPVKit/FFmpeg updated"
