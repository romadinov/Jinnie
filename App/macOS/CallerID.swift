import AppKit
import ApplicationServices
import Contacts
import Foundation
import JinnieCore

/// Who is on a messenger call (WhatsApp, Telegram), and whether it's work: the names in the call window (Accessibility)
/// matched against Jinnie's people and the user's Contacts. A call counts as work if any participant is a work contact:
/// in Jinnie's directory with projects, at the owner's organisation or a client company, or with a client email domain.
/// Everything else (including callers that can't be identified) is private, and private calls aren't recorded.
@MainActor
enum CallerID {
    struct Result {
        var names: [String] = []
        /// Work contacts, as Jinnie people (created from Contacts when needed).
        var people: [Person] = []
        var isWork: Bool { !people.isEmpty }
        var label: String { names.first.map { names.count > 1 ? "\($0) +\(names.count - 1)" : $0 } ?? "Unknown caller" }
    }

    // MARK: Permissions

    static var accessibilityAllowed: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt once (System Settings → Privacy & Security → Accessibility).
    static func requestAccessibility() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    static var contactsAllowed: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }

    static func requestContacts() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    // MARK: Identify

    static func identify(pid: pid_t) -> Result {
        let strings = windowStrings(pid: pid)
        var result = Result()
        let store = AppModel.shared.store
        let dir = Directory(store: store)
        let me = OwnerProfile.current
        let contacts = contactsAllowed ? loadContacts() : []
        for s in strings {
            let text = s.trimmingCharacters(in: .whitespacesAndNewlines)
            guard text.count >= 3, text.count <= 60, !result.names.contains(text) else { continue }
            // Jinnie's own people first.
            if let p = dir.person(name: text), !p.isMe {
                result.names.append(p.name)
                if isWork(p, me: me, dir: dir) { result.people.append(p) }
                continue
            }
            // Then the address book (WhatsApp shows names as saved on the phone, which iCloud syncs to Contacts).
            guard let c = contacts.first(where: { name(of: $0).caseInsensitiveCompare(text) == .orderedSame
                || (!$0.nickname.isEmpty && $0.nickname.caseInsensitiveCompare(text) == .orderedSame) }) else { continue }
            result.names.append(name(of: c))
            if let p = workPerson(from: c, me: me, dir: dir, store: store) { result.people.append(p) }
        }
        return result
    }

    static func isWork(_ p: Person, me: OwnerProfile, dir: Directory) -> Bool {
        if !p.projectIDs.isEmpty { return true }
        if let org = p.org, !org.isEmpty, !me.organization.isEmpty, org.localizedCaseInsensitiveContains(me.organization) { return true }
        return p.emails.contains { e in dir.project(forEmail: e) != nil || sameDomain(e, me.emails) }
    }

    /// A Contacts card that is a work contact becomes (or matches) a Jinnie person.
    static func workPerson(from c: CNContact, me: OwnerProfile, dir: Directory, store: Store) -> Person? {
        let emails = c.emailAddresses.map { ($0.value as String).lowercased() }
        let org = c.organizationName
        let clientProject = emails.compactMap { dir.project(forEmail: $0) }.first
            ?? (org.isEmpty ? nil : dir.project(named: org))
        let colleague = (!org.isEmpty && !me.organization.isEmpty && org.localizedCaseInsensitiveContains(me.organization))
            || emails.contains { sameDomain($0, me.emails) }
        guard clientProject != nil || colleague else { return nil }
        if let existing = emails.lazy.compactMap({ dir.person(email: $0) }).first ?? dir.person(name: name(of: c)) { return existing }
        var p = Person(name: name(of: c))
        p.emails = emails
        p.org = org.isEmpty ? (colleague ? me.organization : nil) : org
        if let clientProject { p.projectIDs = [clientProject.id] }
        if !c.nickname.isEmpty { p.aliases = [c.nickname] }
        return store.save(p)
    }

    static func sameDomain(_ email: String, _ mine: [String]) -> Bool {
        let personal: Set<String> = ["gmail.com", "icloud.com", "me.com", "outlook.com", "hotmail.com", "yahoo.com", "proton.me"]
        guard let d = email.split(separator: "@").last.map(String.init), !personal.contains(d) else { return false }
        return mine.contains { $0.hasSuffix("@" + d) }
    }

    static func name(of c: CNContact) -> String {
        [c.givenName, c.familyName].filter { !$0.isEmpty }.joined(separator: " ").nilIfEmpty ?? c.organizationName
    }

    private static var cachedContacts: (at: Date, list: [CNContact])?

    static func loadContacts() -> [CNContact] {
        if let c = cachedContacts, Date().timeIntervalSince(c.at) < 600 { return c.list }
        let keys = [CNContactGivenNameKey, CNContactFamilyNameKey, CNContactNicknameKey, CNContactOrganizationNameKey,
                    CNContactEmailAddressesKey] as [CNKeyDescriptor]
        var out: [CNContact] = []
        try? CNContactStore().enumerateContacts(with: CNContactFetchRequest(keysToFetch: keys)) { c, _ in out.append(c) }
        cachedContacts = (Date(), out)
        return out
    }

    /// Every bit of text in the app's windows (titles, labels), a few levels deep: the call window shows the caller's or
    /// group's name. Empty without the Accessibility permission.
    static func windowStrings(pid: pid_t) -> [String] {
        guard accessibilityAllowed else { return [] }
        let app = AXUIElementCreateApplication(pid)
        var windows: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXWindowsAttribute as CFString, &windows) == .success,
              let list = windows as? [AXUIElement] else { return [] }
        var out: [String] = []
        func visit(_ e: AXUIElement, depth: Int) {
            guard depth < 7, out.count < 200 else { return }
            for attr in [kAXTitleAttribute, kAXValueAttribute, kAXDescriptionAttribute] {
                var v: CFTypeRef?
                if AXUIElementCopyAttributeValue(e, attr as CFString, &v) == .success, let s = v as? String, !s.isEmpty { out.append(s) }
            }
            var children: CFTypeRef?
            if AXUIElementCopyAttributeValue(e, kAXChildrenAttribute as CFString, &children) == .success, let kids = children as? [AXUIElement] {
                for k in kids.prefix(40) { visit(k, depth: depth + 1) }
            }
        }
        for w in list.prefix(6) { visit(w, depth: 0) }
        return out
    }
}
