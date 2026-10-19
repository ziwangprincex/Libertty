import AppKit
import CoreImage

/// Libertty ▸ Web Access…: turn it on, and the link (with a QR code for a
/// phone) that opens this Mac's panes in a browser.
@MainActor
final class WebAccessPanel: NSObject {
    static let shared = WebAccessPanel()

    private var panel: NSPanel?
    private let mode = NSPopUpButton()
    private let link = NSTextField(labelWithString: "")
    private let qr = NSImageView()
    private let status = NSTextField(wrappingLabelWithString: "")
    private let input = NSButton(checkboxWithTitle: "Allow typing from the browser", target: nil, action: nil)
    private var observer: NSObjectProtocol?

    @objc func show(_ sender: Any?) {
        let panel = self.panel ?? makePanel()
        refresh()
        if !panel.isVisible { panel.center() }
        Probe.activateApp()
        panel.makeKeyAndOrderFront(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 440, height: 420),
                            styleMask: [.titled, .closable], backing: .buffered, defer: false)
        panel.title = "Web Access"
        panel.isReleasedWhenClosed = false

        mode.addItems(withTitles: ["Off", "This Mac only", "This Mac and the local network"])
        mode.target = self
        mode.action = #selector(modeChanged(_:))
        link.isSelectable = true
        link.lineBreakMode = .byTruncatingMiddle
        link.font = .monospacedSystemFont(ofSize: 11, weight: .regular)
        qr.imageScaling = .scaleProportionallyUpOrDown
        qr.wantsLayer = true
        qr.layer?.magnificationFilter = .nearest
        status.font = .systemFont(ofSize: 11)
        status.textColor = .secondaryLabelColor
        input.target = self
        input.action = #selector(inputChanged(_:))
        let copy = NSButton(title: "Copy Link", target: self, action: #selector(copyLink(_:)))
        let reset = NSButton(title: "New Link", target: self, action: #selector(newLink(_:)))
        reset.toolTip = "Make a new secret: the old link stops working and open pages disconnect"
        let open = NSButton(title: "Open", target: self, action: #selector(openLink(_:)))

        let buttons = NSStackView(views: [copy, open, NSView(), reset])
        let stack = NSStackView(views: [mode, link, qr, buttons, input, status])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.edgeInsets = NSEdgeInsets(top: 18, left: 20, bottom: 18, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            link.widthAnchor.constraint(equalToConstant: 400),
            buttons.widthAnchor.constraint(equalTo: link.widthAnchor),
            status.widthAnchor.constraint(equalTo: link.widthAnchor),
            qr.widthAnchor.constraint(equalToConstant: 180), qr.heightAnchor.constraint(equalToConstant: 180),
        ])
        panel.contentView = content
        observer = NotificationCenter.default.addObserver(forName: WebAccess.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        self.panel = panel
        return panel
    }

    private func refresh() {
        let web = WebAccess.shared
        mode.selectItem(at: web.mode == .off ? 0 : web.mode == .local ? 1 : 2)
        input.state = web.allowsInput ? .on : .off
        let links = web.links
        link.stringValue = links.first ?? "Turn it on to get a link."
        qr.image = links.first.flatMap(Self.qrCode)
        qr.isHidden = links.isEmpty
        var notes: [String] = []
        if let error = web.lastError { notes.append("Can't listen on port \(web.port): \(error)") }
        switch web.mode {
        case .off: notes.append("Shows the panes of Libertty's windows in a browser, live, and lets you type into them.")
        case .local: notes.append("Only this Mac can connect: from elsewhere, use ssh -L \(web.port):127.0.0.1:\(web.port) or Tailscale.")
        case .network:
            notes.append("Anyone on this network who has the link can see and type into your panes. It's plain HTTP: use it on networks you trust.")
            if links.count > 1 { notes.append("Also: " + links.dropFirst().map { $0.components(separatedBy: "/#").first ?? $0 }.joined(separator: ", ")) }
        }
        status.stringValue = notes.joined(separator: "\n")
    }

    @objc private func modeChanged(_ sender: Any?) {
        ConfigStore.shared.set("web-access", ["off", "local", "network"][max(0, mode.indexOfSelectedItem)])
    }

    @objc private func inputChanged(_ sender: Any?) {
        ConfigStore.shared.set("web-access-input", input.state == .on ? "true" : "false")
    }

    @objc private func copyLink(_ sender: Any?) {
        guard let first = WebAccess.shared.links.first else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(first, forType: .string)
    }

    @objc private func openLink(_ sender: Any?) {
        guard let first = WebAccess.shared.links.first, let url = URL(string: first) else { return }
        NSWorkspace.shared.open(url)
    }

    @objc private func newLink(_ sender: Any?) {
        WebAccess.shared.resetToken()
        refresh()
    }

    private static func qrCode(_ text: String) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(text.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let image = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 8, y: 8)) else { return nil }
        let rep = NSCIImageRep(ciImage: image)
        let result = NSImage(size: rep.size)
        result.addRepresentation(rep)
        return result
    }
}
