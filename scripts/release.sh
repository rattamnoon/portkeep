#!/bin/bash
# Builds Burrow-<version>.dmg (ADR-0001), signed and notarized unless UNSIGNED=1.
#
# Usage: scripts/release.sh <version> [build-number]
#
# Signed build needs:
#   - a "Developer ID Application" certificate in a keychain on the search list
#   - DEVELOPER_ID   e.g. "Developer ID Application: Your Name (TEAMID)"
#   - TEAM_ID        e.g. "ABCDE12345"
#   - a notarytool keychain profile named burrow-notary:
#       xcrun notarytool store-credentials burrow-notary --apple-id <id> --team-id <TEAMID>
#     NOTARY_KEYCHAIN points at the keychain holding it when that isn't the login keychain (CI).
# UNSIGNED=1 builds an ad-hoc signed dmg with no notarization (Gatekeeper will warn).
# Nothing secret is read from or written to the repository.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version> [build-number]}"
BUILD="${2:-1}"
UNSIGNED="${UNSIGNED:-0}"
if [ "$UNSIGNED" != 1 ]; then
  : "${DEVELOPER_ID:?set DEVELOPER_ID, or UNSIGNED=1}"
  : "${TEAM_ID:?set TEAM_ID, or UNSIGNED=1}"
fi

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/Burrow.xcarchive"
APP="$OUT/export/Burrow.app"
DMG="$OUT/Burrow-$VERSION.dmg"

rm -rf "$OUT"
mkdir -p "$OUT/export"
cd "$ROOT"

xcodegen generate

if [ "$UNSIGNED" = 1 ]; then
  xcodebuild archive \
    -scheme Burrow -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- ONLY_ACTIVE_ARCH=NO
  cp -R "$ARCHIVE/Products/Applications/Burrow.app" "$APP"
else
  xcodebuild archive \
    -scheme Burrow -configuration Release -destination 'generic/platform=macOS' \
    -archivePath "$ARCHIVE" \
    MARKETING_VERSION="$VERSION" CURRENT_PROJECT_VERSION="$BUILD" \
    CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY="$DEVELOPER_ID" DEVELOPMENT_TEAM="$TEAM_ID" \
    OTHER_CODE_SIGN_FLAGS="--timestamp" ONLY_ACTIVE_ARCH=NO

  cat > "$OUT/export.plist" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>method</key><string>developer-id</string>
  <key>teamID</key><string>$TEAM_ID</string>
  <key>signingStyle</key><string>manual</string>
  <key>signingCertificate</key><string>Developer ID Application</string>
</dict></plist>
EOF
  xcodebuild -exportArchive -archivePath "$ARCHIVE" -exportOptionsPlist "$OUT/export.plist" -exportPath "$OUT/export"
fi

# A drag-to-Applications disk image.
STAGE="$OUT/dmg"
mkdir -p "$STAGE"
cp -R "$APP" "$STAGE/"
ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Burrow $VERSION" -srcfolder "$STAGE" -ov -format UDZO "$DMG"

if [ "$UNSIGNED" != 1 ]; then
  codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"
  NOTARY_ARGS=(--keychain-profile burrow-notary)
  [ -n "${NOTARY_KEYCHAIN:-}" ] && NOTARY_ARGS+=(--keychain "$NOTARY_KEYCHAIN")
  xcrun notarytool submit "$DMG" "${NOTARY_ARGS[@]}" --wait
  xcrun stapler staple "$DMG"
  spctl -a -t open --context context:primary-signature -vv "$DMG"
fi

(cd "$OUT" && shasum -a 256 "$(basename "$DMG")" > "$(basename "$DMG").sha256")
cat "$DMG.sha256"
echo "Built $DMG"
