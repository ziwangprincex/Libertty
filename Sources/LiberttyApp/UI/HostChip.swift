import AppKit
import LiberttyCore

/// The toolbar's host chip (Rex): the machine this window's sessions run
/// on, and under it the chip, memory, macOS and liberttyd. On a remote
/// window it names the host instead (GoRex's take).
final class HostChip {
    private let button: NSButton
    private let popover = NSPopover()
    private var host: RemoteHost?
    private var linkUp = true
    /// The session server's answer for this machine, once known.
    private var server: String?
    /// One question at a time: a host that's down can hold a dial open for
    /// a long while, and every click would otherwise park one more thread.
    private var asking = false
    private weak var shown: InfoViewController?

    var view: NSView { button }

    init() {
        button = NSButton(frame: NSRect(x: 0, y: 0, width: 120, height: 24))
        button.bezelStyle = .texturedRounded
        button.imagePosition = .imageLeading
        button.font = .systemFont(ofSize: 11, weight: .medium)
        button.target = self
        button.action = #selector(showInfo(_:))
        button.toolTip = "This Mac"
        popover.behavior = .transient
        refresh(host: nil, linkUp: true)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    /// Which machine the window runs on: this Mac (nil) or a host.
    func refresh(host: RemoteHost?, linkUp: Bool) {
        if host?.destination != self.host?.destination { server = nil }  // another machine's
        self.host = host
        self.linkUp = linkUp
        if let host {
            button.title = host.destination
            button.image = NSImage(systemSymbolName: "server.rack", accessibilityDescription: nil)
            button.toolTip = "Sessions on \(host.destination)"
        } else {
            button.title = HostChip.computerName
            button.image = NSImage(systemSymbolName: "cpu", accessibilityDescription: nil)
            button.toolTip = "This Mac"
        }
        button.sizeToFit()
        // An open popover follows the link coming back (or going).
        shown?.show(linkUp: linkUp)
    }

    @objc private func showInfo(_ sender: Any?) {
        let info = InfoViewController(host: host, linkUp: linkUp, server: server)
        shown = info
        popover.contentViewController = info
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .maxY)
        askServer()
    }

    /// Who serves the sessions: liberttyd's protocol and build, on the
    /// machine the window runs on. Asked off the main thread.
    private func askServer() {
        guard !asking else { return }
        asking = true
        let destination = host?.destination
        let address = host?.address ?? .local
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let hello = DaemonClient.hello(timeout: 4, address: address)
            let text = hello.map { "liberttyd · protocol \($0.version) · build \($0.build.isEmpty ? "?" : $0.build)" }
                ?? (destination == nil ? "liberttyd isn't running" : "unreachable")
            DispatchQueue.main.async {
                guard let self else { return }
                self.asking = false
                // The window may have moved to another machine meanwhile.
                guard self.host?.destination == destination else { return }
                self.server = text
                self.shown?.show(server: text)
            }
        }
    }

    // MARK: What this Mac is

    private static func sysctl(_ name: String) -> String {
        var size = 0
        sysctlbyname(name, nil, &size, nil, 0)
        guard size > 0 else { return "" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "" }
        return String(cString: buffer)
    }

    /// The name the user gave this Mac ("…'s MacBook Pro").
    static var computerName: String {
        guard let name = Host.current().localizedName, !name.isEmpty else { return "This Mac" }
        // "Prince 的 MacBook Pro" → "MacBook Pro".
        for separator in ["的", "'s ", "’s "] {
            if let range = name.range(of: separator), range.upperBound < name.endIndex {
                return String(name[range.upperBound...])
            }
        }
        return name
    }

    static var model: String { sysctl("hw.model") }
    static var chip: String { sysctl("machdep.cpu.brand_string") }
    static var memory: String {
        var size = 0
        sysctlbyname("hw.memsize", nil, &size, nil, 0)
        var bytes = UInt64(0)
        guard size == MemoryLayout<UInt64>.size, sysctlbyname("hw.memsize", &bytes, &size, nil, 0) == 0 else { return "" }
        return bytes >= (1 << 30) ? "\(bytes >> 30) GB" : "\(bytes >> 20) MB"
    }
    static var systemVersion: String {
        let v = ProcessInfo.processInfo.operatingSystemVersion
        return "macOS \(v.majorVersion).\(v.minorVersion)\(v.patchVersion > 0 ? ".\(v.patchVersion)" : "")"
    }

    /// The chip, memory and OS of this Mac, as rows for the popover.
    static var thisMacRows: [(String, String)] {[
        ("Model", model),
        ("Chip", chip),
        ("Memory", memory),
        ("System", systemVersion),
    ]}
}

/// The chip's popover: the machine's facts, and its session server.
private final class InfoViewController: NSViewController {
    private let host: RemoteHost?
    private var linkUp: Bool
    private var server: String?
    private weak var linkLabel: NSTextField?
    private weak var serverLabel: NSTextField?

    init(host: RemoteHost?, linkUp: Bool, server: String?) {
        self.host = host
        self.linkUp = linkUp
        self.server = server
        super.init(nibName: nil, bundle: nil)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    override func loadView() {
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.edgeInsets = NSEdgeInsets(top: 14, left: 16, bottom: 14, right: 16)

        let title = NSTextField(labelWithString: host?.destination ?? Host.current().localizedName ?? "This Mac")
        title.font = .systemFont(ofSize: 13, weight: .semibold)
        stack.addArrangedSubview(title)

        if host != nil {
            let link = NSTextField(labelWithString: "")
            link.font = .systemFont(ofSize: 11)
            stack.addArrangedSubview(link)
            linkLabel = link
        } else {
            for (label, value) in HostChip.thisMacRows where !value.isEmpty {
                stack.addArrangedSubview(Self.row(label, value))
            }
        }
        let server = Self.row("Session server", self.server ?? "…")
        stack.addArrangedSubview(server)
        serverLabel = server

        view = stack
        show(linkUp: linkUp)
    }

    func show(linkUp: Bool) {
        self.linkUp = linkUp
        guard let host, let linkLabel else { return }
        linkLabel.stringValue = linkUp ? "Connected · sessions in \(host.destination)'s liberttyd" : "Reconnecting…"
        linkLabel.textColor = linkUp ? .secondaryLabelColor : .systemOrange
    }

    func show(server: String) {
        self.server = server
        serverLabel?.attributedStringValue = Self.row("Session server", server).attributedStringValue
    }

    private static func row(_ label: String, _ value: String) -> NSTextField {
        let text = NSTextField(labelWithString: "")
        text.font = .systemFont(ofSize: 11)
        text.textColor = .secondaryLabelColor
        let bold = NSMutableAttributedString(string: label + "  ",
                                             attributes: [.font: NSFont.systemFont(ofSize: 11, weight: .medium)])
        bold.append(NSAttributedString(string: value, attributes: [:]))
        text.attributedStringValue = bold
        return text
    }
}
