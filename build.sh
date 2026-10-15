#!/usr/bin/env bash
# Copyright (C) 2026 Flip Digital Labs
# SPDX-License-Identifier: GPL-3.0-or-later
# Development build of Hush.app with only the Xcode command line tools.
# (For a notarized DMG to share, use ./release.sh — see DISTRIBUTION.md.)
#
#   ./build.sh            → build/Hush.app
#   ./build.sh install    → also copies it to /Applications and launches it
#
# Signing: uses your "Apple Development" certificate if one is in the keychain, so macOS keeps
# the audio permission across rebuilds. Override with SIGN_IDENTITY="…" ./build.sh
# Signed with the hardened runtime + entitlements, same as release builds, so anything the
# runtime would block shows up here first.
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Hush"
APP="build/${APP_NAME}.app"

command -v swift >/dev/null || { echo "✗ Swift not found. Install Xcode or run: xcode-select --install"; exit 1; }

echo "▸ Compiling…"
swift build -c release
BIN_DIR="$(swift build -c release --show-bin-path)"

echo "▸ Assembling ${APP}"
mkdir -p build
scripts/assemble-app.sh "$BIN_DIR/$APP_NAME" "$APP"

IDENTITY="${SIGN_IDENTITY:-}"
if [[ -z "$IDENTITY" ]]; then
  IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Development|Developer ID Application/ { print $2; exit }' || true)"
fi

if [[ -n "$IDENTITY" ]]; then
  echo "▸ Signing with: $IDENTITY"
  codesign --force --options runtime --entitlements Resources/Hush.entitlements --sign "$IDENTITY" "$APP"
else
  echo "▸ No developer certificate found — signing ad hoc."
  echo "  (macOS may ask for the audio permission again after each rebuild.)"
  codesign --force --options runtime --entitlements Resources/Hush.entitlements --sign - "$APP"
fi

if [[ "${1:-}" == "install" ]]; then
  DEST="/Applications/${APP_NAME}.app"
  pkill -x "$APP_NAME" 2>/dev/null || true
  sleep 0.5
  rm -rf "$DEST"
  cp -R "$APP" "$DEST"
  open "$DEST"
  echo "✓ Installed to $DEST and launched — look for the speaker icon in the menu bar."
else
  echo "✓ Built $APP"
  echo "  Run it:      open $APP"
  echo "  Or install:  ./build.sh install"
fi
