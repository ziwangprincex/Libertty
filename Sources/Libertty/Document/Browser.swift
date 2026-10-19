import AppKit
import WebKit

/// The browser block's bar (Tern's browser block): back, forward, reload or
/// stop, the address (or a search), and Open in the default browser; a thin
/// line under it shows a page loading. It sits at the top of a web page's
/// pane, which is a browser tab or a page beside the terminal.
final class BrowserBar: NSView, NSTextFieldDelegate {
    static let height: CGFloat = 34

    var onBack: (() -> Void)?
    var onForward: (() -> Void)?
    var onReload: (() -> Void)?
    var onStop: (() -> Void)?
    var onNavigate: ((String) -> Void)?
    var onOpenExternally: (() -> Void)?

    let field = NSTextField()
    private let back = BrowserBar.button("chevron.left", "Back")
    private let forward = BrowserBar.button("chevron.right", "Forward")
    private let reload = BrowserBar.button("arrow.clockwise", "Reload")
    private let external = BrowserBar.button("safari", "Open in Default Browser")
    private let progress = NSView()
    private let line = NSView()
    private var loading = false

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        back.action = #selector(goBack)
        forward.action = #selector(goForward)
        reload.action = #selector(reloadOrStop)
        external.action = #selector(openExternally)
        for b in [back, forward, reload, external] { b.target = self }
        field.placeholderString = "Search or enter an address"
        field.font = Typeface.secondary
        field.isBordered = false
        field.drawsBackground = true
        field.focusRingType = .none
        field.bezelStyle = .roundedBezel
        field.wantsLayer = true
        field.layer?.cornerRadius = 7
        field.delegate = self
        field.cell?.usesSingleLineMode = true
        field.cell?.lineBreakMode = .byTruncatingTail
        progress.wantsLayer = true
        line.wantsLayer = true
        for v in [back, forward, reload, field, external, line, progress] {
            v.translatesAutoresizingMaskIntoConstraints = false
            addSubview(v)
        }
        NSLayoutConstraint.activate([
            back.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            back.centerYAnchor.constraint(equalTo: centerYAnchor),
            forward.leadingAnchor.constraint(equalTo: back.trailingAnchor, constant: 2),
            forward.centerYAnchor.constraint(equalTo: centerYAnchor),
            reload.leadingAnchor.constraint(equalTo: forward.trailingAnchor, constant: 2),
            reload.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.leadingAnchor.constraint(equalTo: reload.trailingAnchor, constant: 8),
            field.centerYAnchor.constraint(equalTo: centerYAnchor),
            field.heightAnchor.constraint(equalToConstant: 24),
            external.leadingAnchor.constraint(equalTo: field.trailingAnchor, constant: 6),
            external.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            external.centerYAnchor.constraint(equalTo: centerYAnchor),
            line.leadingAnchor.constraint(equalTo: leadingAnchor),
            line.trailingAnchor.constraint(equalTo: trailingAnchor),
            line.bottomAnchor.constraint(equalTo: bottomAnchor),
            line.heightAnchor.constraint(equalToConstant: 1),
            progress.leadingAnchor.constraint(equalTo: leadingAnchor),
            progress.bottomAnchor.constraint(equalTo: bottomAnchor),
            progress.heightAnchor.constraint(equalToConstant: 2),
        ])
        progressWidth = progress.widthAnchor.constraint(equalToConstant: 0)
        progressWidth.isActive = true
        updateColors()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    private var progressWidth: NSLayoutConstraint!

    private static func button(_ symbol: String, _ tip: String) -> NSButton {
        let b = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: tip)!, target: nil, action: nil)
        b.isBordered = false
        b.contentTintColor = .secondaryLabelColor
        b.symbolConfiguration = .init(pointSize: 12, weight: .regular)
        b.toolTip = tip
        b.widthAnchor.constraint(equalToConstant: 26).isActive = true
        b.heightAnchor.constraint(equalToConstant: 24).isActive = true
        return b
    }

    /// The bar's colors: the card's, so bar and page read as one card.
    func apply(background: NSColor) {
        layer?.backgroundColor = background.cgColor
        updateColors()
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateColors()
    }

    private func updateColors() {
        line.layer?.backgroundColor = NSColor.separatorColor.cgColor
        progress.layer?.backgroundColor = NSColor.controlAccentColor.cgColor
        field.backgroundColor = NSColor.labelColor.withAlphaComponent(0.06)
    }

    /// What the page is now. The address shows unless it's being typed in.
    func show(url: URL?, canGoBack: Bool, canGoForward: Bool, loading: Bool, progress value: Double) {
        if field.currentEditor() == nil { field.stringValue = url.map(Self.display) ?? "" }
        back.isEnabled = canGoBack
        forward.isEnabled = canGoForward
        self.loading = loading
        reload.image = NSImage(systemSymbolName: loading ? "xmark" : "arrow.clockwise", accessibilityDescription: loading ? "Stop" : "Reload")
        reload.toolTip = loading ? "Stop" : "Reload"
        progressWidth.constant = loading ? max(8, bounds.width * value) : 0
        self.progress.isHidden = !loading
    }

    /// An address as people read it: no `https://`, no trailing slash on a bare host.
    static func display(_ url: URL) -> String {
        guard url.scheme == "http" || url.scheme == "https" else { return url.absoluteString }
        var s = url.absoluteString
        if s.hasPrefix("https://") { s.removeFirst(8) } else if s.hasPrefix("http://") { s.removeFirst(7) }
        if s.hasSuffix("/"), s.dropLast().contains("/") == false { s.removeLast() }
        return s
    }

    /// What was typed, as somewhere to go: an address (with or without its
    /// scheme; `localhost:3000` too), else a search with `browser-search`.
    static func destination(_ typed: String, search: String) -> URL? {
        let text = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return nil }
        if let url = URL(string: text), let scheme = url.scheme?.lowercased(), ["http", "https", "about"].contains(scheme) { return url }
        let looksLikeHost = !text.contains(" ")
            && (text.range(of: #"^localhost(:\d+)?(/.*)?$"#, options: .regularExpression) != nil
                || text.range(of: #"^[\w-]+(\.[\w-]+)+(:\d+)?(/.*)?$"#, options: .regularExpression) != nil
                || text.range(of: #"^\d{1,3}(\.\d{1,3}){3}(:\d+)?(/.*)?$"#, options: .regularExpression) != nil
                || text.range(of: #"^\[[0-9a-fA-F:]+\](:\d+)?(/.*)?$"#, options: .regularExpression) != nil)
        if looksLikeHost {
            // This Mac (its own server) over plain http; anything else over https.
            let host = URL(string: "http://" + text)?.host?.lowercased() ?? ""
            let local = host == "localhost" || host.hasSuffix(".localhost") || host == "::1" || host == "0.0.0.0"
                || host.range(of: #"^127(\.\d{1,3}){3}$"#, options: .regularExpression) != nil
            return URL(string: (local ? "http://" : "https://") + text)
        }
        let query = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?#"))) ?? text
        return URL(string: search.replacingOccurrences(of: "%s", with: query))
    }

    func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
        switch selector {
        case #selector(NSResponder.insertNewline(_:)):
            onNavigate?(field.stringValue)
            return true
        case #selector(NSResponder.cancelOperation(_:)):
            // Esc puts the address back and the keyboard in the page.
            onNavigate?("")
            return true
        default:
            return false
        }
    }

    /// ⌘L: the address, selected.
    func focusAddress() {
        window?.makeFirstResponder(field)
        field.currentEditor()?.selectAll(nil)
    }

    @objc private func goBack() { onBack?() }
    @objc private func goForward() { onForward?() }
    @objc private func reloadOrStop() { loading ? onStop?() : onReload?() }
    @objc private func openExternally() { onOpenExternally?() }
}

/// `libertty +browser`: a command for the browser in front, from a script or
/// an agent in a terminal. It reaches the running app as a distributed
/// notification and its answer is written to the file the command named.
/// Reading or acting in pages needs `browser-automation = true`: a page
/// may be one you're signed in to.
enum BrowserAutomation {
    static let replied = Notification.Name("dev.libertty.terminal.browser-reply")

    /// What needs the setting (opening and navigating don't).
    static let reading: Set<String> = ["text", "html", "eval", "click", "type", "screenshot", "url"]

    /// Carry out `info` in `controller` and answer through the reply file.
    static func handle(_ info: [String: String], in controller: TerminalWindowController?) {
        // The answer goes only where the CLI waits for it: its token's file in
        // the temporary folder (any process can post this notification).
        guard let token = info["token"], UUID(uuidString: token) != nil, let out = info["out"] else { return }
        let outURL = URL(fileURLWithPath: out)
        guard outURL.lastPathComponent == "libertty-browser-\(token)",
              outURL.deletingLastPathComponent().resolvingSymlinksInPath().path
                == URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path else { return }
        let op = info["op"] ?? ""
        let arg = info["arg"] ?? ""
        func reply(_ ok: Bool, _ text: String) {
            try? Data(text.utf8).write(to: URL(fileURLWithPath: out), options: .atomic)
            DistributedNotificationCenter.default().postNotificationName(
                replied, object: nil, userInfo: ["token": token, "ok": ok ? "1" : "0"], deliverImmediately: true)
        }
        guard let controller else { return reply(false, "no Libertty window") }
        if reading.contains(op), !ConfigStore.shared.config.browserAutomation {
            return reply(false, "\(op) needs browser-automation = true in the config (pages may be ones you're signed in to)")
        }
        if op == "open" {
            guard let url = BrowserBar.destination(arg.isEmpty ? "about:blank" : arg, search: ConfigStore.shared.config.browserSearch) else {
                return reply(false, "not an address: \(arg)")
            }
            controller.openBrowser(url, beside: info["split"] == "1")
            return reply(true, url.absoluteString)
        }
        guard let page = controller.frontBrowser else { return reply(false, "no browser open (libertty +browser open URL)") }
        switch op {
        case "url": reply(true, page.pageURL.absoluteString)
        case "back": page.browserBack(); reply(true, "")
        case "forward": page.browserForward(); reply(true, "")
        case "reload": page.reload(); reply(true, "")
        case "go":
            guard let url = BrowserBar.destination(arg, search: ConfigStore.shared.config.browserSearch) else { return reply(false, "not an address: \(arg)") }
            page.browse(to: url)
            reply(true, url.absoluteString)
        case "text", "html":
            page.pageScript(op == "text" ? "document.body ? document.body.innerText : ''" : "document.documentElement.outerHTML", own: true) { value, error in
                reply(error == nil, error ?? (value as? String ?? ""))
            }
        case "eval":
            page.pageScript(arg) { value, error in
                if let error { return reply(false, error) }
                let json = value.flatMap { v -> String? in
                    if v is NSNull { return "null" }
                    if let s = v as? String { return s }
                    // NaN or a date would make JSONSerialization raise (not throw): ask first.
                    guard JSONSerialization.isValidJSONObject([v]),
                          let data = try? JSONSerialization.data(withJSONObject: [v]) else { return String(describing: v) }
                    return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
                } ?? "undefined"
                reply(true, json)
            }
        case "click":
            page.pageScript("(function(s){const e=document.querySelector(s);if(!e)return false;e.click();return true})(\(Self.literal(arg)))", own: true) { value, error in
                if let error { return reply(false, error) }
                reply(value as? Bool == true, value as? Bool == true ? "" : "nothing matches \(arg)")
            }
        case "type":
            let parts = arg.split(separator: "\u{1f}", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { return reply(false, "usage: +browser type SELECTOR TEXT") }
            let script = """
                (function(s,t){const e=document.querySelector(s);if(!e)return false;e.focus();
                const setter=Object.getOwnPropertyDescriptor(Object.getPrototypeOf(e),'value')?.set;
                if(setter)setter.call(e,t);else e.value=t;
                e.dispatchEvent(new Event('input',{bubbles:true}));e.dispatchEvent(new Event('change',{bubbles:true}));return true})(\(Self.literal(parts[0])), \(Self.literal(parts[1])))
                """
            page.pageScript(script, own: true) { value, error in
                if let error { return reply(false, error) }
                reply(value as? Bool == true, value as? Bool == true ? "" : "nothing matches \(parts[0])")
            }
        case "screenshot":
            guard let path = info["file"], !path.isEmpty else { return reply(false, "usage: +browser screenshot FILE.png") }
            page.snapshot { image in
                guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]),
                      (try? png.write(to: URL(fileURLWithPath: path))) != nil else { return reply(false, "couldn't take the picture") }
                reply(true, path)
            }
        default:
            reply(false, "unknown +browser command \(op)")
        }
    }

    private static func literal(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]), let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }
}
