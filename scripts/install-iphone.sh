#!/bin/bash
# Builds Jinnie for iPhone and installs it on a connected (or Wi-Fi paired) iPhone.
# Usage: scripts/install-iphone.sh            (first connected/available iPhone)
#        scripts/install-iphone.sh <device-id> (see: xcrun devicectl list devices)
set -euo pipefail
cd "$(dirname "$0")/.."
xcodegen generate >/dev/null
# Signing: either an Apple ID in Xcode → Settings → Accounts, or an App Store Connect API key:
#   ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=<uuid> scripts/…
AUTH=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
if [ -n "${1:-}" ]; then DEVICE="$1"; else
  TMP=$(mktemp); xcrun devicectl list devices --json-output "$TMP" >/dev/null 2>&1 || true
  DEVICE=$(python3 -c "
import json,sys
d=json.load(open('$TMP'))
for x in d.get('result',{}).get('devices',[]):
    hp=x.get('hardwareProperties',{}); cp=x.get('connectionProperties',{})
    if hp.get('deviceType')=='iPhone' and hp.get('reality')=='physical' and cp.get('pairingState')=='paired':
        print(x['identifier']); break
"); rm -f "$TMP"
fi
[ -n "$DEVICE" ] || { echo "No iPhone found. Connect it or pass a device id (xcrun devicectl list devices)."; exit 1; }
xcodebuild -project Jinnie.xcodeproj -scheme JinnieIOS -configuration Debug -derivedDataPath build -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
  -destination "generic/platform=iOS" build | grep -E "error:|BUILD" || true
xcrun devicectl device install app --device "$DEVICE" build/Build/Products/Debug-iphoneos/Jinnie.app
echo "Installed on $DEVICE — open Jinnie once on the phone so it registers for iCloud sync."
