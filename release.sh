#!/usr/bin/env bash
# Copyright (C) 2026 Flip Digital Labs
# SPDX-License-Identifier: GPL-3.0-or-later
# Builds a distributable Hush DMG: universal (Apple silicon + Intel), Developer ID signed with
# the hardened runtime, notarized by Apple and stapled — so it opens on any Mac with no warnings.
#
#   ./release.sh 1.3.0           → dist/Hush-1.3.0.dmg   (signed + notarized)
#   ./release.sh 1.3.0 --adhoc   → dist/Hush-1.3.0.dmg   (unsigned test build; Gatekeeper warns)
#
# One-time setup (Apple Developer Program, certificate, notary profile): see DISTRIBUTION.md.
#
#   SIGN_IDENTITY   "Developer ID Application: Name (TEAMID)"  — auto-detected if omitted
#   NOTARY_PROFILE  keychain profile from `xcrun notarytool store-credentials` (default: hush-notary)
#   APPLE_ID + APPLE_APP_PASSWORD + APPLE_TEAM_ID
#                   use these instead of a keychain profile (GitHub Actions does)
set -euo pipefail
cd "$(dirname "$0")"

APP_NAME="Hush"
VERSION="${1:-}"
MODE="${2:-}"
NOTARY_PROFILE="${NOTARY_PROFILE:-hush-notary}"
ENTITLEMENTS="Resources/Hush.entitlements"
DIST="dist"
APP="$DIST/$APP_NAME.app"
DMG="$DIST/$APP_NAME-$VERSION.dmg"

step() { echo; echo "▸ $*"; }
fail() { echo "✗ $*" >&2; exit 1; }

[[ -n "$VERSION" ]] || fail "Usage: ./release.sh <version> [--adhoc]    e.g. ./release.sh 1.3.0"
[[ "$VERSION" =~ ^[0-9]+(\.[0-9]+){1,2}$ ]] || fail "Version must look like 1.3 or 1.3.0 (got '$VERSION')"
[[ -z "$MODE" || "$MODE" == "--adhoc" ]] || fail "Unknown option '$MODE' (only --adhoc is supported)"

# Build number: commit count if this is a git repo, otherwise a timestamp. Always increases.
BUILD_NUMBER="$(git rev-list --count HEAD 2>/dev/null || date +%Y%m%d%H%M)"

# ── Preflight ────────────────────────────────────────────────────────────────
command -v swift >/dev/null || fail "Swift not found. Install Xcode."
if [[ "$MODE" != "--adhoc" ]]; then
  IDENTITY="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ { print $2; exit }' || true)}"
  [[ -n "$IDENTITY" ]] || fail "No 'Developer ID Application' certificate in your keychain.
  → DISTRIBUTION.md, step 2. Or run with --adhoc for an unsigned test build."
  if [[ -n "${APPLE_ID:-}" && -n "${APPLE_APP_PASSWORD:-}" && -n "${APPLE_TEAM_ID:-}" ]]; then
    NOTARY_AUTH=(--apple-id "$APPLE_ID" --password "$APPLE_APP_PASSWORD" --team-id "$APPLE_TEAM_ID")
  else
    NOTARY_AUTH=(--keychain-profile "$NOTARY_PROFILE")
  fi
  xcrun notarytool history "${NOTARY_AUTH[@]}" >/dev/null 2>&1 \
    || fail "Notarization credentials not found or not working (profile '$NOTARY_PROFILE').
  → DISTRIBUTION.md, step 3."
fi

# ── Build ────────────────────────────────────────────────────────────────────
step "Compiling universal binary (Apple silicon + Intel)…"
swift build -c release --arch arm64 --arch x86_64 \
  || fail "Universal build failed. If it mentions xcbuild, run: sudo xcode-select -s /Applications/Xcode.app"
BIN_DIR="$(swift build -c release --arch arm64 --arch x86_64 --show-bin-path)"
lipo -info "$BIN_DIR/$APP_NAME"

step "Assembling $APP_NAME $VERSION (build $BUILD_NUMBER)"
rm -rf "$DIST"
mkdir -p "$DIST"
scripts/assemble-app.sh "$BIN_DIR/$APP_NAME" "$APP" "$VERSION" "$BUILD_NUMBER"

# ── Sign ─────────────────────────────────────────────────────────────────────
if [[ "$MODE" == "--adhoc" ]]; then
  step "Signing ad hoc (test build — not for public release)"
  codesign --force --options runtime --entitlements "$ENTITLEMENTS" --sign - "$APP"
else
  step "Signing with $IDENTITY"
  codesign --force --options runtime --timestamp --entitlements "$ENTITLEMENTS" --sign "$IDENTITY" "$APP"
fi
codesign --verify --strict --verbose=2 "$APP"

# ── DMG ──────────────────────────────────────────────────────────────────────
step "Creating $DMG"
STAGING="$(mktemp -d)"
ditto "$APP" "$STAGING/$APP_NAME.app"
ln -s /Applications "$STAGING/Applications"
hdiutil create -volname "$APP_NAME $VERSION" -srcfolder "$STAGING" -ov -format UDZO "$DMG" >/dev/null
rm -rf "$STAGING"

# ── Notarize ─────────────────────────────────────────────────────────────────
if [[ "$MODE" != "--adhoc" ]]; then
  codesign --force --timestamp --sign "$IDENTITY" "$DMG"

  step "Notarizing with Apple (usually 1–5 minutes)…"
  LOG="$DIST/notarization.log"
  xcrun notarytool submit "$DMG" "${NOTARY_AUTH[@]}" --wait 2>&1 | tee "$LOG" || true
  if ! grep -q "status: Accepted" "$LOG"; then
    SUBMISSION="$(awk '/^ *id:/ { print $2; exit }' "$LOG")"
    fail "Notarization was not accepted. See why with:
  xcrun notarytool log ${SUBMISSION:-<submission-id>} --keychain-profile $NOTARY_PROFILE"
  fi

  step "Stapling the notarization ticket"
  xcrun stapler staple "$DMG"
  xcrun stapler validate "$DMG"

  step "Checking Gatekeeper accepts it"
  spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG"
fi

shasum -a 256 "$DMG" | tee "$DMG.sha256"

echo
if [[ "$MODE" == "--adhoc" ]]; then
  echo "✓ Test build: $DMG"
  echo "  Not notarized — recipients must open it via System Settings → Privacy & Security → Open Anyway."
else
  echo "✓ Ready to ship: $DMG"
  echo "  Signed, notarized and stapled. Upload it anywhere (GitHub Releases, your site, Gumroad…)."
fi
