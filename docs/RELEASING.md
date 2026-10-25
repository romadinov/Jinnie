# Releasing Jinnie

The Mac app ships as a **Developer ID–signed, notarized DMG** on GitHub Releases, with **Sparkle** in-app updates. The
iPhone app ships through **TestFlight** (internal testers). The Mac app can't use TestFlight: TestFlight and the Mac
App Store require the App Sandbox, and Jinnie's agent runs Claude Code, Uberdoer, a browser and reMarkable tools,
which a sandboxed app can't.

## One-time setup

1. **CloudKit production schema.** TestFlight and Developer ID builds use the *Production* CloudKit environment.
   Open [CloudKit Console](https://icloud.developer.apple.com) → container `iCloud.com.romadinov.jinnie` → Schema →
   **Deploy Schema Changes…** to Production. Repeat whenever a record type or field is added (Jinnie stores everything in
   one record type, `JinnieRecord`, so this is rare).
2. **App Store Connect app record** (iPhone; Apple's API can't create one):
   [App Store Connect](https://appstoreconnect.apple.com/apps) → + → New App → iOS, name "Jinnie", bundle ID
   `com.romadinov.jinnie`, SKU `jinnie`. `swift scripts/testflight.swift setup` checks it and explains if it's missing.
3. **API key** for the scripts (App Store Connect → Users and Access → Integrations → Team Keys, role Admin):
   ```sh
   export ASC_KEY_PATH=~/path/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=<issuer uuid>
   ```
   Without it the scripts use the Apple ID in Xcode → Settings → Accounts for signing and uploads; notarization then
   needs a keychain profile: `xcrun notarytool store-credentials jinnie-notary --apple-id <you> --team-id SZVSSCJQFN`.
4. **Sparkle signing key**: in your login Keychain (account `com.romadinov.jinnie`), created with Sparkle's
   `generate_keys`. Its public half is `SUPublicEDKey` in `App/macOS/Info.plist`. Back up the private key
   (`generate_keys --account com.romadinov.jinnie -x jinnie-sparkle.key`, store it safely): without it, installed copies
   can't be updated.
5. **Testers group**: `swift scripts/testflight.swift setup` creates the internal group "Jinnie testers" (every build is
   available to it automatically, no Beta App Review).

## Each release

```sh
scripts/bump-build.sh [0.2.0]               # build number +1 (and the version, if given)
scripts/release-mac.sh "What changed"       # archive → Developer ID → notarize → DMG → appcast → GitHub release
scripts/release-iphone.sh                   # archive → upload to TestFlight
swift scripts/testflight.swift status       # processing state, testers
```

## Testers

```sh
swift scripts/testflight.swift invite colleague@company.com "First Last"   # App Store Connect team invite (Developer, Jinnie only)
swift scripts/testflight.swift sync                                        # after they accept: adds them to the group
```

They get a TestFlight email for the iPhone app. For the Mac, send them the
[latest release](https://github.com/romadinov/Jinnie/releases/latest); afterwards the app updates itself.
Each tester needs their own Claude subscription and connects their own accounts in Set Up Jinnie.
