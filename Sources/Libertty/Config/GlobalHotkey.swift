import AppKit
import Carbon.HIToolbox

/// A physical key plus modifiers, as Carbon's global hotkeys need it.
/// Written with the same names as keybinds: `ctrl+alt+t`, `cmd+shift+space`, `f5`.
struct Shortcut: Equatable {
    /// Carbon virtual key code (`kVK_*`), the same numbering as `NSEvent.keyCode`.
    var keyCode: UInt32
    var modifiers: NSEvent.ModifierFlags

    init(keyCode: UInt32, modifiers: NSEvent.ModifierFlags) {
        self.keyCode = keyCode
        self.modifiers = modifiers.intersection([.control, .option, .shift, .command])
    }

    /// A bare key is only allowed for F-keys: anything else would swallow
    /// ordinary typing system-wide.
    init?(_ text: String) {
        guard let trigger = Trigger(text.lowercased()), let s = trigger.shortcut else { return nil }
        guard !s.modifiers.isEmpty || trigger.keyName.isFunctionKey else { return nil }
        self = s
    }

    /// From a key press in a shortcut recorder.
    init?(event: NSEvent) {
        let mods = event.modifierFlags.intersection([.control, .option, .shift, .command])
        guard let key = KeyName.code(Int(event.keyCode)), !mods.isEmpty || key.isFunctionKey else { return nil }
        self.init(keyCode: UInt32(event.keyCode), modifiers: mods)
    }

    private var key: KeyName? { KeyName.code(Int(keyCode)) }

    /// The form written to the config file.
    var configString: String { (modifierConfigNames(modifiers) + [key?.name ?? "?"]).joined(separator: "+") }

    /// The form shown in menus and Settings, e.g. `⌃⌥T`.
    var displayString: String { modifierSymbols(modifiers) + (key?.symbol ?? "?") }

    fileprivate var carbonModifiers: UInt32 {
        var m = 0
        if modifiers.contains(.command) { m |= cmdKey }
        if modifiers.contains(.shift) { m |= shiftKey }
        if modifiers.contains(.option) { m |= optionKey }
        if modifiers.contains(.control) { m |= controlKey }
        return UInt32(m)
    }
}

/// System-wide shortcuts through Carbon's `RegisterEventHotKey`, which
/// needs no Accessibility permission (unlike an event tap). The key is
/// consumed before the frontmost app sees it.
final class GlobalHotkeys {
    static let shared = GlobalHotkeys()

    static let didChange = Notification.Name("LiberttyGlobalHotkeysDidChange")

    /// Shortcuts (config strings) the system refused: another app owns them,
    /// or the key has no physical code (like `plus`).
    private(set) var failed: Set<String> = [] {
        didSet { NotificationCenter.default.post(name: Self.didChange, object: self) }
    }

    private var bindings: [(shortcut: Shortcut?, text: String, action: () -> Void)] = []
    private var registered: [EventHotKeyRef] = []
    private var handler: EventHandlerRef?

    /// While paused (a Settings recorder is listening) the keys reach apps normally.
    var paused = false {
        didSet { if paused != oldValue { reregister() } }
    }

    private init() {
        var type = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetEventDispatcherTarget(), { _, event, _ in
            var id = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                                           nil, MemoryLayout<EventHotKeyID>.size, nil, &id)
            guard status == noErr, id.signature == GlobalHotkeys.signature else { return OSStatus(eventNotHandledErr) }
            // Carbon dispatches on the main thread.
            let bindings = GlobalHotkeys.shared.bindings
            if Int(id.id) < bindings.count { bindings[Int(id.id)].action() }
            return noErr
        }, 1, &type, nil, &handler)
    }

    private static let signature: OSType = 0x4C55_4D4E  // 'LUMN'

    /// Replace every global shortcut. `text` is the config spelling, for
    /// reporting failures.
    func bind(_ list: [(text: String, action: () -> Void)]) {
        bindings = list.map { (Shortcut($0.text), $0.text, $0.action) }
        reregister()
    }

    private func reregister() {
        registered.forEach { UnregisterEventHotKey($0) }
        registered.removeAll()
        guard !paused else { return }
        var failures = Set<String>()
        for (i, b) in bindings.enumerated() {
            guard let shortcut = b.shortcut else {
                failures.insert(b.text)
                continue
            }
            var ref: EventHotKeyRef?
            let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers,
                                             EventHotKeyID(signature: Self.signature, id: UInt32(i)),
                                             GetEventDispatcherTarget(), 0, &ref)
            if status == noErr, let ref { registered.append(ref) } else { failures.insert(b.text) }
        }
        if failures != failed { failed = failures }
    }
}
