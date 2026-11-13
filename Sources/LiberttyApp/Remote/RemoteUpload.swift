import AppKit
import LiberttyCore

/// Files pasted or dropped on a pane whose program runs on another machine
/// (Connect to Host) go there first, through that host's liberttyd, and the
/// pane gets where they are there — as Rex and Kero do. A screenshot pasted
/// into Claude Code over ssh is then a file it can open; a path on this Mac
/// would mean nothing to it. Each paste or drop is one batch, kept a week
/// on the host (Uploads).
enum RemoteUpload {
    /// One file to send: where it is here, and its path inside the batch
    /// (its name, or a path inside a dropped folder).
    struct Item {
        let source: Source
        let relativePath: String

        enum Source {
            case file(URL)
            case data(Data)
        }
    }

    struct Failure: Error, CustomStringConvertible {
        let description: String
    }

    static let maxTotalBytes = 1 << 30
    static let maxFiles = 5000

    /// What dropping or pasting `urls` sends: each file, and each folder's
    /// files under it (links inside folders aren't followed). The paths to
    /// type are the top ones: a folder as a folder.
    static func items(for urls: [URL]) throws -> (items: [Item], top: [String]) {
        var items: [Item] = [], top: [String] = [], total = 0
        let fm = FileManager.default
        func add(_ url: URL, as relative: String) throws {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= Uploads.maxFileBytes else {
                throw Failure(description: "\(url.lastPathComponent) is over \(Uploads.maxFileBytes >> 20) MB")
            }
            total += size
            guard total <= maxTotalBytes, items.count < maxFiles else {
                throw Failure(description: "That's more than \(maxTotalBytes >> 30) GB or \(maxFiles) files")
            }
            items.append(Item(source: .file(url), relativePath: relative))
        }
        for url in urls {
            let name = url.lastPathComponent
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { continue }
            if isDir.boolValue {
                guard let walker = fm.enumerator(at: url, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey],
                                                 options: []) else { continue }
                for case let file as URL in walker {
                    let values = try? file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey])
                    guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }
                    let inside = file.standardizedFileURL.path.dropFirst(url.standardizedFileURL.path.count)
                    try add(file, as: name + "/" + inside.drop { $0 == "/" })
                }
            } else {
                try add(url, as: name)
            }
            top.append(name)
        }
        return (items, top)
    }

    /// A name for one paste or drop.
    static func newBatch() -> String {
        let stamp = DateFormatter()
        stamp.locale = Locale(identifier: "en_US_POSIX")
        stamp.dateFormat = "yyyyMMdd-HHmmss"
        return stamp.string(from: Date()) + "-" + String(UUID().uuidString.prefix(8)).lowercased()
    }

    /// Sends `items` to the liberttyd at `address` (off the main thread) and
    /// returns where each of `top` is there, or why not. `.unsupported`: an
    /// older liberttyd, which takes no uploads.
    enum Outcome {
        case sent([String])
        case unsupported
        case failed(String)
    }

    static func send(_ items: [Item], top: [String], batch: String, to address: DaemonAddress) -> Outcome {
        var batchRoot: String?
        for item in items {
            let bytes: Data
            switch item.source {
            case .data(let data): bytes = data
            case .file(let url):
                guard let data = try? Data(contentsOf: url, options: .alwaysMapped) else {
                    return .failed("Couldn't read \(url.lastPathComponent)")
                }
                bytes = data
            }
            let payload = bytes.withUnsafeBytes { Connection.headed(["batch": batch, "path": item.relativePath], body: $0) }
            // A big file over a slow link takes a while: a minute per 50 MB or so, at least two.
            let timeout = max(120, Double(bytes.count) / 1_000_000)
            switch DaemonClient.request(.upload, payload: payload, needing: "upload", timeout: timeout, address: address) {
            case .unsupported: return .unsupported
            case .unanswered: return .failed("The host didn't answer")
            case .answered(let frame):
                guard frame.json["ok"] as? Bool == true, let path = frame.json["path"] as? String else {
                    return .failed(frame.json["error"] as? String ?? "The host refused \(item.relativePath)")
                }
                // The batch's folder there: the path less what's inside it.
                if batchRoot == nil, path.hasSuffix("/" + item.relativePath) {
                    batchRoot = String(path.dropLast(item.relativePath.count + 1))
                }
            }
        }
        guard let root = batchRoot else { return .sent([]) }
        return .sent(top.map { root + "/" + $0 })
    }
}

extension TerminalView {
    /// Files or a pasted image for a pane on another machine: sent there,
    /// then their paths there typed (one quoted word each, and a space).
    /// While they go, the pane says so; if the host's liberttyd is too old
    /// to take them, what this Mac's paths would be is typed instead, as
    /// before, for files (an image has none worth typing).
    func uploadAndType(urls: [URL] = [], image png: Data? = nil) {
        upload(urls: urls, image: png) { [weak self] outcome in
            guard let self else { return }
            switch outcome {
            case .sent(let paths):
                guard !paths.isEmpty else { return }
                self.sendInput(paths.map(ShellQuote.quote).joined(separator: " ") + " ")
            case .unsupported:
                if !urls.isEmpty {
                    self.sendInput(urls.map { ShellQuote.quote($0.path) }.joined(separator: " ") + " ")
                } else {
                    self.uploadFailed(L10n.t("The host's liberttyd is older and takes no files. Connect to it again to update it."))
                }
            case .failed(let why):
                self.uploadFailed(why)
            }
        }
    }

    /// Files or an image sent to this pane's host, and the outcome told on
    /// the main thread (the composer puts the paths in its text instead of
    /// typing them). While they go, the pane says so.
    func upload(urls: [URL], image png: Data?, then done: @escaping (RemoteUpload.Outcome) -> Void) {
        guard let host = session.host else { return done(.failed("This pane isn't on another machine")) }
        let batch = RemoteUpload.newBatch()
        let items: [RemoteUpload.Item], top: [String]
        if let png {
            let name = "paste-\(batch.prefix(15)).png"
            items = [RemoteUpload.Item(source: .data(png), relativePath: name)]
            top = [name]
        } else {
            do {
                (items, top) = try RemoteUpload.items(for: urls)
            } catch {
                return done(.failed("\(error)"))
            }
        }
        guard !items.isEmpty else { return done(.sent([])) }
        let address = host.address
        uploadsUnderWay += 1
        showUploadTag(L10n.t("Uploading to %@…").replacingOccurrences(of: "%@", with: host.destination))
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            let outcome = RemoteUpload.send(items, top: top, batch: batch, to: address)
            DispatchQueue.main.async {
                guard let self else { return }
                self.uploadsUnderWay -= 1
                if self.uploadsUnderWay == 0 { self.showUploadTag(nil) }
                done(outcome)
            }
        }
    }

    /// A paste on a host's pane: files copied in Finder, or an image alone,
    /// go there (text pastes as it is). Whether it was one of those.
    func pasteRemotely(_ pasteboard: NSPasteboard) -> Bool {
        if let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL],
           !urls.isEmpty {
            uploadAndType(urls: urls)
            return true
        }
        if let text = pasteboard.string(forType: .string), !text.isEmpty { return false }
        guard let png = PasteContent.pngData(pasteboard) else { return false }
        uploadAndType(image: png)
        return true
    }

    private func uploadFailed(_ why: String) {
        guard let window else { return }
        let alert = NSAlert()
        alert.messageText = L10n.t("Couldn't send that to the host")
        alert.informativeText = why
        alert.beginSheetModal(for: window)
    }

    private static var uploadTagKey: UInt8 = 0
    private static var uploadCountKey: UInt8 = 0

    /// Pastes and drops on their way to the host: the tag stays till the last is there.
    private var uploadsUnderWay: Int {
        get { objc_getAssociatedObject(self, &Self.uploadCountKey) as? Int ?? 0 }
        set { objc_setAssociatedObject(self, &Self.uploadCountKey, newValue, .OBJC_ASSOCIATION_RETAIN) }
    }

    /// The tag at the pane's bottom right while files go (nil: gone).
    private func showUploadTag(_ text: String?) {
        var tag = objc_getAssociatedObject(self, &Self.uploadTagKey) as? NSTextField
        guard let text else {
            tag?.removeFromSuperview()
            objc_setAssociatedObject(self, &Self.uploadTagKey, nil, .OBJC_ASSOCIATION_RETAIN)
            return
        }
        if tag == nil {
            let label = NSTextField(labelWithString: "")
            label.font = .systemFont(ofSize: 11, weight: .medium)
            label.textColor = .secondaryLabelColor
            label.wantsLayer = true
            label.drawsBackground = true
            label.layer?.cornerRadius = 5
            effectiveAppearance.performAsCurrentDrawingAppearance {
                label.backgroundColor = NSColor.windowBackgroundColor.withAlphaComponent(0.92)
            }
            addSubview(label)
            label.layer?.zPosition = 2
            objc_setAssociatedObject(self, &Self.uploadTagKey, label, .OBJC_ASSOCIATION_RETAIN)
            tag = label
        }
        guard let tag else { return }
        tag.stringValue = " " + text + " "
        tag.setAccessibleLabel(text)
        let size = tag.fittingSize
        let width = min(size.width, max(0, bounds.width - 12))
        tag.frame = NSRect(x: bounds.width - width - 18, y: 6, width: width, height: size.height)
        tag.autoresizingMask = [.minXMargin, .maxYMargin]
        AccessibilityNews.announce(text, from: tag)
    }

    /// What the upload tag says (the UI probe): nil when there's none.
    var uploadTagShown: String? { (objc_getAssociatedObject(self, &Self.uploadTagKey) as? NSTextField)?.stringValue }
}
