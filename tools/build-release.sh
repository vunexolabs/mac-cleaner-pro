#!/usr/bin/env bash
# Build a Release-configured DMG of Mac Cleaner Pro.
#
# $0-mode (no Apple Developer cert):
#   - Ad-hoc signs the binaries (CODE_SIGN_IDENTITY=-).
#   - Skips notarization. Users will see Gatekeeper's "unidentified developer"
#     warning on first launch and need to right-click → Open. See docs/INSTALL.md.
#
# Paid-mode (when you have Developer ID):
#   1. In project.yml set DEVELOPMENT_TEAM and CODE_SIGN_IDENTITY="Developer ID Application: ...".
#   2. Replace REPLACE_TEAM_ID in PrivilegedHelper/Info.plist and CodeSignValidator.swift.
#   3. Replace the "==> Extracting .app from archive" block below with a real
#      `xcodebuild -exportArchive ... -exportOptionsPlist <plist>` call using
#      method `developer-id`. Then notarize:
#        xcrun notarytool submit out/MacCleanerPro-*.dmg --apple-id <id> --team-id <team> --password <app-password> --wait
#        xcrun stapler staple out/MacCleanerPro-*.dmg
#
# Run from the repo root:  ./tools/build-release.sh

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

VERSION=$(awk -F'"' '/MARKETING_VERSION/ { print $2; exit }' project.yml || true)
VERSION="${VERSION:-1.0.0}"
OUT="out"
ARCHIVE="$OUT/MacCleanerPro.xcarchive"
EXPORT="$OUT/Export"
DMG="$OUT/MacCleanerPro-${VERSION}.dmg"
APP="$EXPORT/MacCleanerPro.app"

rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Regenerating Xcode project"
command -v xcodegen >/dev/null || { echo "xcodegen not installed (brew install xcodegen)"; exit 1; }
xcodegen generate

echo "==> Archiving Release"
xcodebuild \
  -project MacCleanerPro.xcodeproj \
  -scheme MacCleanerPro \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  archive | xcpretty || xcodebuild \
  -project MacCleanerPro.xcodeproj \
  -scheme MacCleanerPro \
  -configuration Release \
  -archivePath "$ARCHIVE" \
  archive

echo "==> Extracting .app from archive"
# We deliberately skip `xcodebuild -exportArchive` here: the only export methods
# it accepts on current Xcode (`app-store-connect`, `developer-id`, etc.) all
# require a paid Developer ID. For ad-hoc signed $0-mode builds, the .app inside
# the archive is already the final artifact — copy it out directly.
mkdir -p "$EXPORT"
ARCHIVE_APP="$ARCHIVE/Products/Applications/MacCleanerPro.app"
[ -d "$ARCHIVE_APP" ] || { echo "Archive missing $ARCHIVE_APP"; exit 1; }
cp -R "$ARCHIVE_APP" "$EXPORT/"

[ -d "$APP" ] || { echo "Could not extract .app to $APP"; exit 1; }

echo "==> Re-signing bundle coherently (ad-hoc, single pass)"
# On Apple Silicon (macOS 13+), dyld refuses to load a framework whose synthetic
# ad-hoc team identifier differs from the loading binary's. Each separate
# xcodebuild signing operation produces a *different* synthetic identifier even
# though both signatures are nominally ad-hoc — which is what causes the
# "different Team IDs" launch crash. Re-signing the whole bundle in one
# `codesign --deep` pass forces every binary inside to share one identity.
# (When you upgrade to a paid Developer ID, replace `-` with the cert's CN —
#  e.g. "Developer ID Application: Your Name (TEAMID)" — and notarize after.)
codesign --force --deep --sign - "$APP"
codesign --verify --deep --strict --verbose=2 "$APP" || {
  echo "Warning: codesign verification reported issues"
}

echo "==> Building DMG"
STAGE="$OUT/dmg-stage"
rm -rf "$STAGE"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"

hdiutil create \
  -volname "Mac Cleaner Pro" \
  -srcfolder "$STAGE" \
  -ov -format UDZO \
  "$DMG"

# Checksum. This has to run AFTER hdiutil, or the hash won't describe the file
# anyone actually downloads. Until the app is notarized, a published SHA-256 is
# the only way for someone to verify that the DMG they fetched is the DMG we
# built, so it ships as a release asset alongside the disk image.
echo "==> Checksum"
DMG_NAME="$(basename "$DMG")"
( cd "$OUT" && shasum -a 256 "$DMG_NAME" > "$DMG_NAME.sha256" )
SHA="$(awk '{print $1}' "$DMG.sha256")"

echo
echo "Done."
echo "  DMG:    $DMG"
echo "  SHA256: $SHA"
echo "  Sidecar: $DMG.sha256"
echo
echo "Publish the hash with the release, and verify a download with:"
echo "  shasum -a 256 -c $DMG_NAME.sha256"
echo
echo "Note: This build is ad-hoc signed. Recipients will see a Gatekeeper prompt"
echo "on first launch. Direct them to docs/INSTALL.md for the one-time approval."
echo "Notarization requires an Apple Developer Program membership (\$99/yr)."
