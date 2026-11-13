import AppKit
import QuickLookUI
import UniformTypeIdentifiers

/// Quick Look over a pane (Rex's ⌘Y): the files and web pages its screen
/// names, in the system's preview panel, ← and → between them; ⇧⌘-click
/// previews just one. The panel shows only files, so a web link is fetched
/// for it when its turn comes, into a folder of this preview's own that goes
/// when the panel closes.
final class QuickLookPreview: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    final class Item: NSObject, QLPreviewItem {
        let link: TerminalLink
        let url: URL
        /// A web page as saved for the panel; nil until it is.
        fileprivate(set) var saved: URL?
        fileprivate var fetching = false

        init(link: TerminalLink, url: URL) {
            self.link = link
            self.url = url
        }

        var isWeb: Bool { !url.isFileURL }
        var previewItemURL: URL! { isWeb ? saved : url }
        var previewItemTitle: String! { isWeb ? url.absoluteString : url.lastPathComponent }
    }

    let items: [Item]
    /// Where each item's link is on screen, for the panel to zoom from.
    private let frame: (TerminalLink) -> NSRect
    private var folder: URL?
    private var fetches: [URLSessionTask] = []

    /// A pane's links as previews (`remote`: a host's pane, whose files
    /// aren't this Mac's). Starts at the last: what was printed most recently.
    init(_ links: [TerminalLink], remote: Bool, folders: Bool = false, frame: @escaping (TerminalLink) -> NSRect) {
        items = Self.previewable(links, remote: remote, folders: folders)
        self.frame = frame
    }

    /// The files of this Mac that exist and http(s) pages, in order. Not
    /// folders, unless `folders`: every prompt names one.
    static func previewable(_ links: [TerminalLink], remote: Bool, folders: Bool = false) -> [Item] {
        links.compactMap { link in
            guard let url = URL(string: link.url)
                    ?? URL(string: link.url.addingPercentEncoding(withAllowedCharacters: .urlFragmentAllowed) ?? ""),
                  let scheme = url.scheme?.lowercased() else { return nil }
            if scheme == "http" || scheme == "https" { return url.host?.isEmpty == false ? Item(link: link, url: url) : nil }
            guard scheme == "file", !remote else { return nil }
            // An OSC 8 file link names its machine: only this one's.
            if let host = url.host, !host.isEmpty, host != "localhost",
               TerminalSession.path(fromPwd: "file://\(host)/") == nil { return nil }
            var isDirectory: ObjCBool = false
            guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory), folders || !isDirectory.boolValue
            else { return nil }
            return Item(link: link, url: URL(fileURLWithPath: url.path))
        }
    }

    /// What the panel lists, for the UI probe.
    var titles: [String] { items.map { $0.previewItemTitle } }

    var startIndex: Int { max(0, items.count - 1) }

    /// The panel closed: what was fetched for it goes.
    func finish() {
        fetches.forEach { $0.cancel() }
        fetches.removeAll()
        if let folder { try? FileManager.default.removeItem(at: folder) }
        folder = nil
    }

    deinit { finish() }

    // MARK: Data source

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int { items.count }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard items.indices.contains(index) else { return nil }
        let item = items[index]
        if item.isWeb, item.saved == nil { fetch(item, for: panel) }
        return item
    }

    // MARK: Delegate

    /// ← → between the items (↑ ↓ scroll the one shown); Space or the Quick Look key again closes.
    func previewPanel(_ panel: QLPreviewPanel!, handle event: NSEvent!) -> Bool {
        guard let event, event.type == .keyDown, items.count > 0 else { return false }
        if event.charactersIgnoringModifiers == " " || ConfigStore.shared.keybinds.action(for: event) == .quickLook {
            panel.orderOut(nil)
            return true
        }
        let step: Int
        switch Int(event.keyCode) {
        case 123: step = -1  // ←
        case 124: step = 1   // →
        default: return false
        }
        let next = panel.currentPreviewItemIndex + step
        guard items.indices.contains(next) else { return true }
        panel.currentPreviewItemIndex = next
        return true
    }

    func previewPanel(_ panel: QLPreviewPanel!, sourceFrameOnScreenFor item: QLPreviewItem!) -> NSRect {
        guard let item = item as? Item else { return .zero }
        return frame(item.link)
    }

    // MARK: Web pages

    /// The most a page may be: a glance, not a download.
    static let maxBytes = 25 << 20

    private func fetch(_ item: Item, for panel: QLPreviewPanel) {
        guard !item.fetching else { return }
        item.fetching = true
        let folder = self.folder ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("libertty-quicklook-\(UUID().uuidString)", isDirectory: true)
        self.folder = folder
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let index = items.firstIndex(of: item) ?? 0
        let task = PageFetch.start(item.url, limit: Self.maxBytes) { [weak self, weak panel] result in
            DispatchQueue.main.async {
                guard let self, self.folder == folder else { return }
                item.saved = Self.save(result, of: item.url, as: "\(index)", in: folder)
                // The panel asks again for the item it shows.
                if let panel, panel.currentPreviewItem as? Item === item { panel.refreshCurrentPreviewItem() }
            }
        }
        fetches.append(task)
    }

    /// The page as a file the panel can show: named for what it is, a
    /// page's own links resolved from where it came from; a failure says so.
    static func save(_ result: Result<(Data, String?), Error>, of url: URL, as name: String, in folder: URL) -> URL? {
        let data: Data, ext: String
        switch result {
        case .success(let (body, mime)):
            let type = mime.flatMap { UTType(mimeType: $0) } ?? UTType(filenameExtension: url.pathExtension)
            if type?.conforms(to: .html) ?? (mime == nil) {
                ext = "html"
                data = withBase(body, url)
            } else {
                ext = type?.preferredFilenameExtension ?? "txt"
                data = body
            }
        case .failure(let error):
            ext = "html"
            let message = MarkdownRenderer.escape(error.localizedDescription)
            data = Data("""
                <!doctype html><meta charset="utf-8"><body style="font: 15px -apple-system; padding: 2em">
                <p>\(L10n.t("Couldn't load this page")): \(MarkdownRenderer.escape(url.absoluteString))</p>
                <p style="opacity: .6">\(message)</p>
                """.utf8)
        }
        let file = folder.appendingPathComponent(name).appendingPathExtension(ext)
        return (try? data.write(to: file)) == nil ? nil : file
    }

    /// A page's relative links and pictures resolve where it came from.
    private static func withBase(_ html: Data, _ url: URL) -> Data {
        let base = Data("<base href=\"\(MarkdownRenderer.escapeAttribute(url.absoluteString))\">".utf8)
        guard let head = html.range(of: Data("<head>".utf8)) ?? html.range(of: Data("<HEAD>".utf8)) else { return base + html }
        var out = html
        out.insert(contentsOf: base, at: head.upperBound)
        return out
    }
}

/// One page, fetched without cookies and stopped at `limit` bytes.
private final class PageFetch: NSObject, URLSessionDataDelegate {
    private let limit: Int
    private var body = Data()
    private var mime: String?
    private let done: (Result<(Data, String?), Error>) -> Void

    private init(limit: Int, done: @escaping (Result<(Data, String?), Error>) -> Void) {
        self.limit = limit
        self.done = done
    }

    static func start(_ url: URL, limit: Int, done: @escaping (Result<(Data, String?), Error>) -> Void) -> URLSessionTask {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = 20
        configuration.httpShouldSetCookies = false
        let fetch = PageFetch(limit: limit, done: done)
        let session = URLSession(configuration: configuration, delegate: fetch, delegateQueue: nil)
        let task = session.dataTask(with: url)
        task.resume()
        session.finishTasksAndInvalidate()
        return task
    }

    struct TooBig: LocalizedError {
        var errorDescription: String? { L10n.t("It's too big to preview.") }
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
        mime = response.mimeType
        if response.expectedContentLength > limit {
            body = Data()
            completionHandler(.cancel)
            done(.failure(TooBig()))
            return
        }
        completionHandler(.allow)
    }

    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
        body.append(data)
        if body.count > limit {
            dataTask.cancel()
            body = Data()
            done(.failure(TooBig()))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error {
            // Cancelled for being too big (said already), or the panel closed.
            if (error as? URLError)?.code == .cancelled { return }
            done(.failure(error))
        } else {
            done(.success((body, mime)))
        }
    }
}
