import JinnieCore
import SwiftUI

/// Mic for any text field: tap to dictate (stops by itself after a pause, or tap again); what you say is appended to
/// `text`, live. The menu picks the engine and language, as in Uberdoer.
struct MicButton: View {
    @Binding var text: String
    var dictation: Dictation
    var size: CGFloat = 17
    var autoStart = false
    /// Load Whisper when shown (Quick Note), so it's ready by the time you speak.
    var preload = false
    /// Called with the final text after listening ends (e.g. to save a voice note straight away).
    var onFinish: ((String) -> Void)? = nil
    @State private var before = ""

    var body: some View {
        Menu {
            Button(dictation.isListening ? "Stop Dictation" : "Dictate") { toggle() }
            Divider()
            Section("Engine") {
                Button { dictation.engine = .whisper; Task { await WhisperModel.shared.prepare() } } label: {
                    let t = "Whisper (on device)" + whisperNote
                    if dictation.engine == .whisper { Label(t, systemImage: "checkmark") } else { Text(t) }
                }
                Button { dictation.engine = .apple } label: {
                    if dictation.engine == .apple { Label("Apple", systemImage: "checkmark") } else { Text("Apple") }
                }
            }
            Section("Language") {
                Button { dictation.followKeyboard() } label: {
                    let t = dictation.engine == .whisper ? "Automatic (detects Russian/English)" : "Match Keyboard Layout"
                    if dictation.followsKeyboard { Label(t, systemImage: "checkmark") } else { Text(t) }
                }
                ForEach(Dictation.languages, id: \.identifier) { l in
                    Button { dictation.locale = l } label: {
                        let name = Locale.current.localizedString(forIdentifier: l.identifier) ?? l.identifier
                        if !dictation.followsKeyboard && dictation.locale == l { Label(name, systemImage: "checkmark") } else { Text(name) }
                    }
                }
            }
        } label: {
            Image(systemName: dictation.isListening ? "mic.fill" : (dictation.state == .transcribing ? "waveform" : "mic"))
                .font(.system(size: size))
                .foregroundStyle(dictation.isListening ? Color.red : Color.secondary)
                .symbolEffect(.pulse, isActive: dictation.isBusy)
        } primaryAction: {
            toggle()
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Dictate (⌘D): Whisper on this device, Russian and English. The menu picks the language.")
        .background { Button("") { toggle() }.keyboardShortcut("d").opacity(0).frame(width: 0, height: 0) }
        .onAppear {
            if autoStart { toggle() }
            // Load Whisper now (a few seconds when cached) so it's ready by the time you speak.
            else if preload && dictation.engine == .whisper && WhisperModel.shared.isDownloaded { Task { await WhisperModel.shared.prepare() } }
        }
        .onChange(of: dictation.transcript) { _, t in
            guard dictation.isListening, !t.isEmpty else { return }
            text = before.isEmpty ? t : before + " " + t
        }
    }

    func toggle() {
        if dictation.isListening { dictation.stop(); return }
        before = text.trimmingCharacters(in: .whitespacesAndNewlines)
        dictation.start { final in
            let t = final.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty { text = before.isEmpty ? t : before + " " + t }
            onFinish?(text)
        }
    }

    private var whisperNote: String {
        switch WhisperModel.shared.status {
        case .notDownloaded: " — downloads once"
        case .downloading(let p): " — downloading \(Int(p * 100))%"
        case .failed: " — failed, click to retry"
        default: ""
        }
    }
}

/// One line under a field while dictating: listening, transcribing, model download, or a permission problem.
struct DictationStatus: View {
    var dictation: Dictation

    var body: some View {
        Group {
            switch dictation.state {
            case .starting, .listening:
                Label(dictation.activeEngine == .whisper ? "Listening… (stops after a pause)" : "Listening (Apple)…", systemImage: "waveform")
            case .transcribing: Label("Transcribing…", systemImage: "hourglass")
            case .denied(let m), .failed(let m): Label(m, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            case .idle:
                if case .downloading(let p) = WhisperModel.shared.status {
                    Label("Downloading Whisper \(Int(p * 100))% (one time)", systemImage: "arrow.down.circle")
                }
            }
        }
        .font(.caption).foregroundStyle(.secondary).lineLimit(2)
    }
}
