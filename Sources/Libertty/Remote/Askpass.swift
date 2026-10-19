import AppKit

/// ssh's questions while Libertty connects to a host (SSH_ASKPASS): a password,
/// a key's passphrase, or whether to trust a host key seen for the first
/// time. ssh runs the Libertty executable with LIBERTTY_ASKPASS=1 and the prompt as
/// its argument; the answer goes to stdout, and an exit status of 1 cancels.
enum Askpass {
    static var requested: Bool { ProcessInfo.processInfo.environment["LIBERTTY_ASKPASS"] == "1" }

    static func run(prompt: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // no second Dock icon
        app.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        if let icon = NSImage(named: "AppIcon") ?? Bundle.main.image(forResource: "AppIcon") { alert.icon = icon }
        let kind = ProcessInfo.processInfo.environment["SSH_ASKPASS_PROMPT"] ?? ""
        let text = prompt.trimmingCharacters(in: .whitespacesAndNewlines)

        if kind == "confirm" || text.contains("(yes/no") {
            // A new host key (with its fingerprint), or a key that asks before each use.
            alert.messageText = text.contains("authenticity") ? "Connect to a host Libertty hasn't seen before?" : "Allow this?"
            alert.informativeText = text
            alert.addButton(withTitle: text.contains("authenticity") ? "Connect" : "Allow")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
            print("yes")
            exit(0)
        }
        if kind == "none" {
            // Only to show (touch your security key…); ssh ends it when done.
            alert.messageText = text
            alert.addButton(withTitle: "Cancel")
            alert.runModal()
            exit(1)
        }

        alert.messageText = text.isEmpty ? "Password" : text
        alert.informativeText = "Libertty is connecting with ssh. The answer goes to ssh only and isn't kept."
        let field = NSSecureTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn else { exit(1) }
        print(field.stringValue)
        exit(0)
    }
}
