import Foundation
import JinnieCore

/// What Jinnie needs on this Mac, checked and explained: used by the setup assistant and `jinniectl doctor`.
public struct SetupCheck: Identifiable, Sendable {
    public enum Level: String, Sendable { case required, recommended, optional }
    public enum Status: Sendable, Equatable { case ok, missing, warning, unknown }

    public var id: String
    public var title: String
    public var level: Level
    public var status: Status
    /// What was found ("Signed in with a Max subscription", "Not installed").
    public var detail: String
    /// How to fix it, step by step.
    public var steps: [Step] = []

    public init(id: String, title: String, level: Level, status: Status, detail: String, steps: [Step] = []) {
        self.id = id; self.title = title; self.level = level; self.status = status; self.detail = detail; self.steps = steps
    }

    public struct Step: Sendable, Hashable {
        public var text: String
        /// A command to run in Terminal (copyable).
        public var command: String?
        /// A page to open.
        public var url: String?
        public init(_ text: String, command: String? = nil, url: String? = nil) { self.text = text; self.command = command; self.url = url }
    }
}

public enum Setup {
    public static let connectorsURL = "https://claude.ai/settings/connectors"

    // MARK: Required

    public static func profile() -> SetupCheck {
        let p = OwnerProfile.current
        return SetupCheck(id: "profile", title: "About you", level: .required, status: p.isComplete ? .ok : .missing,
                          detail: p.isComplete ? "\(p.name) · \(p.emails.joined(separator: ", "))" : "Jinnie needs your name and email addresses",
                          steps: p.isComplete ? [] : [.init("Fill in your name, every address you send email from, your role and the languages you write in.")])
    }

    /// Claude Code installed and signed in with a subscription (Jinnie runs `claude -p`, billed to the subscription).
    public static func claude() -> SetupCheck {
        var c = SetupCheck(id: "claude", title: "Claude Code", level: .required, status: .missing, detail: "")
        guard let exe = Claude.locate() else {
            c.detail = "Not installed"
            c.steps = [.init("Install Claude Code (needs a Claude Pro, Max, Team or Enterprise plan):", command: "curl -fsSL https://claude.ai/install.sh | bash",
                             url: "https://code.claude.com/docs/en/setup"),
                       .init("Then sign in:", command: "claude auth login")]
            return c
        }
        let out = run(exe, ["auth", "status", "--json"])
        guard let data = out.data(using: .utf8), let start = out.firstIndex(of: "{"),
              let json = (try? JSONSerialization.jsonObject(with: Data(out[start...].utf8))) as? [String: Any] ?? (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else {
            c.status = .warning
            c.detail = "Installed, but its sign-in status couldn't be read"
            c.steps = [.init("Check it in Terminal:", command: "claude auth status")]
            return c
        }
        guard json["loggedIn"] as? Bool == true else {
            c.detail = "Installed, not signed in"
            c.steps = [.init("Sign in with your Claude account:", command: "claude auth login")]
            return c
        }
        let method = json["authMethod"] as? String ?? ""
        let plan = json["subscriptionType"] as? String
        if method == "claude.ai" {
            c.status = .ok
            c.detail = "Signed in\(plan.map { " · \($0.capitalized) plan" } ?? "")"
        } else {
            c.status = .warning
            c.detail = "Signed in with \(method): runs may be billed per use, and claude.ai connectors (Gmail, Slack…) are only available with a Claude account"
            c.steps = [.init("Sign in with your Claude subscription instead:", command: "claude auth login")]
        }
        return c
    }

    // MARK: Connectors (claude.ai)

    /// Gmail, Calendar, Slack and Drive come from the user's claude.ai connectors. Checking asks Claude which tools it can
    /// load (one short run per source, cached for a day), so this is done on request.
    public static func connectors(_ agent: Agent, refresh: Bool) async -> [SetupCheck] {
        let specs: [(Source, String, SetupCheck.Level, String)] = [
            (.email, "Gmail", .recommended, "Mail is where most commitments and project history are."),
            (.calendar, "Google Calendar", .recommended, "Meetings, attendees and agendas; recordings are matched to them."),
            (.slack, "Slack", .optional, "Direct messages, mentions and project channels."),
            (.drive, "Google Drive", .optional, "Meeting transcripts, Gemini notes and shared documents."),
        ]
        var out: [SetupCheck] = []
        for (source, name, level, why) in specs {
            var c = SetupCheck(id: "connector.\(source.rawValue)", title: name, level: level, status: .unknown, detail: why)
            if !agent.isEnabled(source) {
                c.status = .ok
                c.detail = "Turned off in Jinnie"
            } else if let tools = try? await agent.tools(for: source, refresh: refresh) {
                c.status = tools.isEmpty ? .missing : .ok
                c.detail = tools.isEmpty
                    ? (agent.needsSignIn(source) ? "Added in claude.ai, but signed out or access expired. \(why)" : "Not connected in claude.ai. \(why)")
                    : "Connected (\(tools.count) read-only tools)"
            } else {
                c.status = .warning
                c.detail = "Couldn't check (is Claude Code signed in?)"
            }
            if c.status == .missing {
                c.steps = [.init("Open claude.ai → Settings → Connectors, connect \(name) with the account you use for work, and allow access.", url: connectorsURL),
                           .init("Then check again here. Jinnie only ever uses the connector's read tools.")]
            }
            out.append(c)
        }
        return out
    }

    // MARK: Optional integrations

    public static func uberdoer() -> SetupCheck {
        let ok = Uberdoer.isInstalled
        return SetupCheck(id: "uberdoer", title: "Uberdoer", level: .optional, status: ok ? .ok : .missing,
                          detail: ok ? "Next actions and waiting-fors sync both ways" : "Not installed: actions stay in Jinnie (that's fine)",
                          steps: ok ? [] : [.init("Only if you use Uberdoer: install it in /Applications. Jinnie finds it automatically.")])
    }

    public static func outlook(_ agent: Agent) -> SetupCheck {
        var c = SetupCheck(id: "outlook", title: "Outlook on the web (client Microsoft 365)", level: .optional, status: .ok, detail: "")
        let enabled = agent.isEnabled(.outlook)
        if !OutlookReader.isInstalled {
            c.status = enabled ? .missing : .ok
            c.detail = enabled ? "Turned on, but agent-browser isn't installed" : "Off. For a client mailbox you can't connect to claude.ai (e.g. a customer's Microsoft 365)."
            c.steps = [.init("Install the browser Jinnie reads it with (needs Node.js):", command: "npm i -g agent-browser && agent-browser install"),
                       .init("Then turn Outlook on and sign in once (Settings → Sources → Sign in to Outlook…).")]
            return c
        }
        if !enabled { c.detail = "Off. Turn it on to read a client's Outlook mailbox and calendar."; return c }
        let failed = agent.store.all(RunLog.self).filter { $0.kind == "ingest:outlook" }.max { $0.startedAt < $1.startedAt }
        if let f = failed, !f.ok {
            c.status = .warning
            c.detail = f.message
            c.steps = [.init("Sign in again and choose \"Stay signed in\":", command: "jinniectl outlook-login")]
        } else {
            c.detail = agent.lastRun(.outlook).map { "Read \($0.formatted(.relative(presentation: .named)))" } ?? "On; not read yet"
        }
        return c
    }

    public static func remarkable(_ agent: Agent) -> SetupCheck {
        var c = SetupCheck(id: "remarkable", title: "reMarkable", level: .optional, status: .ok, detail: "")
        let enabled = agent.isEnabled(.remarkable)
        let missing = RemarkableReader.missing
        if !missing.isEmpty {
            c.status = enabled ? .missing : .ok
            c.detail = enabled ? "Turned on, but \(missing.joined(separator: ", ")) \(missing.count == 1 ? "is" : "are") missing" : "Off. Turn it on to transcribe handwritten notebooks from reMarkable Cloud."
            var steps: [SetupCheck.Step] = []
            if missing.contains("rsvg-convert") { steps.append(.init("Install the page renderer:", command: "brew install librsvg")) }
            if missing.contains("rmc") { steps.append(.init("Install the notebook reader (needs uv):", command: "uv tool install rmc")) }
            if missing.contains("rmapi") {
                steps.append(.init("Install rmapi (the reMarkable Cloud client) from its releases page into ~/.local/bin (macOS zip):",
                                   command: "mkdir -p ~/.local/bin && cd /tmp && curl -LO https://github.com/ddvk/rmapi/releases/latest/download/rmapi-macos-arm64.zip && unzip -o rmapi-macos-arm64.zip && mv rmapi ~/.local/bin/",
                                   url: "https://github.com/ddvk/rmapi/releases"))
            }
            steps.append(.init("Connect it to your account once: run it, then enter the code from my.remarkable.com:", command: "~/.local/bin/rmapi",
                               url: "https://my.remarkable.com/device/desktop/connect"))
            c.steps = steps
            return c
        }
        if !RemarkableReader.isSignedIn {
            c.status = enabled ? .missing : .ok
            c.detail = "Tools installed, not connected to reMarkable Cloud"
            c.steps = [.init("Run it once and enter the code from my.remarkable.com:", command: "~/.local/bin/rmapi", url: "https://my.remarkable.com/device/desktop/connect")]
            return c
        }
        c.detail = enabled ? (agent.lastRun(.remarkable).map { "Read \($0.formatted(.relative(presentation: .named)))" } ?? "On; not read yet") : "Ready. Turn it on to transcribe your notebooks."
        return c
    }

    /// Everything that doesn't need a Claude run (connectors are checked separately, on request).
    public static func quickChecks(_ agent: Agent) -> [SetupCheck] {
        [profile(), claude(), uberdoer(), outlook(agent), remarkable(agent)]
    }

    static func run(_ exe: String, _ args: [String]) -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: exe)
        p.arguments = args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + (env["PATH"] ?? "")
        env.removeValue(forKey: "ANTHROPIC_API_KEY")
        p.environment = env
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return "" }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }
}
