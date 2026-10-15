#!/usr/bin/env bash
# Copyright (C) 2026 Flip Digital Labs
# SPDX-License-Identifier: GPL-3.0-or-later
# Assembles Hush.app from a compiled binary: Info.plist, app icon, version stamp.
# Used by build.sh (development) and release.sh (distribution).
#
#   scripts/assemble-app.sh <binary> <output.app> [version] [build-number]
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BINARY="$1"
APP="$2"
VERSION="${3:-}"
BUILD="${4:-}"
NAME="$(basename "$APP" .app)"

rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"
cp "$BINARY" "$APP/Contents/MacOS/$NAME"
cp "$ROOT/Resources/Info.plist" "$APP/Contents/Info.plist"
# GPL-3.0 + third-party notices travel with every copy of the app.
cp "$ROOT/LICENSE" "$ROOT/NOTICE.md" "$APP/Contents/Resources/"

PLIST="$APP/Contents/Info.plist"
if [[ -n "$VERSION" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$PLIST"
fi
if [[ -n "$BUILD" ]]; then
  /usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD" "$PLIST"
fi

# App icon: Resources/AppIcon.png (1024×1024) → AppIcon.icns
if [[ -f "$ROOT/Resources/AppIcon.png" ]]; then
  WORK="$(mktemp -d)"
  ICONSET="$WORK/AppIcon.iconset"
  mkdir -p "$ICONSET"
  for size in 16 32 128 256 512; do
    sips -z "$size" "$size" "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    sips -z "$double" "$double" "$ROOT/Resources/AppIcon.png" --out "$ICONSET/icon_${size}x${size}@2x.png" >/dev/null
  done
  iconutil -c icns "$ICONSET" -o "$APP/Contents/Resources/AppIcon.icns"
  rm -rf "$WORK"
fi
