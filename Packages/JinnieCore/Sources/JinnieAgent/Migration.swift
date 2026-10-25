import Foundation
import JinnieCore

extension Agent {
    /// Installs from before the setup assistant: derive the owner profile from the "me" person and keep the optional
    /// integrations that were already working switched on. Runs once; harmless on new installs.
    public func migrateIfNeeded() {
        guard store.meta("migrated.v2") == nil else { return }
        defer { store.setMeta("migrated.v2", "1") }
        if !OwnerProfile.exists, let me = store.all(Person.self).first(where: \.isMe), !me.emails.isEmpty {
            var p = OwnerProfile()
            p.name = me.name
            p.emails = me.emails
            p.organization = me.org ?? ""
            p.nicknames = me.aliases
            // The Uberdoer folder earlier builds filed work projects in ("Folder : Project").
            let folders = store.all(Project.self).compactMap { $0.uberdoerPath?.components(separatedBy: " : ").first }
            p.uberdoerFolder = Dictionary(grouping: folders, by: { $0 }).max { $0.value.count < $1.value.count }?.key ?? "Work"
            try? p.save()
            log("Owner profile created from the existing directory: \(p.name)")
        }
        if store.meta("enabled.remarkable") == nil, RemarkableReader() != nil, RemarkableReader.isSignedIn {
            store.setMeta("enabled.remarkable", "1")
        }
        if store.meta("enabled.outlook") == nil, lastRun(.outlook) != nil || store.meta("cursor.outlook") != nil {
            store.setMeta("enabled.outlook", "1")
        }
    }
}
