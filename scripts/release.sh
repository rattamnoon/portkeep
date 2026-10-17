#!/bin/bash
# Builds a signed, notarized Burrow.dmg (ADR-0001).
#
# Usage: scripts/release.sh <version>
#
# Needs, on the machine that runs it:
#   - a "Developer ID Application" certificate in the login keychain
#   - DEVELOPER_ID   e.g. "Developer ID Application: Your Name (TEAMID)"
#   - TEAM_ID        e.g. "ABCDE12345"
#   - a notarytool keychain profile named burrow-notary:
#       xcrun notarytool store-credentials burrow-notary --apple-id <id> --team-id <TEAMID>
# Nothing secret is read from or written to the repository.
set -euo pipefail

VERSION="${1:?usage: scripts/release.sh <version>}"
: "${DEVELOPER_ID:?set DEVELOPER_ID}"
: "${TEAM_ID:?set TEAM_ID}"

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
OUT="$ROOT/build/release"
ARCHIVE="$OUT/Burrow.xcarchive"
APP="$OUT/export/Burrow.app"
DMG="$OUT/Burrow-$VERSION.dmg"

rm -rf "$OUT"
mkdir -p "$OUT"
cd "$ROOT"

xcodegen generate
xcodebuild archive \
  -scheme Burrow -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$ARCHIVE" \
  MARKETING_VERSION="$VERSION" \
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

hdiutil create -volname "Burrow" -srcfolder "$APP" -ov -format UDZO "$DMG"
codesign --sign "$DEVELOPER_ID" --timestamp "$DMG"

xcrun notarytool submit "$DMG" --keychain-profile burrow-notary --wait
xcrun stapler staple "$DMG"

spctl -a -t open --context context:primary-signature -vv "$DMG"
shasum -a 256 "$DMG"
echo "Built $DMG"
