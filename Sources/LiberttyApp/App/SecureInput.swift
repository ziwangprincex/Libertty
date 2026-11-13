import AppKit
import Carbon

/// Secure Keyboard Entry (Libertty menu, `toggle_secure_input`): while on and
/// Libertty is the active app, macOS keeps other processes from reading
/// keystrokes. The system state is per process and must be released when
/// Libertty goes to the background, as Terminal.app and Ghostty do.
///
/// With `secure-input-on-password` it also comes on by itself while the pane
/// with the keyboard reads a password, and goes off again after (Otty's Auto
/// Secure Input): the menu's choice is the one you made, not this.
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
    /// The pane with the keyboard reads a password (and the setting is on).
    private(set) var forPassword = false

    private init() {
        requested = UserDefaults.standard.bool(forKey: Self.defaultsKey)
        let center = NotificationCenter.default
        center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.set(false)
        }
        // The keyboard going to another window: a pane's, the palette's, Settings.
        center.addObserver(forName: NSWindow.didBecomeKeyNotification, object: nil, queue: .main) { [weak self] _ in
            self?.refresh()
        }
        apply()
    }

    /// Whether `view` would have it on for a password: it reads one, and the
    /// setting is on.
    static func wantsForPassword(_ view: TerminalView?) -> Bool {
        guard let view, ConfigStore.shared.config.secureInputOnPassword else { return false }
        return view.session.programStatus.readingSecret
    }

    /// Ask again whether the pane with the keyboard reads a password: when
    /// the keyboard moves (a pane, a window, the app) and when a program
    /// starts or stops reading one.
    func refresh() {
        forPassword = Self.wantsForPassword(NSApp?.keyWindow?.firstResponder as? TerminalView)
        apply()
    }

    private func apply() {
        guard NSApp?.isActive == true else { return }
        set(requested || forPassword)
    }

    private func set(_ on: Bool) {
        guard on != enabled else { return }
        if (on ? EnableSecureEventInput() : DisableSecureEventInput()) == noErr { enabled = on }
    }
}
