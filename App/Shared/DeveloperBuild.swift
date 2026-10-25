import Foundation
#if os(macOS)
import Security
#endif

/// True for development-signed builds — the developer's own installs (Xcode or scripts/install-release.sh).
/// Improvement notes and crash reports are collected only in those: they land in the user's own iCloud,
/// which only the developer's agents read. (Apps can't see the App Store account's email, so the signature
/// is the reliable signal; TestFlight and App Store builds are distribution-signed.)
enum DeveloperBuild {
    static let isDeveloper: Bool = {
        #if DEBUG
        return true
        #else
        #if os(macOS)
        // The app's own code signature allows debugging (development signing).
        var code: SecCode?
        var staticCode: SecStaticCode?
        var info: CFDictionary?
        guard SecCodeCopySelf([], &code) == errSecSuccess, let code,
              SecCodeCopyStaticCode(code, [], &staticCode) == errSecSuccess, let staticCode,
              SecCodeCopySigningInformation(staticCode, SecCSFlags(rawValue: kSecCSSigningInformation), &info) == errSecSuccess,
              let entitlements = (info as? [String: Any])?[kSecCodeInfoEntitlementsDict as String] as? [String: Any]
        else { return false }
        return entitlements["com.apple.security.get-task-allow"] as? Bool == true
        #else
        // A development provisioning profile is embedded and allows debugging (get-task-allow).
        guard let data = try? Data(contentsOf: Bundle.main.bundleURL.appending(path: "embedded.mobileprovision")) else { return false }
        let text = String(decoding: data, as: UTF8.self)
        // iOS: "get-task-allow"; macOS: "com.apple.security.get-task-allow".
        guard let key = text.range(of: "get-task-allow</key>") else { return false }
        return text[key.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("<true/>")
        #endif
        #endif
    }()
}
