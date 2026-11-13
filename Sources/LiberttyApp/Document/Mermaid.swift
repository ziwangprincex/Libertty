import AppKit
import WebKit

/// Mermaid diagrams in Markdown documents (```mermaid fences; Mermaid, MIT,
/// bundled from frontend/mermaid by scripts/build-mermaid.sh). A document's
/// page runs no scripts, so the diagrams are drawn elsewhere: in a page of
/// their own out of any window, with no network (its CSP), holding nothing
/// but Mermaid and the source it's handed. Only SVG comes back, cleaned
/// again here, to be set into the document. Main thread only.
final class MermaidRenderer: NSObject, WKNavigationDelegate {
    static let shared = MermaidRenderer()

    enum Drawn: Equatable {
        case svg(String)
        case failed(String)
    }

    /// The bundled script: the app's Resources/mermaid, or vendor/mermaid when running from `swift build`.
    static var script: URL? {
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL { dirs.append(resources.appendingPathComponent("mermaid")) }
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        dirs.append(root.appendingPathComponent("vendor/mermaid"))
        return dirs.map { $0.appendingPathComponent("mermaid.js") }.first { FileManager.default.fileExists(atPath: $0.path) }
    }

    /// How long one diagram may take before it counts as failed (and the page is started over).
    static var timeout: TimeInterval = 15
    /// How long the drawing page stays after its last diagram.
    static let idleTime: TimeInterval = 120

    // Drawn diagrams by theme and source: a document that reloads (saved,
    // scrolled back to) sets them at once.
    private var cache: [String: Drawn] = [:]
    private var order: [String] = []
    private static let cacheLimit = 200

    private struct Job {
        let key: String
        let source: String
        let options: [String: Any]
    }
    private var jobs: [Job] = []
    private var waiting: [() -> Void] = []
    private var drawing = false
    private var web: WKWebView?
    private var ready = false
    private var idle: DispatchWorkItem?

    private static func key(_ source: String, _ theme: Theme) -> String {
        "\(theme.background.hexString)\(theme.foreground.hexString)\u{0}\(source)"
    }

    func drawn(_ source: String, theme: Theme) -> Drawn? { cache[Self.key(source, theme)] }

    /// A fence's HTML in the document: the diagram once drawn, its source with
    /// what went wrong if it couldn't be, its source while it's being drawn.
    func html(_ source: String, theme: Theme) -> String {
        let code = "<pre><code class=\"language-mermaid\">\(MarkdownRenderer.escape(source))</code></pre>"
        switch drawn(source, theme: theme) {
        case .svg(let svg):
            return "<div class=\"mermaid\" role=\"img\" aria-label=\"\(MarkdownRenderer.escapeAttribute(L10n.t("Diagram")))\">\(svg)</div>\n"
        case .failed(let why):
            return "<div class=\"code mermaid-failed\"><div class=\"code-head\"><span>"
                + MarkdownRenderer.escape(L10n.t("Couldn't draw this diagram")) + ": " + MarkdownRenderer.escape(why)
                + "</span></div>\(code)</div>\n"
        case nil:
            return "<div class=\"code mermaid-pending\"><div class=\"code-head\"><span>mermaid</span></div>\(code)</div>\n"
        }
    }

    /// Draw those of `sources` not drawn yet for `theme`; then `done`, once.
    func draw(_ sources: [String], theme: Theme, done: @escaping () -> Void) {
        var queued = Set(jobs.map(\.key))
        let options = Self.options(theme)
        for source in sources {
            let key = Self.key(source, theme)
            guard cache[key] == nil, queued.insert(key).inserted else { continue }
            jobs.append(Job(key: key, source: source, options: options))
        }
        waiting.append(done)
        next()
    }

    private func next() {
        guard !drawing else { return }
        idle?.cancel()
        guard let job = jobs.first else {
            let done = waiting
            waiting.removeAll()
            done.forEach { $0() }
            // Its WebKit process goes after a while with nothing to draw.
            let close = DispatchWorkItem { [weak self] in
                self?.web = nil
                self?.ready = false
            }
            idle = close
            DispatchQueue.main.asyncAfter(deadline: .now() + Self.idleTime, execute: close)
            return
        }
        guard let web = page() else {
            // No Mermaid to draw with: each says so (rather than waiting forever).
            for job in jobs { store(.failed(L10n.t("Mermaid isn't in this build.")), for: job.key) }
            jobs.removeAll()
            return next()
        }
        guard ready else { return }  // didFinish starts it
        drawing = true
        var finished = false
        let finish = { [weak self] (drawn: Drawn) in
            guard let self, !finished else { return }
            finished = true
            self.store(drawn, for: job.key)
            self.jobs.removeFirst()
            self.drawing = false
            self.next()
        }
        let timer = DispatchWorkItem { [weak self] in
            // Stuck (a diagram Mermaid can't finish): a fresh page for the rest.
            self?.web = nil
            self?.ready = false
            finish(.failed(L10n.t("It took too long to draw.")))
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.timeout, execute: timer)
        var options = job.options
        // An id of its own: its styles and markers are scoped by it, and two
        // diagrams drawn at different times may share a document.
        options["id"] = "libertty-diagram-" + UUID().uuidString.prefix(8).lowercased()
        web.callAsyncJavaScript("return await window.libertty.render(source, options)",
                                arguments: ["source": job.source, "options": options], in: nil, in: .page) { result in
            timer.cancel()
            switch result {
            case .success(let value):
                if let svg = value as? String, svg.contains("<svg") { finish(.svg(Self.clean(svg))) }
                else { finish(.failed(L10n.t("Mermaid drew nothing."))) }
            case .failure(let error):
                let message = (error as NSError).userInfo["WKJavaScriptExceptionMessage"] as? String ?? error.localizedDescription
                finish(.failed(Self.firstLine(message)))
            }
        }
    }

    private func store(_ drawn: Drawn, for key: String) {
        if cache[key] == nil { order.append(key) }
        cache[key] = drawn
        while order.count > Self.cacheLimit { cache[order.removeFirst()] = nil }
    }

    /// "UnknownDiagramError: No diagram type detected…" → "No diagram type detected…".
    static func firstLine(_ message: String) -> String {
        let line = message.split(separator: "\n").first.map(String.init) ?? message
        return line.replacingOccurrences(of: #"^\s*(?:[A-Za-z]*Error:\s*)+"#, with: "", options: .regularExpression)
    }

    // MARK: The page

    /// The drawing page, made when first needed: Mermaid as the one script
    /// (put there by Libertty, so the page's own CSP allows no script at all).
    private func page() -> WKWebView? {
        if let web { return web }
        guard let script = Self.script, let code = try? String(contentsOf: script, encoding: .utf8) else { return nil }
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.userContentController.addUserScript(
            WKUserScript(source: code, injectionTime: .atDocumentEnd, forMainFrameOnly: true, in: .page))
        let web = WKWebView(frame: NSRect(x: 0, y: 0, width: 1200, height: 800), configuration: configuration)
        web.navigationDelegate = self
        self.web = web
        ready = false
        web.loadHTMLString("""
            <!doctype html><html><head><meta charset="utf-8">
            <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; img-src data:; font-src data:">
            </head><body></body></html>
            """, baseURL: nil)
        return web
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        guard webView === web else { return }
        ready = true
        next()
    }

    /// Only the page itself, never a link or a frame elsewhere.
    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        decisionHandler(action.request.url?.absoluteString == "about:blank" ? .allow : .cancel)
    }

    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        guard webView === web else { return }
        web = nil
        ready = false
        if drawing { return }  // its timer ends that one
        next()
    }

    // MARK: Look

    /// Mermaid's base theme in the terminal theme's colors, as the document is.
    static func options(_ t: Theme) -> [String: Any] {
        func mix(_ a: RGB, _ b: RGB, _ f: Double) -> String {
            func c(_ x: UInt8, _ y: UInt8) -> Int { Int((Double(x) * (1 - f) + Double(y) * f).rounded()) }
            return String(format: "#%02x%02x%02x", c(a.r, b.r), c(a.g, b.g), c(a.b, b.b))
        }
        let dark = t.isDark, bg = t.background, fg = t.foreground
        let accent = dark ? RGB(0x5a, 0x8c, 0xff) : RGB(0x3d, 0x6f, 0xff)
        let font = "-apple-system, 'SF Pro Text', system-ui, sans-serif"
        return [
            "theme": "base",
            "fontFamily": font,
            "themeVariables": [
                "darkMode": dark,
                "background": bg.hexString,
                "fontFamily": font,
                "fontSize": "14px",
                "primaryColor": mix(bg, fg, dark ? 0.14 : 0.06),
                "primaryTextColor": fg.hexString,
                "primaryBorderColor": mix(bg, accent, 0.65),
                "secondaryColor": mix(bg, accent, dark ? 0.22 : 0.12),
                "tertiaryColor": mix(bg, fg, dark ? 0.08 : 0.03),
                "lineColor": mix(fg, bg, 0.4),
                "textColor": fg.hexString,
                "titleColor": fg.hexString,
                "edgeLabelBackground": bg.hexString,
                "clusterBkg": mix(bg, fg, dark ? 0.06 : 0.03),
                "clusterBorder": mix(bg, fg, 0.25),
                "mainBkg": mix(bg, fg, dark ? 0.14 : 0.06),
                "noteBkgColor": mix(bg, RGB(0xf0, 0xc0, 0x40), dark ? 0.25 : 0.2),
                "noteTextColor": fg.hexString,
            ] as [String: Any],
        ]
    }

    // MARK: Cleaning

    /// What may stay of the SVG (Mermaid's strict mode cleaned it already;
    /// the document runs no scripts anyway): no script, no handler, no frame
    /// or object, and nothing loaded from elsewhere — links within it only,
    /// pictures inline.
    static func clean(_ svg: String) -> String {
        var s = svg
        func remove(_ pattern: String, with template: String = "") {
            s = s.replacingOccurrences(of: pattern, with: template, options: [.regularExpression, .caseInsensitive])
        }
        remove(#"<script\b[^>]*>[\s\S]*?</script\s*>"#)
        remove(#"<script\b[^>]*/?>"#)
        remove(#"</?(iframe|object|embed|link|meta|base|audio|video|source)\b[^>]*>"#)
        // A picture only inline (a label's <img src=…> would load from wherever).
        remove(#"<img\b(?![^>]*\ssrc\s*=\s*["']data:image/(?:png|jpe?g|gif|webp);)[^>]*>"#)
        remove(#"\son[a-z]+\s*=\s*("[^"]*"|'[^']*'|[^\s>]+)"#)
        // Anything but a local reference or an inline picture.
        remove(#"\s(href|xlink:href|src)\s*=\s*("(?!#|data:image/(?:png|jpe?g|gif|webp);)[^"]*"|'(?!#|data:image/(?:png|jpe?g|gif|webp);)[^']*')"#,
               with: " $1=\"#\"")
        remove(#"@import[^;]*;?"#)
        remove(#"url\(\s*(?!['"]?#)[^)]*\)"#, with: "none")
        return s
    }
}
