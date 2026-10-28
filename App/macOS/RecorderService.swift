import AppKit
import Foundation
import ServiceManagement

/// Keeps Jinnie Recorder registered with launchd (a LaunchAgent in Contents/Library/LaunchAgents): it starts at login,
/// and again if it crashes, independently of Jinnie. macOS asks the user once to allow it (Login Items).
@MainActor
enum RecorderService {
    static var service: SMAppService { SMAppService.agent(plistName: RecorderLink.agentPlist) }

    static var isRunning: Bool { !NSRunningApplication.runningApplications(withBundleIdentifier: RecorderLink.recorderBundleID).isEmpty }

    /// Registers the agent (first launch, or after the user turned it back on); starts it if it isn't running.
    static func ensure() {
        let s = service
        if s.status != .enabled {
            do { try s.register() } catch { NSLog("Jinnie: couldn't register Jinnie Recorder: %@", error.localizedDescription) }
        }
        if s.status == .enabled, !isRunning { kickstart() }
    }

    /// Starts the agent now (after "Quit Recorder", which launchd doesn't undo until the next login).
    static func kickstart() {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        p.arguments = ["kickstart", "gui/\(getuid())/\(RecorderLink.agentLabel)"]
        try? p.run()
    }

    static var statusText: String {
        switch service.status {
        case .enabled: isRunning ? "Running" : "Allowed, not running"
        case .requiresApproval: "Needs your approval in System Settings → General → Login Items"
        case .notRegistered: "Not set up"
        case .notFound: "Not found in this copy of Jinnie"
        @unknown default: "Unknown"
        }
    }
}
