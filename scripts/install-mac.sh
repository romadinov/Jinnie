#!/bin/bash
# Builds Jinnie for Mac and installs it to /Applications (run from your own terminal: signing needs
# the Apple ID signed in to Xcode → Settings → Accounts, team SZVSSCJQFN).
set -euo pipefail
cd "$(dirname "$0")/.."
CONFIG="${1:-Debug}"   # Debug = iCloud Development environment (same as Xcode-run iPhone builds)
xcodegen generate >/dev/null
# Signing: either an Apple ID in Xcode → Settings → Accounts, or an App Store Connect API key:
#   ASC_KEY_PATH=~/.appstoreconnect/private_keys/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=<uuid> scripts/…
AUTH=()
if [ -n "${ASC_KEY_PATH:-}" ]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
fi
xcodebuild -project Jinnie.xcodeproj -scheme JinnieMac -configuration "$CONFIG" -derivedDataPath build -allowProvisioningUpdates ${AUTH[@]+"${AUTH[@]}"} \
  SWIFT_OPTIMIZATION_LEVEL=-O SWIFT_COMPILATION_MODE=wholemodule build | grep -E "error:|BUILD" || true
pkill -x Jinnie 2>/dev/null || true
sleep 1
rm -rf /Applications/Jinnie.app
ditto "build/Build/Products/$CONFIG/Jinnie.app" /Applications/Jinnie.app
open /Applications/Jinnie.app
echo "Installed /Applications/Jinnie.app ($CONFIG)"
