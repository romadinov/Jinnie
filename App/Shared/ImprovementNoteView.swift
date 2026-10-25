import JinnieCore
import SwiftUI
#if os(iOS)
import UIKit
#else
import AppKit
#endif

/// "Suggest an Improvement": a note saved to iCloud Drive › Jinnie › Improvement notes.md with where it was written, the
/// build, the device and (optionally) a screenshot of that moment. The Claude session working on Jinnie reads these
/// (~/Dev/agent-feedback) and fixes them.
struct ImprovementNoteView: View {
    let pending: ImprovementNoteRequest.Pending
    let onDone: () -> Void
    @State private var text = ""
    @State private var attach = true
    @State private var saving = false
    @State private var errorMessage: String?
    @State private var dictation = Dictation()
    @FocusState private var focused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("What could be better? Bugs, ideas, wishes…", text: $text, axis: .vertical)
                        .lineLimit(4...12)
                        .focused($focused)
                    HStack { DictationStatus(dictation: dictation); Spacer(); MicButton(text: $text, dictation: dictation) }
                } footer: {
                    Text("Noted at: \(pending.context)")
                }
                if let png = pending.screenshot, let image = Self.image(png) {
                    Section {
                        Toggle("Attach screenshot", isOn: $attach)
                        if attach {
                            image.resizable().scaledToFit().frame(maxHeight: 220)
                                .clipShape(RoundedRectangle(cornerRadius: 8)).frame(maxWidth: .infinity)
                        }
                    }
                }
                if let errorMessage { Text(errorMessage).foregroundStyle(.red) }
            }
            .formStyle(.grouped)
            .navigationTitle("Suggest an Improvement")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel", action: onDone) }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .keyboardShortcut(.return, modifiers: .command)
                        .disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || saving)
                }
            }
            .onAppear { focused = true }
        }
        #if os(macOS)
        .frame(minWidth: 480, minHeight: 420)
        #endif
    }

    static func image(_ png: Data) -> Image? {
        #if os(iOS)
        UIImage(data: png).map { Image(uiImage: $0) }
        #else
        NSImage(data: png).map { Image(nsImage: $0) }
        #endif
    }

    private func save() async {
        saving = true
        defer { saving = false }
        let note = text, context = pending.context, png = attach ? pending.screenshot : nil
        let device = ImprovementNoteRequest.deviceDescription
        do {
            try await Task.detached(priority: .userInitiated) {
                _ = try ImprovementNotes().add(note, context: context, device: device, screenshot: png)
            }.value
            onDone()
        } catch {
            errorMessage = "Couldn't save: \(error.localizedDescription)"
        }
    }
}

/// Presents the note form from anywhere: takes the screenshot first (so it shows the screen, not the menu), then the sheet.
@MainActor @Observable
final class ImprovementNoteRequest {
    static let shared = ImprovementNoteRequest()
    struct Pending: Identifiable {
        let id = UUID()
        let context: String
        let screenshot: Data?
    }
    var pending: Pending?

    /// Improvement notes are for the developer's own builds only (see DeveloperBuild).
    static var isAvailable: Bool { DeveloperBuild.isDeveloper }

    func start() {
        guard Self.isAvailable else { return }
        let context = AppModel.shared.place
        Task {
            try? await Task.sleep(for: .milliseconds(450))
            pending = Pending(context: context, screenshot: Self.capture())
        }
    }

    static var deviceDescription: String {
        #if os(iOS)
        "\(UIDevice.current.model), iOS \(UIDevice.current.systemVersion)"
        #else
        "Mac, macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion).\(ProcessInfo.processInfo.operatingSystemVersion.minorVersion)"
        #endif
    }

    /// The app's current window as PNG.
    static func capture() -> Data? {
        #if os(iOS)
        guard let window = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene })
            .flatMap(\.windows).first(where: \.isKeyWindow) else { return nil }
        let image = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in window.drawHierarchy(in: window.bounds, afterScreenUpdates: false) }
        return image.pngData()
        #else
        guard let view = (NSApp.mainWindow ?? NSApp.windows.first { $0.isVisible && $0.title == "Jinnie" })?.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        view.cacheDisplay(in: view.bounds, to: rep)
        return rep.representation(using: .png, properties: [:])
        #endif
    }
}
