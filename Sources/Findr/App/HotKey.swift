import AppKit
import Carbon.HIToolbox

/// A global shortcut through Carbon's RegisterEventHotKey, which needs no Accessibility permission.
final class HotKey {
    private var ref: EventHotKeyRef?
    private static var action: (() -> Void)?
    private static var handlerInstalled = false

    init(action: @escaping () -> Void) {
        Self.action = action
        guard !Self.handlerInstalled else { return }
        Self.handlerInstalled = true
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, _, _ in
            DispatchQueue.main.async { HotKey.action?() }
            return noErr
        }, 1, &spec, nil, nil)
    }

    /// Returns false when macOS refuses the combination.
    @discardableResult
    func register(code: UInt32, modifiers: UInt32) -> Bool {
        unregister()
        let id = EventHotKeyID(signature: OSType(0x4644_5252), id: 1) // "FDRR"
        return RegisterEventHotKey(code, modifiers, id, GetApplicationEventTarget(), 0, &ref) == noErr
    }

    func unregister() {
        if let ref { UnregisterEventHotKey(ref) }
        ref = nil
    }

    /// Converts AppKit modifier flags to the Carbon mask RegisterEventHotKey expects.
    static func carbonModifiers(_ flags: NSEvent.ModifierFlags) -> UInt32 {
        var mask: UInt32 = 0
        if flags.contains(.command) { mask |= UInt32(cmdKey) }
        if flags.contains(.shift) { mask |= UInt32(shiftKey) }
        if flags.contains(.option) { mask |= UInt32(optionKey) }
        if flags.contains(.control) { mask |= UInt32(controlKey) }
        return mask
    }

    /// Readable label such as "⌘⇧Space".
    static func label(for event: NSEvent) -> String {
        let flags = event.modifierFlags
        var text = ""
        if flags.contains(.control) { text += "⌃" }
        if flags.contains(.option) { text += "⌥" }
        if flags.contains(.shift) { text += "⇧" }
        if flags.contains(.command) { text += "⌘" }
        let names: [UInt16: String] = [49: "Space", 36: "Return", 48: "Tab", 51: "Delete",
                                       123: "←", 124: "→", 125: "↓", 126: "↑"]
        text += names[event.keyCode] ?? (event.charactersIgnoringModifiers ?? "?").uppercased()
        return text
    }
}
