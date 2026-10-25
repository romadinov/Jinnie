import Foundation
import Security

public enum JinnieConfig {
    public static let cloudContainer = "iCloud.com.romadinov.jinnie"
    public static let appGroup = "group.com.romadinov.jinnie"
    /// Posted (Darwin notification) by the CLI / MCP server / extensions after writing to the database.
    public static let externalChangeNotification = "com.romadinov.jinnie.external-change"

    /// The user this agent works for (set up on first launch). Prompts use it to tell "my" actions from other people's.
    public static var ownerName: String { OwnerProfile.current.name }
    public static var ownerEmails: [String] { OwnerProfile.current.emails }

    /// Uberdoer folder new work projects are created in.
    public static var uberdoerWorkFolder: String { OwnerProfile.current.uberdoerFolder }
    public static let uberdoerTag = "Jinnie"
    public static let uberdoerWaitingTag = "Waiting"

    public static var cloudEnvironment: String {
        #if DEBUG
        return "Development"
        #else
        return "Production"
        #endif
    }

    /// macOS: ~/Library/Application Support/Jinnie. iOS: the app group container.
    public static func supportDirectory() -> URL {
        if let override = ProcessInfo.processInfo.environment["JINNIE_HOME"] { return URL(fileURLWithPath: override) }
        #if os(iOS)
        if let group = FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) {
            return group.appendingPathComponent("Jinnie")
        }
        #endif
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return base.appendingPathComponent("Jinnie")
    }

    public static func databaseURL() -> URL {
        supportDirectory().appendingPathComponent("jinnie.sqlite")
    }

    /// CKContainer traps when the iCloud entitlement is missing (unsigned builds, the CLI),
    /// so sync only starts when the binary is actually entitled.
    public static var cloudKitAvailable: Bool {
        // A scratch database (JINNIE_HOME) never syncs: it must not reach the user's iCloud.
        let env = ProcessInfo.processInfo.environment
        if env["JINNIE_NO_SYNC"] != nil || env["JINNIE_HOME"] != nil { return false }
        #if os(macOS)
        guard let task = SecTaskCreateFromSelf(nil) else { return false }
        return SecTaskCopyValueForEntitlement(task, "com.apple.developer.icloud-services" as CFString, nil) != nil
        #else
        return FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup) != nil
        #endif
    }

    public static func postExternalChange() {
        CFNotificationCenterPostNotification(CFNotificationCenterGetDarwinNotifyCenter(),
                                             CFNotificationName(externalChangeNotification as CFString), nil, nil, true)
    }

    public static func observeExternalChanges(_ handler: @escaping () -> Void) {
        ExternalChangeObserver.shared.handler = handler
        CFNotificationCenterAddObserver(CFNotificationCenterGetDarwinNotifyCenter(), nil, { _, _, _, _, _ in
            DispatchQueue.main.async { ExternalChangeObserver.shared.handler?() }
        }, externalChangeNotification as CFString, nil, .deliverImmediately)
    }
}

final class ExternalChangeObserver: @unchecked Sendable {
    static let shared = ExternalChangeObserver()
    var handler: (() -> Void)?
}
