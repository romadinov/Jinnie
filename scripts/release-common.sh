# Shared by the release scripts (sourced). Signing and uploads use either the Apple ID in Xcode → Settings → Accounts,
# or an App Store Connect API key (Admin or App Manager):
#   export ASC_KEY_PATH=~/path/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=<uuid>
# Notarization uses the same key, or a notarytool keychain profile (NOTARY_PROFILE, default "jinnie-notary"):
#   xcrun notarytool store-credentials jinnie-notary --apple-id <you@…> --team-id SZVSSCJQFN   # asks for an app-specific password
cd "$(dirname "$0")/.."
TEAM=SZVSSCJQFN
VERSION=$(sed -n 's/.*MARKETING_VERSION: "\([^"]*\)".*/\1/p' project.yml)
BUILD=$(sed -n 's/.*CURRENT_PROJECT_VERSION: "\([0-9]*\)".*/\1/p' project.yml)
OUT=build/release/$VERSION-$BUILD
mkdir -p "$OUT"
AUTH=()
NOTARY=(--keychain-profile "${NOTARY_PROFILE:-jinnie-notary}")
if [ -n "${ASC_KEY_PATH:-}" ]; then
  AUTH=(-authenticationKeyPath "$ASC_KEY_PATH" -authenticationKeyID "$ASC_KEY_ID" -authenticationKeyIssuerID "$ASC_ISSUER_ID")
  NOTARY=(--key "$ASC_KEY_PATH" --key-id "$ASC_KEY_ID" --issuer "$ASC_ISSUER_ID")
fi
SPARKLE_BIN=$(ls -d build/SourcePackages/artifacts/sparkle/Sparkle/bin 2>/dev/null || true)
xcodegen generate >/dev/null
