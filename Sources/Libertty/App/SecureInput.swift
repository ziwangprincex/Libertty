import AppKit
import Carbon

/// Secure Keyboard Entry (Libertty menu, `toggle_secure_input`): while on and
/// Libertty is the active app, macOS keeps other processes from reading
/// keystrokes. The system state is per process and must be released when
/// Libertty goes to the background, as Terminal.app and Ghostty do.
final class SecureInput {
    static let shared = SecureInput()
    private static let defaultsKey = "SecureInput"

    private(set) var enabled = false  // what the system currently has
    var requested: Bool {
        didSet {
            UserDefaults.standard.set(requested, forKey: Self.defaultsKey)
            apply()
        }
    }

    private init() {
        requested = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.apply()
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.set(false)
        }
        apply()
    }

    private func apply() {
        guard NSApp?.isActive == true else { return }
        set(requested)
    }

    private func set(_ on: Bool) {
        guard on != enabled else { return }
        if (on ? EnableSecureEventInput() : DisableSecureEventInput()) == noErr { enabled = on }
    }
}
