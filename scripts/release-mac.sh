#!/bin/bash
# Mac release: Developer ID–signed, notarized DMG published as a GitHub release, with the Sparkle appcast that installed
# copies check for updates (Help/Jinnie menu → Check for Updates…).
#   scripts/bump-build.sh && scripts/release-mac.sh "What's new in this build"
# Needs: the Sparkle signing key in your login Keychain (generate_keys --account com.romadinov.jinnie), notarization
# credentials (see release-common.sh) and `gh` signed in to the account that owns romadinov/Jinnie.
set -euo pipefail
source "$(dirname "$0")/release-common.sh"
NOTES="${1:-Bug fixes and improvements.}"
TAG="v$VERSION-$BUILD"
REPO=romadinov/Jinnie
if gh release view "$TAG" -R "$REPO" >/dev/null 2>&1; then echo "Release $TAG exists: run scripts/bump-build.sh first"; exit 1; fi

echo "▸ Archiving Jinnie $VERSION ($BUILD)"
xcodebuild archive -project Jinnie.xcodeproj -scheme JinnieMac -configuration Release -destination 'generic/platform=macOS' \
  -archivePath "$OUT/Jinnie.xcarchive" -derivedDataPath build -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} | grep -E "error:|ARCHIVE" || true
[ -d "$OUT/Jinnie.xcarchive" ] || { echo "Archive failed"; exit 1; }
SPARKLE_BIN=$(ls -d build/SourcePackages/artifacts/sparkle/Sparkle/bin)

cat > "$OUT/ExportOptions-mac.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>developer-id</string><key>teamID</key><string>$TEAM</string>
<key>signingStyle</key><string>automatic</string><key>destination</key><string>export</string>
</dict></plist>
PLIST
echo "▸ Exporting (Developer ID)"
xcodebuild -exportArchive -archivePath "$OUT/Jinnie.xcarchive" -exportPath "$OUT/mac" -exportOptionsPlist "$OUT/ExportOptions-mac.plist" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} | grep -E "error:|EXPORT" || true
APP="$OUT/mac/Jinnie.app"
[ -d "$APP" ] || { echo "Export failed"; exit 1; }
codesign --verify --deep --strict "$APP"

echo "▸ Notarizing the app"
ditto -c -k --keepParent "$APP" "$OUT/Jinnie.zip"
xcrun notarytool submit "$OUT/Jinnie.zip" "${NOTARY[@]}" --wait
xcrun stapler staple "$APP"

echo "▸ Building the DMG"
DMG="$OUT/Jinnie-$VERSION-$BUILD.dmg"
STAGE="$OUT/dmg"; rm -rf "$STAGE"; mkdir -p "$STAGE"
ditto "$APP" "$STAGE/Jinnie.app"; ln -s /Applications "$STAGE/Applications"
hdiutil create -volname "Jinnie" -srcfolder "$STAGE" -ov -format UDZO "$DMG" >/dev/null
IDENTITY=$(security find-identity -v -p codesigning | sed -n 's/.*"\(Developer ID Application: [^"]*\)".*/\1/p' | head -1)
codesign --sign "$IDENTITY" --timestamp "$DMG"
xcrun notarytool submit "$DMG" "${NOTARY[@]}" --wait
xcrun stapler staple "$DMG"
spctl -a -t open --context context:primary-signature -v "$DMG"

echo "▸ Sparkle appcast"
FEED="$OUT/feed"; rm -rf "$FEED"; mkdir -p "$FEED"
cp "$DMG" "$FEED/"
printf '<h2>Jinnie %s (%s)</h2><p>%s</p>\n' "$VERSION" "$BUILD" "$NOTES" > "$FEED/$(basename "$DMG" .dmg).html"
"$SPARKLE_BIN/generate_appcast" --account com.romadinov.jinnie \
  --download-url-prefix "https://github.com/$REPO/releases/download/$TAG/" \
  --embed-release-notes -o "$FEED/appcast.xml" "$FEED"

echo "▸ Publishing $TAG"
gh release create "$TAG" -R "$REPO" --title "Jinnie $VERSION ($BUILD)" --notes "$NOTES" "$DMG" "$FEED/appcast.xml"
echo "Released: https://github.com/$REPO/releases/tag/$TAG (installed copies update within a day, or via Check for Updates…)"
