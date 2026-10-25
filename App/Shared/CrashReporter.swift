import Foundation
import JinnieCore
import MetricKit
import os

private let log = Logger(subsystem: "com.romadinov.jinnie", category: "Diagnostics")

/// Saves crash, hang and resource reports from MetricKit to iCloud Drive › Jinnie › Crash reports (one JSON per
/// report), where the agent-feedback tool picks them up for the Claude session that owns this repo. MetricKit delivers
/// a report on the launch after the problem. Same as Scriptorium's.
final class CrashReporter: NSObject, MXMetricManagerSubscriber, @unchecked Sendable {
    static let shared = CrashReporter()
    private var device = "Device"

    /// Only in the developer's own (development-signed) builds; TestFlight and App Store builds collect nothing.
    @MainActor func start() {
        guard DeveloperBuild.isDeveloper else { return }
        device = AppModel.shared.deviceName
        MXMetricManager.shared.add(self)
        let past = MXMetricManager.shared.pastDiagnosticPayloads
        if !past.isEmpty { save(past) }
    }

    func didReceive(_ payloads: [MXDiagnosticPayload]) { save(payloads) }

    private func save(_ payloads: [MXDiagnosticPayload]) {
        let device = device
        Task.detached(priority: .utility) {
            let folder = Feedback.crashFolder
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.dateFormat = "yyyy-MM-dd HHmmss"
            for payload in payloads {
                let crashes = payload.crashDiagnostics?.count ?? 0
                let hangs = payload.hangDiagnostics?.count ?? 0
                let other = (payload.cpuExceptionDiagnostics?.count ?? 0) + (payload.diskWriteExceptionDiagnostics?.count ?? 0)
                guard crashes + hangs + other > 0 else { continue }
                let kind = crashes > 0 ? "Crash" : (hangs > 0 ? "Hang" : "Resource")
                let name = "\(kind) \(f.string(from: payload.timeStampEnd)) \(device) build \(build).json".replacingOccurrences(of: "/", with: "-")
                let url = folder.appendingPathComponent(name)
                guard !FileManager.default.fileExists(atPath: url.path) else { continue }
                var error: NSError?
                NSFileCoordinator().coordinate(writingItemAt: url, options: .forReplacing, error: &error) { target in
                    try? payload.jsonRepresentation().write(to: target, options: .atomic)
                }
                log.info("Saved diagnostic report \(name, privacy: .public)")
            }
        }
    }
}
