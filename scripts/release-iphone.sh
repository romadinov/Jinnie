#!/bin/bash
# iPhone release: archive and upload to App Store Connect for TestFlight (internal testers: available minutes after
# processing, no review). Then `swift scripts/testflight.swift status`.
#   scripts/bump-build.sh && scripts/release-iphone.sh
# One-time: the app record must exist in App Store Connect (`swift scripts/testflight.swift setup` explains).
set -euo pipefail
source "$(dirname "$0")/release-common.sh"
echo "▸ Archiving Jinnie for iPhone $VERSION ($BUILD)"
xcodebuild archive -project Jinnie.xcodeproj -scheme JinnieIOS -configuration Release -destination 'generic/platform=iOS' \
  -archivePath "$OUT/JinnieIOS.xcarchive" -derivedDataPath build -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} | grep -E "error:|ARCHIVE" || true
[ -d "$OUT/JinnieIOS.xcarchive" ] || { echo "Archive failed"; exit 1; }
cat > "$OUT/ExportOptions-ios.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?><!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>method</key><string>app-store-connect</string><key>teamID</key><string>$TEAM</string>
<key>signingStyle</key><string>automatic</string><key>destination</key><string>upload</string>
<key>testFlightInternalTestingOnly</key><true/><key>manageAppVersionAndBuildNumber</key><false/>
<key>uploadSymbols</key><true/>
</dict></plist>
PLIST
echo "▸ Uploading to TestFlight"
xcodebuild -exportArchive -archivePath "$OUT/JinnieIOS.xcarchive" -exportPath "$OUT/ios" -exportOptionsPlist "$OUT/ExportOptions-ios.plist" \
  -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} | grep -E "error:|EXPORT|Upload" || true
echo "Uploaded $VERSION ($BUILD). Processing takes ~5–15 min; then it's on TestFlight for the internal group."
