import AppKit
import Carbon.HIToolbox

/// A system-wide shortcut. Carbon's RegisterEventHotKey needs no Accessibility permission
/// and works whichever app is frontmost.
struct Shortcut: Codable, Equatable {
    var keyCode: UInt32
    var carbonModifiers: UInt32
    var display: String

    init(keyCode: UInt32, carbonModifiers: UInt32, display: String) {
        self.keyCode = keyCode; self.carbonModifiers = carbonModifiers; self.display = display
    }

    init?(event: NSEvent) {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        var mods: UInt32 = 0
        var text = ""
        if flags.contains(.control) { mods |= UInt32(controlKey); text += "⌃" }
        if flags.contains(.option) { mods |= UInt32(optionKey); text += "⌥" }
        if flags.contains(.shift) { mods |= UInt32(shiftKey); text += "⇧" }
        if flags.contains(.command) { mods |= UInt32(cmdKey); text += "⌘" }
        guard mods != 0 else { return nil }
        let key: String = switch Int(event.keyCode) {
        case kVK_Space: "Space"; case kVK_Return: "↩"; case kVK_Tab: "⇥"
        default: (event.charactersIgnoringModifiers ?? "?").uppercased()
        }
        self.init(keyCode: UInt32(event.keyCode), carbonModifiers: mods, display: text + key)
    }

    static func load(_ key: String, default d: Shortcut) -> Shortcut? {
        guard let data = UserDefaults.standard.data(forKey: key) else { return d }
        if data.isEmpty { return nil } // explicitly cleared
        return (try? JSONDecoder().decode(Shortcut.self, from: data)) ?? d
    }

    static func save(_ s: Shortcut?, _ key: String) {
        UserDefaults.standard.set(s.flatMap { try? JSONEncoder().encode($0) } ?? Data(), forKey: key)
    }
}

final class HotKeyCenter {
    static let shared = HotKeyCenter()
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var handlers: [UInt32: () -> Void] = [:]
    private var installed = false

    func register(id: UInt32, _ shortcut: Shortcut?, handler: @escaping () -> Void) {
        unregister(id: id)
        guard let shortcut else { return }
        installIfNeeded()
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x4A4E4E49), id: id) // 'JNNI'
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID, GetApplicationEventTarget(), 0, &ref)
        if status == noErr, let ref {
            refs[id] = ref
            handlers[id] = handler
        } else {
            NSLog("Jinnie: could not register hotkey \(shortcut.display) (\(status)); another app may own it")
        }
    }

    func unregister(id: UInt32) {
        if let r = refs.removeValue(forKey: id) { UnregisterEventHotKey(r) }
        handlers[id] = nil
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let id = hk.id
            DispatchQueue.main.async { HotKeyCenter.shared.handlers[id]?() }
            return noErr
        }, 1, &spec, nil, nil)
    }
}
