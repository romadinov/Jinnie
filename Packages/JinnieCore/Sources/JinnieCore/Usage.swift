import Foundation

/// What Jinnie spends, per day and kind of work. Runs are billed to the Claude subscription; the dollars are the
/// API-equivalent price `claude` reports, a fair measure of how much of the plan's limits Jinnie uses.
/// Kept as one synced RunLog per day (kind "usage", id "usage-YYYY-MM-DD") so the iPhone's Activity shows it too.
public enum Usage {
    private static let lock = NSLock()

    /// "ingest-email" → "Reading sources", "brief-Acme" → "Project briefs"…
    public static func kind(of label: String) -> String {
        let head = label.split(separator: "-").first.map(String.init) ?? label
        switch head {
        case "ingest", "notes", "learn": return "Reading sources"
        case "scan": return "History scans"
        case "summary": return "Summaries"
        case "brief": return "Project briefs"
        case "ask": return "Ask"
        case "clarify": return "Open questions"
        case "enrich": return "Task context"
        case "remarkable": return "reMarkable"
        case "recording": return "Recordings"
        case "tools": return "Connector checks"
        default: return "Other"
        }
    }

    public static func record(label: String, cost: Double, store: Store, date: Date = Date()) {
        guard cost > 0 else { return }
        lock.withLock {
            let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd"; f.timeZone = .current
            let day = f.string(from: date)
            let id = "usage-\(day)"
            var log = store.get(RunLog.self, id) ?? {
                var r = RunLog(kind: "usage"); r.id = id; r.startedAt = Calendar.current.startOfDay(for: date); return r
            }()
            var parts = breakdown(log.message)
            parts[kind(of: label), default: 0] += cost
            log.message = format(parts)
            log.finishedAt = Date()
            log.ok = true
            store.save(log)
        }
    }

    /// "Reading sources $3.10 · Ask $0.80" ⇄ ["Reading sources": 3.10, "Ask": 0.80]
    public static func breakdown(_ message: String) -> [String: Double] {
        var out: [String: Double] = [:]
        for part in message.components(separatedBy: " · ") {
            guard let r = part.range(of: " $", options: .backwards), let v = Double(part[r.upperBound...]) else { continue }
            out[String(part[..<r.lowerBound])] = v
        }
        return out
    }

    public static func format(_ parts: [String: Double]) -> String {
        parts.sorted { $0.value > $1.value }.map { "\($0.key) $\(String(format: "%.2f", $0.value))" }.joined(separator: " · ")
    }

    public static func total(_ message: String) -> Double { breakdown(message).values.reduce(0, +) }
}
