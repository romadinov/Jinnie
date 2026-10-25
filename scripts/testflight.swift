#!/usr/bin/env swift
// TestFlight automation for Jinnie's iPhone app through the App Store Connect API.
//
//   export ASC_KEY_PATH=~/path/AuthKey_XXXX.p8 ASC_KEY_ID=XXXX ASC_ISSUER_ID=<uuid>   # key with Admin access
//   swift scripts/testflight.swift setup                     # checks the app record, creates the internal group
//   swift scripts/testflight.swift invite a@b.com "First Last" [more emails…]   # invites colleagues (internal testers)
//   swift scripts/testflight.swift sync                      # adds everyone who accepted to the group
//   swift scripts/testflight.swift status                    # latest builds, group members, pending invitations
//
// Internal testers are members of your App Store Connect team (any role; "Developer" with access to Jinnie only is
// enough). They get every build minutes after processing, with no Beta App Review. Apple's API can't create the app
// record itself: `setup` says exactly what to click once.
import CryptoKit
import Foundation

let bundleID = "com.romadinov.jinnie"
let groupName = "Jinnie testers"

// MARK: Auth (ES256 JWT, 20 minutes)

func env(_ k: String) -> String {
    guard let v = ProcessInfo.processInfo.environment[k], !v.isEmpty else {
        print("Set \(k) (see the top of this script)."); exit(1)
    }
    return v
}

func base64url(_ d: Data) -> String {
    d.base64EncodedString().replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
}

func token() -> String {
    let pem = (try? String(contentsOfFile: (env("ASC_KEY_PATH") as NSString).expandingTildeInPath, encoding: .utf8)) ?? ""
    guard let key = try? P256.Signing.PrivateKey(pemRepresentation: pem) else { print("Can't read the .p8 key at ASC_KEY_PATH"); exit(1) }
    let header = ["alg": "ES256", "kid": env("ASC_KEY_ID"), "typ": "JWT"]
    let now = Int(Date().timeIntervalSince1970)
    let claims: [String: Any] = ["iss": env("ASC_ISSUER_ID"), "iat": now, "exp": now + 1200, "aud": "appstoreconnect-v1"]
    let h = base64url(try! JSONSerialization.data(withJSONObject: header))
    let c = base64url(try! JSONSerialization.data(withJSONObject: claims))
    let sig = try! key.signature(for: Data("\(h).\(c)".utf8))
    return "\(h).\(c).\(base64url(sig.rawRepresentation))"
}

let jwt = token()

@discardableResult
func api(_ method: String, _ path: String, _ body: [String: Any]? = nil) -> [String: Any] {
    var req = URLRequest(url: URL(string: "https://api.appstoreconnect.apple.com" + path)!)
    req.httpMethod = method
    req.setValue("Bearer \(jwt)", forHTTPHeaderField: "Authorization")
    if let body {
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try! JSONSerialization.data(withJSONObject: body)
    }
    let sem = DispatchSemaphore(value: 0)
    var out: [String: Any] = [:]
    URLSession.shared.dataTask(with: req) { data, resp, _ in
        let status = (resp as? HTTPURLResponse)?.statusCode ?? 0
        out = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        out["_status"] = status
        sem.signal()
    }.resume()
    sem.wait()
    if let errors = out["errors"] as? [[String: Any]] {
        out["_error"] = errors.map { "\($0["title"] ?? ""): \($0["detail"] ?? "")" }.joined(separator: "; ")
    }
    return out
}

func data(_ r: [String: Any]) -> [[String: Any]] { r["data"] as? [[String: Any]] ?? [] }
func attr(_ o: [String: Any], _ k: String) -> Any? { (o["attributes"] as? [String: Any])?[k] }

// MARK: Steps

func app() -> [String: Any]? {
    data(api("GET", "/v1/apps?filter[bundleId]=\(bundleID)")).first { attr($0, "bundleId") as? String == bundleID }
}

func requireApp() -> String {
    guard let a = app(), let id = a["id"] as? String else {
        print("""
        ✗ No App Store Connect app record for \(bundleID) yet. Apple's API can't create one, so once, by hand (2 minutes):
          1. Open https://appstoreconnect.apple.com/apps → + → New App
          2. Platform: iOS · Name: Jinnie (if taken, e.g. "Jinnie Notes") · Language: English
             Bundle ID: \(bundleID) · SKU: jinnie · User Access: Full Access → Create
          3. Run `swift scripts/testflight.swift setup` again.
        """)
        exit(1)
    }
    return id
}

func group(_ appID: String) -> String {
    let groups = data(api("GET", "/v1/apps/\(appID)/betaGroups?limit=50"))
    if let g = groups.first(where: { attr($0, "name") as? String == groupName }), let id = g["id"] as? String { return id }
    let r = api("POST", "/v1/betaGroups", ["data": ["type": "betaGroups",
        "attributes": ["name": groupName, "isInternalGroup": true, "hasAccessToAllBuilds": true],
        "relationships": ["app": ["data": ["type": "apps", "id": appID]]]]])
    guard let id = (r["data"] as? [String: Any])?["id"] as? String else { print("Couldn't create the group: \(r["_error"] ?? r)"); exit(1) }
    print("✓ Created internal group \"\(groupName)\" (every new build is available to it automatically)")
    return id
}

func users() -> [[String: Any]] { data(api("GET", "/v1/users?limit=200")) }

/// Adds every team member who isn't in the group yet (internal testers must be team members).
func sync(_ appID: String, _ groupID: String, only emails: Set<String>? = nil) {
    let inGroup = Set(data(api("GET", "/v1/betaGroups/\(groupID)/betaTesters?limit=200")).compactMap { (attr($0, "email") as? String)?.lowercased() })
    var added = 0
    for u in users() {
        guard let email = (attr(u, "username") as? String)?.lowercased(), !inGroup.contains(email) else { continue }
        if let emails, !emails.contains(email) { continue }
        let r = api("POST", "/v1/betaTesters", ["data": ["type": "betaTesters",
            "attributes": ["email": email, "firstName": attr(u, "firstName") ?? "", "lastName": attr(u, "lastName") ?? ""],
            "relationships": ["betaGroups": ["data": [["type": "betaGroups", "id": groupID]]]]]])
        if let e = r["_error"] { print("  ! \(email): \(e)") } else { print("✓ \(email) added to \(groupName): TestFlight emails them"); added += 1 }
    }
    if added == 0 { print("Everyone who accepted is already in \(groupName).") }
}

/// The Developer ID provisioning profile the Mac app needs (iCloud entitlements). Xcode only makes it when you export by
/// hand; with an API key, xcodebuild can't, so this creates it (or reuses it) and installs it for manual signing.
func macProfile() {
    let macID = "com.romadinov.jinnie.mac", profileName = "Jinnie Mac Developer ID"
    guard let bundle = data(api("GET", "/v1/bundleIds?filter[identifier]=\(macID)&limit=20")).first(where: { attr($0, "identifier") as? String == macID }),
          let bundleRef = bundle["id"] as? String else { print("✗ No bundle ID \(macID) in your developer account"); exit(1) }
    let certs = data(api("GET", "/v1/certificates?filter[certificateType]=DEVELOPER_ID_APPLICATION,DEVELOPER_ID_APPLICATION_G2&limit=50"))
    // The certificate whose private key is on this Mac (matched by serial number).
    let p = Process(); p.executableURL = URL(fileURLWithPath: "/bin/sh")
    p.arguments = ["-c", "security find-certificate -c 'Developer ID Application' -p | openssl x509 -noout -serial | cut -d= -f2"]
    let pipe = Pipe(); p.standardOutput = pipe; try! p.run(); p.waitUntilExit()
    let serial = String(decoding: pipe.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
    guard let cert = certs.first(where: { (attr($0, "serialNumber") as? String)?.uppercased() == serial }), let certRef = cert["id"] as? String else {
        print("✗ The Developer ID certificate on this Mac (serial \(serial)) isn't in the account"); exit(1)
    }
    var profile = data(api("GET", "/v1/profiles?limit=200"))
        .first { attr($0, "profileState") as? String == "ACTIVE" && attr($0, "name") as? String == profileName }
    if profile == nil {
        let r = api("POST", "/v1/profiles", ["data": ["type": "profiles", "attributes": ["name": profileName, "profileType": "MAC_APP_DIRECT"],
            "relationships": ["bundleId": ["data": ["type": "bundleIds", "id": bundleRef]],
                              "certificates": ["data": [["type": "certificates", "id": certRef]]]]]])
        guard let d = r["data"] as? [String: Any] else { print("✗ Couldn't create the profile: \(r["_error"] ?? r)"); exit(1) }
        profile = d
        print("✓ Created the provisioning profile \"\(profileName)\"")
    }
    guard let content = profile.flatMap({ attr($0, "profileContent") as? String }).flatMap({ Data(base64Encoded: $0) }),
          let uuid = profile.flatMap({ attr($0, "uuid") as? String }) else { print("✗ Profile has no content"); exit(1) }
    let home = FileManager.default.homeDirectoryForCurrentUser
    for dir in ["Library/Developer/Xcode/UserData/Provisioning Profiles", "Library/MobileDevice/Provisioning Profiles"] {
        let url = home.appendingPathComponent(dir)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        try! content.write(to: url.appendingPathComponent("\(uuid).provisionprofile"))
    }
    print("✓ Installed \"\(profileName)\" (\(uuid))")
}

let args = Array(CommandLine.arguments.dropFirst())
switch args.first ?? "status" {
case "setup":
    let appID = requireApp()
    print("✓ App record found (\(appID))")
    let g = group(appID)
    sync(appID, g)
    print("Next: scripts/release-iphone.sh uploads a build; invite colleagues with `invite`.")
case "invite":
    let appID = requireApp()
    let g = group(appID)
    var rest = Array(args.dropFirst())
    var emails = Set<String>()
    while let email = rest.first {
        rest.removeFirst()
        var name = ""
        if let next = rest.first, !next.contains("@") { name = next; rest.removeFirst() }
        let parts = name.split(separator: " ").map(String.init)
        emails.insert(email.lowercased())
        if users().contains(where: { (attr($0, "username") as? String)?.lowercased() == email.lowercased() }) { continue }
        let r = api("POST", "/v1/userInvitations", ["data": ["type": "userInvitations", "attributes": [
            "email": email, "firstName": parts.first ?? email.components(separatedBy: "@")[0], "lastName": parts.dropFirst().joined(separator: " ").isEmpty ? "-" : parts.dropFirst().joined(separator: " "),
            "roles": ["DEVELOPER"], "allAppsVisible": false, "provisioningAllowed": false],
            "relationships": ["visibleApps": ["data": [["type": "apps", "id": appID]]]]]])
        if let e = r["_error"] { print("  ! \(email): \(e)") } else { print("✓ Invited \(email) to your App Store Connect team (Developer, Jinnie only). They accept the email, then run `sync`.") }
    }
    sync(appID, g, only: emails)
case "sync":
    let appID = requireApp()
    sync(appID, group(appID))
case "mac-profile":
    macProfile()
case "profiles":
    for p in data(api("GET", "/v1/profiles?limit=200")) { print("\(attr(p, "name") ?? "")  \(attr(p, "profileType") ?? "")  \(attr(p, "profileState") ?? "")") }
case "apps":
    for a in data(api("GET", "/v1/apps?limit=200")) { print("\(attr(a, "bundleId") ?? "?")  \(attr(a, "name") ?? "")") }
case "status":
    let appID = requireApp()
    print("Builds:")
    for b in data(api("GET", "/v1/builds?filter[app]=\(appID)&sort=-uploadedDate&limit=5")) {
        print("  \(attr(b, "version") ?? "?")  \(attr(b, "processingState") ?? "")  uploaded \(attr(b, "uploadedDate") ?? "")\(attr(b, "expired") as? Bool == true ? "  (expired)" : "")")
    }
    let groups = data(api("GET", "/v1/apps/\(appID)/betaGroups?limit=50"))
    for g in groups {
        guard let id = g["id"] as? String else { continue }
        let testers = data(api("GET", "/v1/betaGroups/\(id)/betaTesters?limit=200")).compactMap { attr($0, "email") as? String }
        print("Group \(attr(g, "name") ?? ""): \(testers.isEmpty ? "no testers" : testers.joined(separator: ", "))")
    }
    let pending = data(api("GET", "/v1/userInvitations?limit=100")).compactMap { attr($0, "email") as? String }
    if !pending.isEmpty { print("Invited, not accepted yet: \(pending.joined(separator: ", "))") }
default:
    print("Commands: setup | apps | mac-profile | invite <email> [\"First Last\"]… | sync | status")
}
