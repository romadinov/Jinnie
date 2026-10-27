import Contacts
import Foundation
import JinnieCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// Opens a new email, filled in, in Mimestream (or the default mail app). Jinnie never sends anything itself.
enum MailComposer {
    static let mimestream = "com.mimestream.Mimestream"

    /// mailto: with every part percent-encoded (RFC 6068): line breaks as CRLF, nothing but unreserved characters left bare.
    static func mailtoURL(to: [String], cc: [String] = [], subject: String, body: String) -> URL? {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: unreserved) ?? "" }
        let addressChars = unreserved.union(CharacterSet(charactersIn: "@+"))
        let toPart = to.map { $0.addingPercentEncoding(withAllowedCharacters: addressChars) ?? $0 }.joined(separator: ",")
        var query = ["subject=" + enc(subject), "body=" + enc(body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n"))]
        if !cc.isEmpty { query.insert("cc=" + cc.map(enc).joined(separator: ","), at: 0) }
        return URL(string: "mailto:\(toPart)?\(query.joined(separator: "&"))")
    }

    #if os(macOS)
    static var mimestreamURL: URL? { NSWorkspace.shared.urlForApplication(withBundleIdentifier: mimestream) }
    static var appName: String { mimestreamURL == nil ? "Mail" : "Mimestream" }
    #else
    static var appName: String { "Mail" }
    #endif

    static func compose(to: [String], subject: String, body: String) {
        guard let url = mailtoURL(to: to, subject: subject, body: body) else { return }
        #if os(macOS)
        if let app = mimestreamURL {
            NSWorkspace.shared.open([url], withApplicationAt: app, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
        #else
        UIApplication.shared.open(url)
        #endif
    }
}

/// The owner's Contacts (read, and "Add to Contacts" on request): emails, organisation and job title for Jinnie's people.
/// Jinnie only fills blanks from Contacts; it never overwrites what it knows.
enum ContactsBridge {
    static var allowed: Bool { CNContactStore.authorizationStatus(for: .contacts) == .authorized }

    static func requestAccess() async -> Bool {
        (try? await CNContactStore().requestAccess(for: .contacts)) ?? false
    }

    static let keys: [CNKeyDescriptor] = [
        CNContactIdentifierKey as CNKeyDescriptor, CNContactGivenNameKey as CNKeyDescriptor, CNContactFamilyNameKey as CNKeyDescriptor,
        CNContactEmailAddressesKey as CNKeyDescriptor, CNContactOrganizationNameKey as CNKeyDescriptor,
        CNContactJobTitleKey as CNKeyDescriptor, CNContactFormatter.descriptorForRequiredKeys(for: .fullName),
    ]

    /// The contact for a person: by any of their emails, else by full name when exactly one contact has it.
    static func contact(for p: Person) -> CNContact? {
        guard allowed else { return nil }
        let store = CNContactStore()
        for e in p.emails {
            if let c = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingEmailAddress: e), keysToFetch: keys).first {
                return c
            }
        }
        let norm = Directory.norm(p.name)
        guard norm.contains(" "),
              let hits = try? store.unifiedContacts(matching: CNContact.predicateForContacts(matchingName: p.name), keysToFetch: keys)
        else { return nil }
        let exact = hits.filter { Directory.norm(CNContactFormatter.string(from: $0, style: .fullName) ?? "") == norm }
        return exact.count == 1 ? exact[0] : nil
    }

    /// The person with blanks filled from Contacts, or nil when Contacts adds nothing.
    static func enriched(_ p: Person) -> Person? {
        guard let c = contact(for: p) else { return nil }
        var q = p
        let known = Set(p.emails.map { $0.lowercased() })
        for e in c.emailAddresses.map({ ($0.value as String).trimmingCharacters(in: .whitespaces) }) where !e.isEmpty && !known.contains(e.lowercased()) {
            q.emails.append(e)
        }
        if (q.org ?? "").isEmpty, !c.organizationName.isEmpty { q.org = c.organizationName }
        if (q.role ?? "").isEmpty, !c.jobTitle.isEmpty { q.role = c.jobTitle }
        return q == p ? nil : q
    }

    /// Fills blanks for everyone Jinnie knows. Returns how many people changed.
    @discardableResult
    static func enrichAll(_ store: Store) -> Int {
        guard allowed else { return 0 }
        var n = 0
        for p in store.all(Person.self) where !p.isMe {
            if let q = enriched(p) { store.save(q); n += 1 }
        }
        return n
    }

    /// A new contact from what Jinnie knows (name, emails, organisation, job title).
    static func add(_ p: Person) throws {
        let c = CNMutableContact()
        let parts = p.name.split(separator: " ", maxSplits: 1).map(String.init)
        c.givenName = parts.first ?? p.name
        if parts.count > 1 { c.familyName = parts[1] }
        c.emailAddresses = p.emails.map { CNLabeledValue(label: CNLabelWork, value: $0 as NSString) }
        if let org = p.org { c.organizationName = org }
        if let role = p.role { c.jobTitle = role }
        let req = CNSaveRequest()
        req.add(c, toContainerWithIdentifier: nil)
        try CNContactStore().execute(req)
    }

    #if os(macOS)
    static func open(_ c: CNContact) {
        if let url = URL(string: "addressbook://\(c.identifier)") { NSWorkspace.shared.open(url) }
    }
    #endif
}
