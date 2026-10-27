import AppKit
import WebKit

/// A file shown in a tab: Markdown rendered (Tern's `markdown_rendered`),
/// or source code with highlighting and line numbers. Re-renders when the
/// file is saved, keeping the scroll position. Page JavaScript is off, so
/// HTML inside Markdown can't run scripts.
final class DocumentView: NSView, WKNavigationDelegate, WKUIDelegate, WKDownloadDelegate {
    let url: URL

    /// What the pane shows: a text file (source, Markdown, a diff), an
    /// image, a PDF, or a web page (a dev server beside its terminal).
    /// …or a block (a Git client, a board: `libertty-block://…`, see Blocks).
    enum Kind { case text, image, pdf, web, block }
    let kind: Kind
    /// A name to show instead of the file's (`libertty +diff`'s "git diff").
    var displayName: String?
    /// A web page's title changed (the tab shows it).
    var onTitleChange: (() -> Void)?
    private var titleObservation: NSKeyValueObservation?
    /// A link to another local text file: open it in Libertty too.
    var onOpenDocument: ((URL) -> Void)?
    /// A block opening a file at a line (the Git block's files).
    var onOpenDocumentAt: ((URL, Int?) -> Void)?
    /// A file to open in the editor (a block's "Edit as Text").
    var onEditDocument: ((URL) -> Void)?
    /// What blocks ask of the windows: their terminals, a pane to bring forward, a page to open.
    var onListTerminals: (() -> [BlockTerminal])?
    var onRevealPane: ((String) -> Void)?
    var onOpenBrowser: ((URL) -> Void)?

    private var web: WKWebView
    private var theme: Theme
    private var rendered: Bool
    private var renderSetting: Bool
    /// View ▸ Show Markdown Source, for this document only.
    /// With the editor there, a Markdown file's source is the editor (and
    /// going back to the page saves what was typed first).
    var showsSource = false {
        didSet {
            guard showsSource != oldValue, !syncingSource else { return }
            if Self.isMarkdown(url), Self.editsMarkdownSource {
                if showsSource { return setEditing(true) }
                return leaveEditor { [weak self] ok in if !ok { self?.showsSource = true } }
            }
            apply(theme: theme, renderMarkdown: renderSetting, force: true)
        }
    }

    /// Set by the editor itself (entering or leaving it), not by the menu.
    private var syncingSource = false
    private func syncShowsSource(_ on: Bool) {
        syncingSource = true
        showsSource = on
        syncingSource = false
    }

    private static var editsMarkdownSource: Bool { EditorAssets.page != nil && ConfigStore.shared.config.editSourceFiles }

    /// Back to the page, saving unsaved text first; `done(false)` if it couldn't be saved.
    func leaveEditor(_ done: @escaping (Bool) -> Void = { _ in }) {
        guard isEditing else { return done(true) }
        guard hasUnsavedChanges else {
            setEditing(false)
            return done(true)
        }
        save { [weak self] ok in
            if ok { self?.setEditing(false) }
            done(ok)
        }
    }
    private var watcher: DispatchSourceFileSystemObject?
    private var pendingScroll: Double?
    private var htmlFile: URL?

    static let textExtensions: Set<String> = [
        "md", "markdown", "mdown", "mkd", "txt", "text", "log", "csv", "tsv", "rst", "adoc", "org",
        "swift", "c", "h", "m", "mm", "cpp", "cc", "cxx", "hpp", "rs", "go", "py", "rb", "js", "mjs", "cjs", "jsx", "ts", "tsx",
        "java", "kt", "kts", "scala", "cs", "zig", "sh", "bash", "zsh", "fish", "sql", "json", "jsonc", "yaml", "yml",
        "toml", "ini", "conf", "cfg", "xml", "plist", "html", "htm", "css", "scss", "less", "vue", "svelte", "lua",
        "metal", "glsl", "wgsl", "proto", "graphql", "env", "gitignore", "gitattributes", "editorconfig", "diff", "patch",
    ]
    static let textNames: Set<String> = [
        "makefile", "dockerfile", "license", "readme", "changelog", "authors", "contributing", "gemfile", "podfile",
        "procfile", "brewfile", "justfile", ".zshrc", ".bashrc", ".zprofile", ".profile", ".gitconfig", "config",
    ]

    static let imageExtensions: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "heif", "tif", "tiff", "bmp", "ico", "svg"]

    static func kind(of url: URL) -> Kind {
        if Blocks.isBlock(url) { return .block }
        if url.scheme == "http" || url.scheme == "https" || url.absoluteString == "about:blank" { return .web }
        let ext = url.pathExtension.lowercased()
        if ext == "pdf" { return .pdf }
        return imageExtensions.contains(ext) ? .image : .text
    }

    /// Whether Libertty can show this file itself: text it knows (under 5 MB),
    /// an image or PDF (under 200 MB), or a web page.
    static func canShow(_ url: URL) -> Bool {
        if let block = Blocks.address(forFile: url) { return canShow(block) }
        switch kind(of: url) {
        case .web: return true
        case .block: return Blocks.page(for: url) != nil
        case .image, .pdf:
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            return size < 200_000_000
        case .text: break
        }
        let name = url.lastPathComponent.lowercased()
        let ext = url.pathExtension.lowercased()
        guard textExtensions.contains(ext) || textNames.contains(name) || (ext.isEmpty && name.hasPrefix(".")) else {
            return false
        }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
        return size < 5_000_000
    }

    /// The glyph for this document's tab, its row in the palette.
    var symbol: String { Self.symbol(for: url) }

    static func symbol(for url: URL) -> String {
        switch kind(of: url) {
        case .web: "globe"
        case .image: "photo"
        case .pdf: "doc.richtext"
        case .block: Blocks.symbol(of: url)
        case .text: isMarkdown(url) ? "doc.richtext" : "doc.plaintext"
        }
    }

    static func isMarkdown(_ url: URL) -> Bool {
        ["md", "markdown", "mdown", "mkd"].contains(url.pathExtension.lowercased())
    }

    /// `edit`: open it in the editor rather than as a page (nil: what
    /// `wantsEditor` says for its kind of file).
    init(url: URL, theme: Theme, renderMarkdown: Bool, edit: Bool? = nil) {
        self.url = url
        kind = Self.kind(of: url)
        self.theme = theme
        self.rendered = renderMarkdown && Self.isMarkdown(url)
        self.renderSetting = renderMarkdown
        let editing = kind == .text && EditorAssets.page != nil && EditorAssets.canEdit(url)
            && (edit ?? Self.wantsEditor(url, renderMarkdown: renderMarkdown))
        isEditing = editing
        if editing { rendered = false }
        if editing && Self.isMarkdown(url) { showsSource = true }  // (didSet does nothing before init ends)
        web = WKWebView()
        super.init(frame: .zero)
        if kind == .web { makeBrowserBar() }
        if kind == .block, let service = Blocks.make(url) {
            self.service = service
            service.host = self
            install(makeBlockWeb(service))
            NotificationCenter.default.addObserver(self, selector: #selector(commandFinished), name: Blocks.commandFinished, object: nil)
        } else {
            install(editing ? makeEditorWeb() : Self.makeViewerWeb(kind))
        }
        load(keepScroll: false)
        if kind != .web && kind != .block { watch() }
        if kind == .web { observePage() }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError() }

    deinit {
        service?.close()
        returnPoll?.invalidate()
        watcher?.cancel()
        if let htmlFile { try? FileManager.default.removeItem(at: htmlFile) }
    }

    var title: String {
        // Unsaved changes: a dot before the name, as macOS marks a document.
        if hasUnsavedChanges { return "• " + plainTitle }
        return plainTitle
    }

    private var plainTitle: String {
        if let displayName { return displayName }
        if let service { return service.title }
        guard kind == .web else { return url.lastPathComponent }
        // The page's own title, else where it is.
        if let page = web.title, !page.isEmpty { return page }
        return (url.host ?? url.absoluteString) + (url.port.map { ":\($0)" } ?? "") + (url.path.count > 1 ? url.path : "")
    }

    /// A web page: load it again (View ▸ Reload, ⌘R in the page).
    func reload() {
        // A block's page starts over: what it hasn't written goes first.
        if kind == .block, let service, service.hasUnsavedChanges {
            return service.save { [weak self] _ in self?.web.reload() }
        }
        if kind == .web || kind == .block { web.reload() } else { load(keepScroll: true) }
    }

    // MARK: Browser (the browser block: a web page with its bar)

    private(set) var browserBar: BrowserBar?
    private var pageObservations: [NSKeyValueObservation] = []

    private func makeBrowserBar() {
        let bar = BrowserBar()
        bar.translatesAutoresizingMaskIntoConstraints = false
        addSubview(bar)
        NSLayoutConstraint.activate([
            bar.leadingAnchor.constraint(equalTo: leadingAnchor), bar.trailingAnchor.constraint(equalTo: trailingAnchor),
            bar.topAnchor.constraint(equalTo: topAnchor), bar.heightAnchor.constraint(equalToConstant: BrowserBar.height),
        ])
        bar.apply(background: theme.background.nsColor)
        bar.onBack = { [weak self] in self?.browserBack() }
        bar.onForward = { [weak self] in self?.browserForward() }
        bar.onReload = { [weak self] in self?.web.reload() }
        bar.onStop = { [weak self] in self?.web.stopLoading() }
        bar.onOpenExternally = { [weak self] in
            guard let self, self.pageURL.scheme == "http" || self.pageURL.scheme == "https" else { return }
            NSWorkspace.shared.open(self.pageURL)
        }
        bar.onNavigate = { [weak self] typed in
            guard let self else { return }
            if let url = BrowserBar.destination(typed, search: ConfigStore.shared.config.browserSearch) { self.browse(to: url) }
            self.window?.makeFirstResponder(self.web)
            self.updateBar()
        }
        browserBar = bar
    }

    /// The page's title, address, history and loading follow into the bar and the tab.
    private func observePage() {
        pageObservations = [
            web.observe(\.title) { [weak self] _, _ in DispatchQueue.main.async { self?.onTitleChange?() } },
            web.observe(\.url) { [weak self] _, _ in DispatchQueue.main.async { self?.updateBar(); self?.onTitleChange?() } },
            web.observe(\.canGoBack) { [weak self] _, _ in DispatchQueue.main.async { self?.updateBar() } },
            web.observe(\.canGoForward) { [weak self] _, _ in DispatchQueue.main.async { self?.updateBar() } },
            web.observe(\.isLoading) { [weak self] _, _ in DispatchQueue.main.async { self?.updateBar() } },
            web.observe(\.estimatedProgress) { [weak self] _, _ in DispatchQueue.main.async { self?.updateBar() } },
        ]
        updateBar()
    }

    private func updateBar() {
        browserBar?.show(url: web.url ?? (url.absoluteString == "about:blank" ? nil : url), canGoBack: web.canGoBack,
                         canGoForward: web.canGoForward, loading: web.isLoading, progress: web.estimatedProgress)
    }

    /// Where the page is now (it moves; `url` is where it started). What a
    /// saved layout brings back.
    var pageURL: URL { kind == .web ? (web.url ?? url) : url }

    func browse(to destination: URL) {
        guard kind == .web else { return }
        web.load(URLRequest(url: destination))
    }

    func browserBack() { if web.canGoBack { web.goBack() } }
    func browserForward() { if web.canGoForward { web.goForward() } }

    /// ⌘L in a browser.
    func focusAddress() { browserBar?.focusAddress() }

    /// Run `script` in the page (`+browser eval`, text, click…): its value, or
    /// what went wrong. `own`: in a world of its own, where the page's scripts
    /// can't stand in for `querySelector` or `innerText` (eval means the page's).
    func pageScript(_ script: String, own: Bool = false, completion: @escaping (Any?, String?) -> Void) {
        web.evaluateJavaScript(script, in: nil, in: own ? .defaultClient : .page) { result in
            switch result {
            case .success(let value): completion(value, nil)
            case .failure(let error): completion(nil, error.localizedDescription)
            }
        }
    }

    // A link or button that wants a file: it goes to Downloads (the page's
    // own; a frame's file isn't something you asked for).
    func webView(_ webView: WKWebView, decidePolicyFor response: WKNavigationResponse,
                 decisionHandler: @escaping (WKNavigationResponsePolicy) -> Void) {
        // Also one the server says to save (Content-Disposition: attachment —
        // an export's CSV, a PDF to keep), even if a page could show it.
        let disposition = (response.response as? HTTPURLResponse)?.value(forHTTPHeaderField: "Content-Disposition") ?? ""
        let attachment = disposition.trimmingCharacters(in: .whitespaces).lowercased().hasPrefix("attachment")
        decisionHandler(kind == .web && response.isForMainFrame && (!response.canShowMIMEType || attachment) ? .download : .allow)
    }

    /// Where each download is going; and every browser's, so two at once never pick one name.
    private var downloadTargets: [ObjectIdentifier: URL] = [:]
    private static var downloading: Set<String> = []

    func webView(_ webView: WKWebView, navigationAction: WKNavigationAction, didBecome download: WKDownload) { download.delegate = self }
    func webView(_ webView: WKWebView, navigationResponse: WKNavigationResponse, didBecome download: WKDownload) { download.delegate = self }

    func download(_ download: WKDownload, decideDestinationUsing response: URLResponse, suggestedFilename: String,
                  completionHandler: @escaping (URL?) -> Void) {
        let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        // Never over a file that's there: "name 2.ext", "name 3.ext"…
        let name = (suggestedFilename as NSString).lastPathComponent
        let base = (name as NSString).deletingPathExtension, ext = (name as NSString).pathExtension
        var target = downloads.appendingPathComponent(name)
        var n = 2
        while FileManager.default.fileExists(atPath: target.path) || Self.downloading.contains(target.path) {
            target = downloads.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        Self.downloading.insert(target.path)
        downloadTargets[ObjectIdentifier(download)] = target
        completionHandler(target)
    }

    func downloadDidFinish(_ download: WKDownload) {
        guard let target = downloadTargets.removeValue(forKey: ObjectIdentifier(download)) else { return }
        Self.downloading.remove(target.path)
        // The Dock's Downloads stack bounces for it, as for Safari's.
        DistributedNotificationCenter.default().post(name: .init("com.apple.DownloadFileFinished"), object: target.path)
    }

    func download(_ download: WKDownload, didFailWithError error: Error, resumeData: Data?) {
        let target = downloadTargets.removeValue(forKey: ObjectIdentifier(download))
        if let target { Self.downloading.remove(target.path) }
        guard let window else { return }
        let alert = NSAlert(error: error)
        alert.messageText = "Couldn't download \(target?.lastPathComponent ?? "the file")"
        alert.beginSheetModal(for: window)
    }

    // MARK: Blocks

    /// The tool this block is (nil for files and web pages).
    private(set) var service: BlockService?

    /// A block's page runs its own script (only it: the page's CSP) and calls
    /// its service through `block`; it starts knowing the theme.
    private func makeBlockWeb(_ service: BlockService) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let content = WKUserContentController()
        content.addScriptMessageHandler(BlockBridge(service), contentWorld: .page, name: "block")
        let start: [String: Any] = ["theme": Blocks.theme(theme), "params": [:]]
        if let data = try? JSONSerialization.data(withJSONObject: start), let json = String(data: data, encoding: .utf8) {
            content.addUserScript(WKUserScript(source: "window.__blockInit = \(json);", injectionTime: .atDocumentStart,
                                               forMainFrameOnly: true))
        }
        configuration.userContentController = content
        return WKWebView(frame: .zero, configuration: configuration)
    }

    private func loadBlock() {
        guard let page = Blocks.page(for: url), let root = Blocks.root else { return }
        // Its folder and the fonts beside it (Resources, or the repository).
        web.loadFileURL(page, allowingReadAccessTo: root.deletingLastPathComponent())
    }

    /// The theme to the page. Also each time it loads: its start script
    /// holds the theme it was made with, which a reload would bring back.
    private func sendBlockTheme() {
        guard let data = try? JSONSerialization.data(withJSONObject: Blocks.theme(theme)),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("window.block && block.setTheme(\(json))")
    }

    /// A command finished in a terminal (any window's): a block showing git
    /// (or files) reads again.
    @objc private func commandFinished(_ note: Notification) { service?.promptArrived() }

    // MARK: The page (a viewer, or the editor)

    /// A file is shown, never run; a web page is an app and needs its scripts.
    private static func makeViewerWeb(_ kind: Kind) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = kind == .web
        // A new window only from a click, never from a script by itself.
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.suppressesIncrementalRendering = kind != .web
        return WKWebView(frame: .zero, configuration: configuration)
    }

    /// The editor runs its own script (and only it: the page's CSP), and
    /// talks to this view through `libertty` messages.
    private func makeEditorWeb() -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.defaultWebpagePreferences.allowsContentJavaScript = true
        let content = WKUserContentController()
        content.add(EditorMessages(self), name: "libertty")
        configuration.userContentController = content
        return WKWebView(frame: .zero, configuration: configuration)
    }

    /// Put `page` in place of the one showing (switching between viewer and editor).
    private func install(_ page: WKWebView) {
        let old = web
        let hadFocus = old.window?.firstResponder.map { ($0 as? NSView)?.isDescendant(of: old) ?? false } ?? false
        old.navigationDelegate = nil
        old.uiDelegate = nil
        old.configuration.userContentController.removeScriptMessageHandler(forName: "libertty")
        old.removeFromSuperview()
        web = page
        page.navigationDelegate = self
        page.uiDelegate = self
        page.setValue(false, forKey: "drawsBackground")  // the page paints the theme background
        page.allowsMagnification = !isEditing
        if Probe.running { Self.keepRendering(page) }
        page.translatesAutoresizingMaskIntoConstraints = false
        addSubview(page, positioned: .below, relativeTo: nil)
        NSLayoutConstraint.activate([
            page.leadingAnchor.constraint(equalTo: leadingAnchor), page.trailingAnchor.constraint(equalTo: trailingAnchor),
            // A browser's page sits under its bar.
            page.topAnchor.constraint(equalTo: browserBar?.bottomAnchor ?? topAnchor), page.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        loaded = false
        if hadFocus { window?.makeFirstResponder(page) }
    }

    /// `--ui-probe`'s window is off screen, so WebKit takes it as hidden and
    /// stops the page's animation frames (CodeMirror measures in them): a
    /// probe keeps it drawing as if it were in view.
    private static func keepRendering(_ page: WKWebView) {
        let selector = NSSelectorFromString("_setWindowOcclusionDetectionEnabled:")
        guard page.responds(to: selector), let method = class_getInstanceMethod(type(of: page), selector) else { return }
        typealias Setter = @convention(c) (AnyObject, Selector, Bool) -> Void
        unsafeBitCast(method_getImplementation(method), to: Setter.self)(page, selector, false)
    }

    // MARK: Editing (the editor block: CodeMirror 6)

    /// Whether a text file opens in the editor: source files and plain text
    /// do (`edit-source-files`), Markdown shown rendered and diffs don't.
    static func wantsEditor(_ url: URL, renderMarkdown: Bool) -> Bool {
        guard ConfigStore.shared.config.editSourceFiles, kind(of: url) == .text else { return false }
        if isMarkdown(url) && renderMarkdown { return false }
        return !["diff", "patch"].contains(url.pathExtension.lowercased())
    }

    /// In the editor (⌘S saves) rather than shown as a page.
    private(set) var isEditing = false
    /// What's in the editor differs from the file as last saved or loaded.
    private(set) var hasUnsavedChanges = false
    /// Editing began or ended, or unsaved changes came or went (the tab's name says so).
    var onEditingStateChange: ((DocumentView) -> Void)?
    /// `libertty +open --wait`: who's waiting for this editor to close (each
    /// hears it when it does).
    private(set) var waitTokens: Set<String> = []
    func addWaiter(_ token: String?) { if let token { waitTokens.insert(token) } }
    /// Closed: hand back who was waiting, and forget them.
    func takeWaiters() -> Set<String> {
        defer { waitTokens = [] }
        return waitTokens
    }
    /// Where the cursor is, 1-based.
    private(set) var cursor = (line: 1, column: 1)
    private var editorReady = false
    private var pendingEditorLine: Int?
    /// The file as this view last read or wrote it (nil: not on disk). What
    /// the watcher compares with, so our own save isn't news, and what a save
    /// checks so it never overwrites a change the editor hasn't seen.
    private var diskText: String?
    private var fileMissing = false
    /// The file's encoding (and byte-order mark), kept when saving. Only
    /// UTF-8 and UTF-16 with a mark are editable: anything else is shown
    /// read-only, since writing it back as Unicode would mangle it.
    private var encoding: String.Encoding = .utf8
    private var byteOrderMark = Data()
    private var editableEncoding = true
    /// The editor's unsaved text, a second behind (it survives the page's process dying).
    private var backupText: String?

    /// Open in the editor, or back to the page (keeping no unsaved text:
    /// the caller asks first, or `leaveEditor` saves).
    func setEditing(_ on: Bool) {
        guard kind == .text, on != isEditing, on == false || (EditorAssets.page != nil && EditorAssets.canEdit(url)) else { return }
        isEditing = on
        editorReady = false
        hasUnsavedChanges = false
        backupText = nil
        if Self.isMarkdown(url) { syncShowsSource(on) }
        rendered = !on && renderSetting && Self.isMarkdown(url) && !showsSource
        install(on ? makeEditorWeb() : Self.makeViewerWeb(kind))
        load(keepScroll: false)
        onEditingStateChange?(self)
    }

    /// The file's text in its own encoding; nil when it can't be read (gone, mid-replace).
    private func readFile() -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        byteOrderMark = Data()
        // UTF-8's mark is kept for the save (decoding would drop it).
        let utf8Mark: [UInt8] = [0xEF, 0xBB, 0xBF]
        let utf8Body = data.starts(with: utf8Mark) ? data.dropFirst(utf8Mark.count) : data[...]
        if let text = String(data: utf8Body, encoding: .utf8) {
            encoding = .utf8
            if utf8Body.count < data.count { byteOrderMark = Data(utf8Mark) }
            editableEncoding = true
            return text
        }
        for (mark, coding) in [([0xFF, 0xFE] as [UInt8], String.Encoding.utf16LittleEndian), ([0xFE, 0xFF], .utf16BigEndian)]
        where data.starts(with: mark) {
            if let text = String(data: data.dropFirst(2), encoding: coding) {
                encoding = coding
                byteOrderMark = Data(mark)
                editableEncoding = true
                return text
            }
        }
        encoding = .isoLatin1
        editableEncoding = false
        return String(data: data, encoding: .isoLatin1)
    }

    /// The editor gets the file (first load), or hears it changed on disk.
    private func loadEditor() {
        if !loaded, web.url == nil, let page = EditorAssets.page, let access = EditorAssets.readAccess {
            web.loadFileURL(page, allowingReadAccessTo: access)
            return
        }
        guard editorReady else { return }
        guard let text = readFile() else {
            // Gone (deleted, or a branch switch replacing it): keep the text,
            // and look out for the file coming back.
            if !fileMissing {
                fileMissing = true
                diskText = nil
                runEditor("libertty.diskGone()")
            }
            return watchForReturn()
        }
        fileMissing = false
        // Our own save (or a touch): nothing new.
        guard text != diskText else { return }
        diskText = text
        runEditor("libertty.diskChanged(\(Self.jsString(text)))")
    }

    private func sendFileToEditor() {
        let text = readFile()
        diskText = text
        fileMissing = text == nil
        let body = text ?? ""
        let indent = body.contains("\n\t") ? "\t" : "    "
        var options: [String: Any] = [
            "text": body, "theme": EditorAssets.theme(theme, fontSize: ConfigStore.shared.config.fontSize),
            "keymap": ConfigStore.shared.config.editorKeymap, "crlf": body.contains("\r\n"), "indent": indent,
            "readOnly": !editableEncoding || !FileManager.default.isWritableFile(atPath: url.path),
        ]
        if let language = EditorAssets.language(for: url) { options["language"] = language }
        if let line = pendingEditorLine { options["line"] = line }
        pendingEditorLine = nil
        guard let data = try? JSONSerialization.data(withJSONObject: options),
              let json = String(data: data, encoding: .utf8) else { return }
        runEditor("libertty.load(\(json))")
        // Back after the page's process died: the unsaved text it had.
        if let backup = backupText, backup != body { runEditor("libertty.restore(\(Self.jsString(backup)))") }
        if fileMissing { runEditor("libertty.diskGone()") }
    }

    /// The editor's keys and theme follow the settings.
    func applyEditorSettings() {
        guard isEditing, editorReady else { return }
        let config = ConfigStore.shared.config
        runEditor("libertty.setKeymap(\(Self.jsString(config.editorKeymap)))")
        if let data = try? JSONSerialization.data(withJSONObject: EditorAssets.theme(theme, fontSize: config.fontSize)),
           let json = String(data: data, encoding: .utf8) {
            runEditor("libertty.setTheme(\(json))")
        }
    }

    private func runEditor(_ script: String, completion: ((Any?) -> Void)? = nil) {
        web.evaluateJavaScript(script) { value, _ in completion?(value) }
    }

    /// A string as a JavaScript literal.
    private static func jsString(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]),
              let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    /// From the page (EditorMessages).
    func editorMessage(_ type: String, _ body: [String: Any]) {
        switch type {
        case "ready":
            editorReady = true
            loaded = true
            sendFileToEditor()
        case "dirty":
            let dirty = body["dirty"] as? Bool ?? false
            if !dirty { backupText = nil }
            guard dirty != hasUnsavedChanges else { return }
            hasUnsavedChanges = dirty
            onEditingStateChange?(self)
        case "backup":
            backupText = body["text"] as? String
        case "save":
            guard let text = body["text"] as? String else { return }
            let close = body["close"] as? Bool == true
            write(text) { [weak self] ok in
                guard let self, ok else { return }
                self.runEditor("libertty.saved()")
                guard close else { return }
                // Saved (vim's :wq): closing mustn't ask about the changes the
                // page hasn't yet said are gone.
                if self.hasUnsavedChanges {
                    self.hasUnsavedChanges = false
                    self.onEditingStateChange?(self)
                }
                self.onRequestClose?(self)
            }
        case "close":
            onRequestClose?(self)
        case "cursor":
            cursor = (body["line"] as? Int ?? 1, body["column"] as? Int ?? 1)
        default:
            break
        }
    }

    /// File ▸ Save (⌘S): write what's in the editor. `completion` says whether it's on disk.
    func save(completion: ((Bool) -> Void)? = nil) {
        if kind == .block {
            guard let service else { completion?(true); return }
            service.save { completion?($0) }
            return
        }
        guard isEditing, editorReady else { completion?(!hasUnsavedChanges); return }
        runEditor("libertty.takeText()") { [weak self] value in
            guard let self, let text = value as? String else { completion?(false); return }
            self.write(text) { ok in
                if ok { self.runEditor("libertty.saved()") }
                completion?(ok)
            }
        }
    }

    @objc func saveDocument(_ sender: Any?) { save() }

    /// Write `text` over the file — after asking, when the file changed on
    /// disk in a way the editor hasn't taken, or when the text no longer
    /// fits the file's encoding. Through a replacement file when that keeps
    /// everything (so a crash mid-write leaves the old file whole); in place
    /// for a hard-linked file or one in a folder we can't write.
    private func write(_ text: String, checked: Bool = false, completion: @escaping (Bool) -> Void) {
        guard editableEncoding else {
            ask("“\(url.lastPathComponent)” isn't UTF-8", "Libertty shows it read-only: writing it back would change its other characters.",
                buttons: ["OK"]) { _ in completion(false) }
            return
        }
        if !checked, !fileMissing, let now = readFileQuietly(), now != diskText {
            ask("“\(url.lastPathComponent)” changed on disk", "Another program changed it since it opened here. Save over its changes?",
                buttons: ["Overwrite", "Cancel"]) { [weak self] button in
                if button == 0 { self?.write(text, checked: true, completion: completion) } else { completion(false) }
            }
            return
        }
        guard let body = text.data(using: encoding) else {
            let name = encoding == .utf8 ? "UTF-8" : "UTF-16"
            ask("“\(url.lastPathComponent)” can't hold some characters", "It's \(name); save it as UTF-8 instead?",
                buttons: ["Save as UTF-8", "Cancel"]) { [weak self] button in
                guard let self, button == 0 else { return completion(false) }
                self.encoding = .utf8
                self.byteOrderMark = Data()
                self.write(text, checked: true, completion: completion)
            }
            return
        }
        let data = byteOrderMark + body
        let target = url.resolvingSymlinksInPath()
        let fm = FileManager.default
        do {
            if fm.fileExists(atPath: target.path) {
                let links = (try? fm.attributesOfItem(atPath: target.path)[.referenceCount] as? Int) ?? 1
                if links <= 1, fm.isWritableFile(atPath: target.deletingLastPathComponent().path) {
                    let scratch = try fm.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
                    let temp = scratch.appendingPathComponent(target.lastPathComponent)
                    try data.write(to: temp)
                    _ = try fm.replaceItemAt(target, withItemAt: temp)
                    try? fm.removeItem(at: scratch)
                } else {
                    let handle = try FileHandle(forWritingTo: target)
                    defer { try? handle.close() }
                    try handle.truncate(atOffset: 0)
                    try handle.write(contentsOf: data)
                }
            } else {
                try data.write(to: target, options: .atomic)
                fileMissing = false
                watch()
            }
            diskText = text
            backupText = nil
            completion(true)
        } catch {
            ask("Couldn't save “\(url.lastPathComponent)”", error.localizedDescription, buttons: ["OK"]) { _ in completion(false) }
        }
    }

    /// What's on disk now, without changing what we think its encoding is.
    private func readFileQuietly() -> String? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(data: data.dropFirst(byteOrderMark.count), encoding: encoding)
    }

    /// A sheet over the window (or an alert without one); `done` gets the button's index.
    private func ask(_ title: String, _ message: String, buttons: [String], done: @escaping (Int) -> Void) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        buttons.forEach { alert.addButton(withTitle: $0) }
        let index = { (response: NSApplication.ModalResponse) in response.rawValue - NSApplication.ModalResponse.alertFirstButtonReturn.rawValue }
        if let window { alert.beginSheetModal(for: window) { done(index($0)) } } else { done(index(alert.runModal())) }
    }

    /// The file went away: look again every second until it's back, then watch it again.
    private func watchForReturn() {
        guard returnPoll == nil else { return }
        let timer = Timer(timeInterval: 1, repeats: true) { [weak self] timer in
            guard let self else { return timer.invalidate() }
            guard FileManager.default.fileExists(atPath: self.url.path) else { return }
            timer.invalidate()
            self.returnPoll = nil
            self.watch()
            self.load(keepScroll: true)
        }
        RunLoop.main.add(timer, forMode: .common)
        returnPoll = timer
    }
    private var returnPoll: Timer?

    /// The page's process died (it can, under memory pressure): load it again;
    /// the editor gets its unsaved text back from `backupText`.
    func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        loaded = false
        // What a block's page hadn't written is gone with it.
        (service as? FileBlock)?.pageStarted()
        if isEditing {
            editorReady = false
            if let page = EditorAssets.page, let access = EditorAssets.readAccess { web.loadFileURL(page, allowingReadAccessTo: access) }
        } else {
            load(keepScroll: true)
        }
    }

    /// `--ui-probe`: type at the editor's cursor, and read what it holds.
    func editorInsert(_ text: String) { runEditor("libertty.insert(\(Self.jsString(text)))") }
    func editorText(_ completion: @escaping (String?) -> Void) { runEditor("libertty.text()") { completion($0 as? String) } }
    var isEditorReady: Bool { editorReady }
    func editorEvaluate(_ script: String, _ completion: @escaping (Any?) -> Void) { runEditor(script, completion: completion) }
    /// A web page done loading, as WebKit itself says (`--ui-probe`'s page-wait,
    /// when the page's own script can't be asked yet).
    var pageLoaded: Bool { browserBar != nil && !web.isLoading && web.estimatedProgress >= 1 && !(web.title ?? "").isEmpty }
    /// What WebKit says of the page, for a page-wait that gave up.
    var pageState: String {
        "bar \(browserBar != nil), loading \(web.isLoading), progress \(web.estimatedProgress), title \((web.title ?? "").debugDescription), "
            + "url \(web.url?.absoluteString ?? "none"), in a window \(web.window != nil), visible \(web.window?.isVisible ?? false)"
    }
    /// Run a function body in the page, awaited (the probe's `page-js`); an error comes back as its text.
    func pageCall(_ body: String, _ completion: @escaping (Any?) -> Void) {
        web.callAsyncJavaScript(body, arguments: [:], in: nil, in: .page) { result in
            switch result {
            case .success(let value): completion(value)
            case .failure(let error): completion("error: \(error)")
            }
        }
    }

    /// What the page shows, for the tab overview.
    func snapshot(_ completion: @escaping (CGImage?) -> Void) {
        web.takeSnapshot(with: nil) { image, _ in
            completion(image?.cgImage(forProposedRect: nil, context: nil, hints: nil))
        }
    }

    /// Lets the web view take keyboard focus (scrolling with keys, find, copy).
    var focusTarget: NSView { web }

    // MARK: As a pane of a split (dimmed when unfocused, × on hover, like a terminal pane)

    /// The pane's × asks to close it.
    var onRequestClose: ((DocumentView) -> Void)?
    var showsCloseButton = false { didSet { updateCloseButton() } }
    private var hovering = false
    private lazy var dimLayer: CALayer = {
        let l = CALayer()
        l.opacity = 0
        l.zPosition = 1
        wantsLayer = true
        layer?.addSublayer(l)
        return l
    }()
    private lazy var closeButton: NSButton = {
        let b = NSButton(image: NSImage(systemSymbolName: "xmark", accessibilityDescription: "Close Pane")!,
                         target: self, action: #selector(closeButtonClicked(_:)))
        b.isBordered = false
        b.bezelStyle = .circular
        b.symbolConfiguration = .init(pointSize: 10, weight: .semibold)
        b.contentTintColor = .secondaryLabelColor
        b.toolTip = "Close Pane (⌘W)"
        b.wantsLayer = true
        b.layer?.cornerRadius = 11
        b.isHidden = true
        b.alphaValue = 0
        addSubview(b)
        b.layer?.zPosition = 2
        return b
    }()

    /// The focused pane of a split: the accent line along its top, as a
    /// terminal pane shows (TerminalView.showsFocusLine).
    var showsFocusLine = false {
        didSet {
            guard showsFocusLine != oldValue else { return }
            focusLine.isHidden = !showsFocusLine
            needsLayout = true
        }
    }

    private lazy var focusLine: NSView = {
        let line = NSView()
        line.wantsLayer = true
        line.layer?.backgroundColor = Accent.color.cgColor
        line.isHidden = true
        addSubview(line)
        return line
    }()

    func setDimmed(_ dimmed: Bool, opacity: CGFloat, color: NSColor) {
        dimLayer.backgroundColor = color.cgColor
        let target: Float = dimmed ? Float(1 - opacity) : 0
        guard dimLayer.opacity != target else { return }
        let animation = CABasicAnimation(keyPath: "opacity")
        animation.fromValue = dimLayer.presentation()?.opacity ?? dimLayer.opacity
        animation.toValue = target
        animation.duration = Motion.duration(Motion.hover)
        animation.timingFunction = Motion.ease
        dimLayer.opacity = target
        dimLayer.add(animation, forKey: "opacity")
    }

    override func layout() {
        super.layout()
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        dimLayer.frame = bounds
        CATransaction.commit()
        if showsCloseButton { closeButton.frame = closeFrame }
        if showsFocusLine { focusLine.frame = NSRect(x: 0, y: bounds.height - 1, width: bounds.width, height: 1) }
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        if showsFocusLine { focusLine.layer?.backgroundColor = Accent.color.cgColor }
        // (Asked only while it shows: asking makes the button.)
        if showsCloseButton && hovering { updateCloseButtonColor() }
    }

    /// The × button's disc, in the appearance the pane has now.
    private func updateCloseButtonColor() {
        effectiveAppearance.performAsCurrentDrawingAppearance {
            closeButton.layer?.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.85).cgColor
        }
    }

    private var closeFrame: NSRect { NSRect(x: bounds.width - 30, y: bounds.height - 30, width: 22, height: 22) }

    private func updateCloseButton() {
        let show = showsCloseButton && hovering
        if show {
            updateCloseButtonColor()
            closeButton.isHidden = false
        }
        closeButton.frame = closeFrame
        NSAnimationContext.runAnimationGroup({ ctx in
            ctx.duration = Motion.duration(Motion.hover)
            closeButton.animator().alphaValue = show ? 1 : 0
        }, completionHandler: { [weak self] in
            if !show, self?.hovering == false || self?.showsCloseButton == false { self?.closeButton.isHidden = true }
        })
    }

    @objc private func closeButtonClicked(_ sender: Any?) { onRequestClose?(self) }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero, options: [.mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                       owner: self, userInfo: nil))
    }

    override func mouseEntered(with event: NSEvent) {
        hovering = true
        if showsCloseButton { updateCloseButton() }
    }

    override func mouseExited(with event: NSEvent) {
        hovering = false
        if showsCloseButton || !closeButton.isHidden { updateCloseButton() }
    }

    var isMarkdown: Bool { Self.isMarkdown(url) }

    func apply(theme: Theme, renderMarkdown: Bool, force: Bool = false) {
        renderSetting = renderMarkdown
        browserBar?.apply(background: theme.background.nsColor)
        if kind == .block {
            guard force || theme != self.theme else { return }
            self.theme = theme
            return sendBlockTheme()
        }
        if isEditing {
            guard force || theme != self.theme else { return }
            self.theme = theme
            guard editorReady, let data = try? JSONSerialization.data(withJSONObject: EditorAssets.theme(theme, fontSize: ConfigStore.shared.config.fontSize)),
                  let json = String(data: data, encoding: .utf8) else { return }
            return runEditor("libertty.setTheme(\(json))")
        }
        // A web page and a PDF aren't drawn in the theme's colors: loading
        // them again would lose what's in them (a form, a scroll, the page).
        if kind == .web || kind == .pdf {
            self.theme = theme
            return
        }
        let render = renderMarkdown && Self.isMarkdown(url) && !showsSource
        guard force || theme != self.theme || render != rendered else { return }
        self.theme = theme
        rendered = render
        load(keepScroll: true)
    }

    // MARK: Rendering

    private func load(keepScroll: Bool) {
        if kind == .block { return loadBlock() }
        if isEditing { return loadEditor() }
        guard keepScroll else { return show(scroll: nil) }
        // A reload under way already knows where the reader was (the new
        // page, at the top until it's done, would say 0).
        if !loaded, let y = pendingScroll { return show(scroll: y) }
        web.evaluateJavaScript("window.scrollY") { [weak self] value, _ in
            self?.show(scroll: value as? Double)
        }
    }

    private var isDiff: Bool { ["diff", "patch"].contains(url.pathExtension.lowercased()) && !showsSource }

    private func show(scroll: Double?) {
        switch kind {
        case .web:
            if web.url == nil { web.load(URLRequest(url: url)) } else { web.reload() }
            return
        case .pdf:
            // WebKit shows PDFs itself.
            web.loadFileURL(url, allowingReadAccessTo: url)
            return
        case .block:
            return loadBlock()
        case .image, .text:
            break
        }
        let body: String
        if kind == .image {
            // Changed on disk: a new URL, so the new pixels show.
            let stamp = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?.contentModificationDate?.timeIntervalSince1970 ?? 0
            body = "<div class=\"image-view\"><img src=\"\(MarkdownRenderer.escapeAttribute(url.absoluteString))?v=\(stamp)\"></div>"
        } else {
            let text = (try? String(contentsOf: url, encoding: .utf8))
                ?? (try? String(contentsOf: url, encoding: .isoLatin1)) ?? ""
            if rendered {
                var renderer = MarkdownRenderer { code, lang in Highlighter.html(code, language: lang) }
                body = "<article class=\"md\">\(renderer.render(text))</article>"
            } else if isDiff {
                body = DiffRenderer.html(text)
            } else {
                body = Self.codeView(text, language: Highlighter.language(forFile: url.lastPathComponent))
            }
        }
        let dir = url.deletingLastPathComponent()
        let html = """
            <!doctype html><html><head><meta charset="utf-8">
            <base href="\(MarkdownRenderer.escapeAttribute(dir.absoluteString))">
            <style>\(Self.css(theme))</style></head><body>\(body)</body></html>
            """
        pendingScroll = scroll
        loaded = false
        // A file URL (not loadHTMLString) so relative images next to the
        // document can load; the page itself lives in a private temp file.
        let file = htmlFile ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("libertty-doc-\(UUID().uuidString).html")
        htmlFile = file
        do {
            try html.write(to: file, atomically: true, encoding: .utf8)
            web.loadFileURL(file, allowingReadAccessTo: URL(fileURLWithPath: "/"))
        } catch {
            web.loadHTMLString(html, baseURL: dir)
        }
    }

    private static func codeView(_ text: String, language: String) -> String {
        let highlighted = Highlighter.html(text, language: language)
        let lines = highlighted.components(separatedBy: "\n")
        var rows = ""
        rows.reserveCapacity(highlighted.count + lines.count * 40)
        for (n, line) in lines.enumerated() {
            rows += "<span class=\"ln\" id=\"L\(n + 1)\" data-n=\"\(n + 1)\"></span>\(line)\n"
        }
        return "<pre class=\"source\"><code>\(rows)</code></pre>"
    }

    func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
        loaded = true
        if kind == .block {
            sendBlockTheme()
            (service as? FileBlock)?.pageStarted()
        }
        if let line = pendingLine {
            pendingLine = nil
            pendingScroll = nil
            return reveal(line: line)
        }
        if let y = pendingScroll { webView.evaluateJavaScript("window.scrollTo(0, \(y))") }
        pendingScroll = nil
    }

    private var loaded = false
    private var pendingLine: Int?

    /// Scroll a source file to `line` and mark it (⌘-click on `file:line`).
    /// Markdown shown rendered has no lines: it switches to its source.
    func reveal(line: Int) {
        if isEditing {
            guard editorReady else { pendingEditorLine = line; return }
            return runEditor("libertty.goToLine(\(line))")
        }
        if rendered {
            if Self.editsMarkdownSource { pendingEditorLine = line } else { pendingLine = line }
            showsSource = true
            return
        }
        guard loaded else { pendingLine = line; return }
        let js = """
            (function(){var e=document.getElementById('L\(line)');if(!e)return;
            var o=document.querySelector('.hl-line');if(o)o.remove();
            var r=e.getBoundingClientRect(),d=document.createElement('div');d.className='hl-line';
            d.style.top=(r.top+window.scrollY)+'px';d.style.height=r.height+'px';document.body.appendChild(d);
            window.scrollTo(0,Math.max(0,r.top+window.scrollY-window.innerHeight/3));})()
            """
        web.evaluateJavaScript(js)
    }

    func webView(_ webView: WKWebView, decidePolicyFor action: WKNavigationAction,
                 decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if kind == .web {
            // A web app moves around inside itself; other schemes go to their apps.
            // A link that says to save what it leads to (`<a download>`, a web
            // app's Export): to Downloads, not over the page.
            if action.shouldPerformDownload { return decisionHandler(.download) }
            guard let target = action.request.url, let scheme = target.scheme?.lowercased(),
                  !["http", "https", "about", "data", "blob"].contains(scheme) else { return decisionHandler(.allow) }
            decisionHandler(.cancel)
            openElsewhere(target, clicked: action.navigationType == .linkActivated)
            return
        }
        // A block's page and the editor's load once and stay: nothing navigates them away.
        if kind == .block {
            let page = action.request.url?.standardizedFileURL == Blocks.page(for: url)?.standardizedFileURL
            if !page, action.navigationType == .linkActivated, let target = action.request.url { openFromBlock(target) }
            return decisionHandler(page ? .allow : .cancel)
        }
        if isEditing {
            let page = EditorAssets.page
            return decisionHandler(action.request.url?.standardizedFileURL == page?.standardizedFileURL ? .allow : .cancel)
        }
        guard action.navigationType == .linkActivated, let target = action.request.url else {
            return decisionHandler(.allow)
        }
        // In-page anchors scroll; everything else leaves the page.
        if target.isFileURL, let htmlFile, target.path == htmlFile.path { return decisionHandler(.allow) }
        // "#install" resolves against the page's <base> (the document's
        // folder), not the page: it's this page's anchor all the same.
        if target.isFileURL, let fragment = target.fragment, !fragment.isEmpty,
           [url.deletingLastPathComponent().path, url.path].contains(target.standardizedFileURL.path) {
            decisionHandler(.cancel)
            return scroll(toAnchor: fragment.removingPercentEncoding ?? fragment)
        }
        decisionHandler(.cancel)
        if target.isFileURL, Self.canShow(target), FileManager.default.fileExists(atPath: target.path) {
            onOpenDocument?(target)
        } else if target.isFileURL {
            confirmOpeningFile(target)
        } else {
            NSWorkspace.shared.open(target)
        }
    }

    /// A link in a document to a local file Libertty can't show: a README's
    /// `install.command` or an app would run on one click (a cloned repo's
    /// files carry no quarantine for Gatekeeper to ask), so it asks first.
    /// A folder is shown in Finder.
    private func confirmOpeningFile(_ target: URL) {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: target.path, isDirectory: &isDirectory) else { return NSSound.beep() }
        let package = NSWorkspace.shared.isFilePackage(atPath: target.path)
        if isDirectory.boolValue, !package { return NSWorkspace.shared.activateFileViewerSelecting([target]) }
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = "Open “\(target.lastPathComponent)”?"
        alert.informativeText = "This document links to it. If it's a program or a script, opening it runs it.\n\n"
            + (target.path as NSString).abbreviatingWithTildeInPath
        alert.addButton(withTitle: "Show in Finder")
        alert.addButton(withTitle: "Cancel")
        alert.addButton(withTitle: "Open")
        alert.beginSheetModal(for: window) { response in
            switch response {
            case .alertFirstButtonReturn: NSWorkspace.shared.activateFileViewerSelecting([target])
            case .alertThirdButtonReturn: NSWorkspace.shared.open(target)
            default: break
            }
        }
    }

    /// Scroll to the element with this id (a heading's anchor).
    private func scroll(toAnchor id: String) {
        guard let data = try? JSONSerialization.data(withJSONObject: [id]),
              let quoted = String(data: data, encoding: .utf8)?.dropFirst().dropLast() else { return }
        web.evaluateJavaScript("var e=document.getElementById(\(quoted));if(e)e.scrollIntoView();")
    }

    /// A page opening a new window (target=_blank): the browser gets it.
    func webView(_ webView: WKWebView, createWebViewWith configuration: WKWebViewConfiguration,
                 for action: WKNavigationAction, windowFeatures: WKWindowFeatures) -> WKWebView? {
        // A browser opens it in a tab of its own (this page stays); a
        // document's link leaves for the default browser.
        guard let target = action.request.url else { return nil }
        if kind == .web, ["http", "https"].contains(target.scheme?.lowercased() ?? "") {
            if let onOpenBrowser { onOpenBrowser(target) } else { webView.load(URLRequest(url: target)) }
        } else if kind == .web {
            openElsewhere(target, clicked: action.navigationType == .linkActivated)
        } else if kind == .block {
            openFromBlock(target)
        } else {
            NSWorkspace.shared.open(target)
        }
        return nil
    }

    /// A link in what a block shows (a drawing's, a notebook's): someone
    /// else's, maybe. A web page opens in the browser block; anything else
    /// only after asking, and never a file.
    private func openFromBlock(_ target: URL) {
        if ["http", "https"].contains(target.scheme?.lowercased() ?? "") {
            onOpenBrowser?(target)
        } else {
            openElsewhere(target, clicked: true)
        }
    }

    /// A page's link to another app (`zoommtg:`, `mailto:`, `vscode:`): only
    /// when clicked, and after asking which app it opens, as Safari does.
    /// Never `file:` (a page doesn't get to this Mac's files) and nothing a
    /// script or a hidden frame starts by itself (`smb:` would mount a share).
    private func openElsewhere(_ target: URL, clicked: Bool) {
        guard clicked, target.scheme?.lowercased() != "file",
              let app = NSWorkspace.shared.urlForApplication(toOpen: target), let window else { return }
        let alert = NSAlert()
        let name = FileManager.default.displayName(atPath: app.path).replacingOccurrences(of: ".app", with: "")
        alert.messageText = "Open this link in “\(name)”?"
        alert.informativeText = String(target.absoluteString.prefix(300))
        alert.addButton(withTitle: "Open")
        alert.addButton(withTitle: "Cancel")
        alert.beginSheetModal(for: window) { response in
            if response == .alertFirstButtonReturn { NSWorkspace.shared.open(target) }
        }
    }

    // MARK: Find and zoom

    /// The editor finds with its own panel (it draws only the lines in view,
    /// so the page's find would miss the rest).
    func openEditorFind() { runEditor("libertty.find()") }

    func find(_ text: String, backwards: Bool, completion: @escaping (Bool) -> Void) {
        guard !text.isEmpty else { return completion(false) }
        let configuration = WKFindConfiguration()
        configuration.backwards = backwards
        configuration.wraps = true
        configuration.caseSensitive = false
        web.find(text, configuration: configuration) { result in completion(result.matchFound) }
    }

    func zoom(by delta: Double) {
        web.pageZoom = min(3, max(0.5, web.pageZoom + delta * 0.1))
    }

    func resetZoom() { web.pageZoom = 1 }

    // MARK: Live reload

    private func watch() {
        watcher?.cancel()
        let fd = open(url.path, O_EVTONLY)
        // Not there right now (mid-replace, a branch switch): watch for it to come back.
        guard fd >= 0 else { return watchForReturn() }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend],
                                                               queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            // Editors save by replacing the file: follow the new one.
            if source.data.contains(.rename) || source.data.contains(.delete) {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    self.watch()
                    // Still gone (a branch switch): the page stays as it was
                    // until the file is back, so its scroll is kept for it.
                    // (The editor hears it's gone: its text is unsaved now.)
                    if self.isEditing || FileManager.default.fileExists(atPath: self.url.path) { self.load(keepScroll: true) }
                }
            } else {
                self.load(keepScroll: true)
            }
        }
        source.setCancelHandler { close(fd) }
        source.resume()
        watcher = source
    }

    // MARK: Style

    /// Tern's document styling (its `.md` CSS and design tokens), on the
    /// terminal theme's background, with code colored from its palette.
    private static func css(_ t: Theme) -> String {
        let dark = t.isDark
        let bg = t.background.hexString, fg = t.foreground.hexString
        func mix(_ a: RGB, _ b: RGB, _ f: Double) -> String {
            func c(_ x: UInt8, _ y: UInt8) -> Int { Int((Double(x) * (1 - f) + Double(y) * f).rounded()) }
            return String(format: "#%02x%02x%02x", c(a.r, b.r), c(a.g, b.g), c(a.b, b.b))
        }
        let t2 = mix(t.foreground, t.background, 0.28), t3 = mix(t.foreground, t.background, 0.45)
        let t4 = mix(t.foreground, t.background, 0.65)
        let l1 = dark ? "rgba(255,255,255,0.07)" : "rgba(24,26,44,0.06)"
        let l2 = dark ? "rgba(255,255,255,0.10)" : "rgba(24,26,44,0.09)"
        let l3 = dark ? "rgba(255,255,255,0.16)" : "rgba(24,26,44,0.16)"
        let codeBg = mix(t.background, dark ? RGB(0, 0, 0) : RGB(0, 0, 0), dark ? 0.35 : 0.025)
        let accent = dark ? "#5a8cff" : "#3d6fff"
        let a = t.ansi
        return """
        :root { color-scheme: \(dark ? "dark" : "light"); --bg: \(bg); --t1: \(fg); --t2: \(t2); --t3: \(t3); --t4: \(t4);
          --l1: \(l1); --l2: \(l2); --l3: \(l3); --code-bg: \(codeBg); --accent: \(accent);
          --sans: -apple-system, 'SF Pro Text', system-ui, sans-serif;
          --mono: 'JetBrainsMono Nerd Font', 'JetBrains Mono', ui-monospace, 'SF Mono', Menlo, monospace; }
        html { background: var(--bg); }
        body { margin: 0; padding: 12px 40px 64px; color: var(--t1); font: 14.5px/1.7 var(--sans);
          -webkit-font-smoothing: antialiased; }
        ::selection { background: \(t.selection.hexString); }
        .md { max-width: 780px; margin: 0 auto; }
        .md > :first-child { margin-top: 0; }
        .md > :last-child { margin-bottom: 0; }
        .md p { margin: 0 0 12px; }
        .md h1, .md h2, .md h3, .md h4, .md h5, .md h6 { position: relative; margin: 28px 0 10px; font-weight: 600;
          line-height: 1.3; letter-spacing: -0.012em; color: var(--t1); }
        .md h1 { font-size: 26px; letter-spacing: -0.02em; margin-top: 8px; }
        .md h2 { font-size: 19px; padding-top: 16px; box-shadow: inset 0 1px 0 var(--l1); }
        .md h3 { font-size: 16px; }
        .md h4 { font-size: 14.5px; }
        .md h5, .md h6 { font-size: 14px; color: var(--t2); }
        .md .anchor { position: absolute; left: -18px; padding-right: 4px; color: var(--t4); text-decoration: none; }
        .md :is(h1,h2,h3,h4,h5,h6):hover .anchor::before { content: '#'; }
        .md h2 .anchor { top: 16px; }
        .md a { color: var(--accent); text-decoration: none; box-shadow: inset 0 -1px 0 color-mix(in srgb, var(--accent) 30%, transparent); }
        .md a:hover { box-shadow: inset 0 -1px 0 var(--accent); }
        .md strong { font-weight: 600; }
        .md del { color: var(--t3); }
        .md :not(pre) > code { padding: 1px 6px; border-radius: 6px; font: 12.5px/1 var(--mono); background: var(--l2); }
        .md .code { margin: 4px 0 22px; border-radius: 12px; background: var(--code-bg); box-shadow: inset 0 0 0 1px var(--l2); overflow: hidden; }
        .md .code-head { padding: 7px 16px 0; font: 500 11px var(--sans); color: var(--t3); text-transform: lowercase; }
        .md .code pre { margin: 0; padding: 12px 16px 16px; overflow: auto; font: 12.5px/1.7 var(--mono); color: var(--t1); tab-size: 4; }
        .md .code-head + pre { padding-top: 6px; }
        .md :is(ul, ol) { margin: 0 0 12px; padding-left: 22px; }
        .md li { margin: 0 0 6px; padding-left: 4px; }
        .md li > :is(ul, ol) { margin: 6px 0 0; }
        .md li:last-child { margin-bottom: 0; }
        .md ul.tasks { list-style: none; padding-left: 4px; }
        .md li.task { padding-left: 0; list-style: none; }
        .md ul:not(.tasks) > li.task { margin-left: -18px; }
        .md li.task input { margin: 0 8px 0 0; vertical-align: -1px; accent-color: var(--accent); }
        .md blockquote { margin: 0 0 14px; padding: 0 0 0 14px; box-shadow: inset 2px 0 0 var(--l3); color: var(--t2); }
        .md hr { height: 1px; margin: 24px 0; border: 0; background: var(--l2); }
        .md img { max-width: 100%; border-radius: 6px; }
        .image-view { display: flex; align-items: center; justify-content: center; min-height: calc(100vh - 76px); }
        .image-view img { max-width: 100%; max-height: calc(100vh - 76px); object-fit: contain;
          background: repeating-conic-gradient(var(--l2) 0% 25%, transparent 0% 50%) 50% / 16px 16px; }
        \(DiffRenderer.css(dark: dark))
        .md .table { margin: 0 0 16px; overflow-x: auto; }
        .md table { border-collapse: collapse; font-size: 13.5px; line-height: 1.5; }
        .md th, .md td { padding: 5px 16px 5px 0; border-bottom: 1px solid var(--l1); text-align: left; vertical-align: top; }
        .md th { border-bottom-color: var(--l2); font-weight: 550; color: var(--t2); white-space: nowrap; }
        .md td { font-variant-numeric: tabular-nums; }
        .md details { margin: 0 0 12px; }
        .md summary { cursor: default; color: var(--t2); }
        .md kbd { padding: 1px 5px; border-radius: 4px; font: 12px var(--mono); box-shadow: inset 0 -1px 0 var(--l3), 0 0 0 1px var(--l2); }
        pre.source { margin: 0; font: 12.5px/1.65 var(--mono); color: var(--t1); tab-size: 4; counter-reset: ln; }
        body:has(pre.source) { padding: 16px 20px 48px 0; font-size: 12.5px; }
        .hl-line { position: absolute; left: 0; right: 0; pointer-events: none;
          background: color-mix(in srgb, var(--accent) 16%, transparent); }
        pre.source .ln::before { content: attr(data-n); display: inline-block; width: 5ch; margin-right: 2ch;
          text-align: right; color: var(--t4); user-select: none; -webkit-user-select: none; }
        .hl-k { color: \(a[5].hexString); }
        .hl-s { color: \(a[2].hexString); }
        .hl-c { color: var(--t3); font-style: italic; }
        .hl-n { color: \(a[3].hexString); }
        .hl-t { color: \(a[6].hexString); }
        .hl-f { color: \(a[4].hexString); }
        .hl-v { color: \(a[1].hexString); }
        """
    }
}

extension DocumentView: NSMenuItemValidation {
    /// File ▸ Save only means something in the editor.
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        item.action == #selector(saveDocument(_:)) ? isEditing || (service as? FileBlock).map { !type(of: $0).readOnly } == true : true
    }
}

extension DocumentView: BlockHost {
    func send(_ event: String, _ payload: Any) {
        guard let data = try? JSONSerialization.data(withJSONObject: [event, payload]),
              let json = String(data: data, encoding: .utf8) else { return }
        web.evaluateJavaScript("block._emit(...\(json))")
    }

    func titleChanged() { onTitleChange?() }

    func openFile(_ url: URL, line: Int?) {
        onOpenDocumentAt?(url, line) ?? onOpenDocument?(url)
    }

    func terminals() -> [BlockTerminal] { onListTerminals?() ?? [] }
    func reveal(paneID: String) { onRevealPane?(paneID) }
    func openBrowser(_ url: URL) { onOpenBrowser?(url) }
    func editFile(_ url: URL) { onEditDocument?(url) }

    func unsavedChanged(_ unsaved: Bool) {
        hasUnsavedChanges = unsaved
        onEditingStateChange?(self)
    }

    var blockWindow: NSWindow? { window }
}
