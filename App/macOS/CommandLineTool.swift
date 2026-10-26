import AppKit

/// Puts `jinniectl` on the PATH: a link in /usr/local/bin to the copy inside Jinnie.app, so it follows app updates.
@MainActor
enum CommandLineTool {
    static let link = "/usr/local/bin/jinniectl"
    static var binary: String { Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/jinniectl").path }

    static var isInstalled: Bool {
        (try? FileManager.default.destinationOfSymbolicLink(atPath: link)) == binary
    }

    /// Links without a prompt when /usr/local/bin is writable, otherwise asks for an administrator password.
    static func install() {
        let fm = FileManager.default
        do {
            if fm.isWritableFile(atPath: "/usr/local/bin") {
                try? fm.removeItem(atPath: link)
                try fm.createSymbolicLink(atPath: link, withDestinationPath: binary)
            } else {
                let sh = "mkdir -p /usr/local/bin && ln -sf '\(binary)' '\(link)'"
                let script = "do shell script \"\(sh)\" with administrator privileges"
                var error: NSDictionary?
                NSAppleScript(source: script)?.executeAndReturnError(&error)
                if let error, (error[NSAppleScript.errorNumber] as? Int) == -128 { return }   // cancelled
                if let error { throw NSError(domain: "Jinnie", code: 1, userInfo: [NSLocalizedDescriptionKey: error[NSAppleScript.errorMessage] as? String ?? "\(error)"]) }
            }
            report("Installed jinniectl", "Open a new Terminal window and run: jinniectl doctor")
        } catch {
            report("Couldn't install jinniectl", error.localizedDescription)
        }
    }

    private static func report(_ title: String, _ text: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = text
        alert.runModal()
    }
}
