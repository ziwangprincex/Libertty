import AppKit
import CryptoKit

/// A block that edits one file (a drawing, a board, a notebook): it reads
/// the file, writes it back only over what it read (a change made elsewhere
/// is never overwritten unseen), and tells the page when the file changes
/// under it. Its unsaved changes count as the editor's do: ⌘S and closing
/// ask the page to write. The address names the file:
/// `libertty-block://canvas?file=/path/to/drawing.excalidraw`.
class FileBlock: BlockService {
    class var symbol: String { "doc" }
    /// Shows the file and never writes it (the profile viewer).
    class var readOnly: Bool { false }
    /// Bigger than this isn't read: the page holds the whole file.
    static let sizeLimit = 64_000_000
    weak var host: BlockHost?
    let file: URL

    /// The file's bytes as last read or written here (nil: it wasn't there).
    private var known: SHA256.Digest?
    /// The file began with UTF-8's byte-order mark (kept when it's saved).
    private var hasBOM = false
    private let lock = NSLock()
    private var watcher: DispatchSourceFileSystemObject?
    private var retry: DispatchWorkItem?
    private var closed = false
    private(set) var hasUnsavedChanges = false

    /// Saving (⌘S, a closing window): a numbered round the page answers
    /// (`saveDone` with its id); waiters who come while one runs get the
    /// next round, if there are still changes by then.
    private var saveRound = 0
    private var saving = false
    private var roundWaiters: [(Bool) -> Void] = []
    private var nextWaiters: [(Bool) -> Void] = []

    required init?(url: URL) {
        guard let path = Blocks.parameter("file", of: url), path.hasPrefix("/") else { return nil }
        file = URL(fileURLWithPath: path).standardizedFileURL
        DispatchQueue.main.async { [weak self] in self?.watch() }
    }

    var title: String { file.lastPathComponent }

    func handle(_ method: String, _ params: [String: Any], reply: @escaping (Result<Any, BlockError>) -> Void) {
        if Self.readOnly, ["write", "dirty", "saveDone", "export", "openText"].contains(method) {
            return reply(.failure(BlockError("\(file.lastPathComponent) is shown read-only")))
        }
        switch method {
        case "read": blockWork(reply) { try self.read() }
        case "write":
            // `base`: the file's digest as the page read it — what it writes over.
            // `force`: over a change made elsewhere, when the page was told and chose this.
            guard let text = params["text"] as? String else { return reply(.failure(BlockError("nothing to write"))) }
            let force = params["force"] as? Bool ?? false
            let base = params["base"] as? String
            // The file's UTF-8 mark goes back with it (Windows' editors write one).
            blockWork(reply) {
                self.lock.lock(); let mark = self.hasBOM; self.lock.unlock()
                return try self.write((mark ? Data([0xEF, 0xBB, 0xBF]) : Data()) + Data(text.utf8), base: base, force: force)
            }
        case "dirty":
            let on = params["dirty"] as? Bool ?? false
            DispatchQueue.main.async { self.setUnsaved(on) }
            reply(.success(true))
        case "saveDone":
            let ok = params["ok"] as? Bool ?? false, id = params["id"] as? Int ?? -1
            DispatchQueue.main.async { self.finishSave(ok, round: id) }
            reply(.success(true))
        case "reveal":
            DispatchQueue.main.async { NSWorkspace.shared.activateFileViewerSelecting([self.file]) }
            reply(.success(true))
        case "openText":
            // The file itself, in the editor (a board's Markdown).
            DispatchQueue.main.async { self.host?.editFile(self.file) }
            reply(.success(true))
        case "export":
            guard let format = params["format"] as? String, ["png", "svg"].contains(format),
                  let base64 = params["data"] as? String, let data = Data(base64Encoded: base64) else {
                return reply(.failure(BlockError("nothing to export")))
            }
            DispatchQueue.main.async { self.export(data, as: format, reply: reply) }
        default:
            handleMore(method, params, reply: reply)
        }
    }

    /// A kind's own calls.
    func handleMore(_ method: String, _ params: [String: Any], reply: @escaping (Result<Any, BlockError>) -> Void) {
        reply(.failure(BlockError("unknown call \(method)")))
    }

    // MARK: The file

    /// The digest of bytes, as 64 hex characters (the page hands it back to write).
    static func hex(_ digest: SHA256.Digest) -> String { digest.map { String(format: "%02x", $0) }.joined() }

    private func read() throws -> [String: Any] {
        let fm = FileManager.default
        var data: Data?
        if fm.fileExists(atPath: file.path) {
            let size = (try? fm.attributesOfItem(atPath: file.path)[.size] as? Int) ?? 0
            guard size <= Self.sizeLimit else {
                throw BlockError("\(file.lastPathComponent) is \(size / 1_000_000) MB: too big to open here (the limit is \(Self.sizeLimit / 1_000_000) MB).")
            }
            data = try Data(contentsOf: file)
        }
        lock.lock()
        let digest = data.map { SHA256.hash(data: $0) }
        known = digest
        lock.unlock()
        var text = ""
        if data == nil { lock.lock(); hasBOM = false; lock.unlock() }  // a new file: none
        if let data {
            let mark = data.starts(with: [0xEF, 0xBB, 0xBF])
            guard let decoded = String(data: mark ? data.dropFirst(3) : data[...], encoding: .utf8) else {
                throw BlockError("\(file.lastPathComponent) isn't UTF-8 text")
            }
            lock.lock(); hasBOM = mark; lock.unlock()
            text = decoded
        }
        // Written in place when its folder won't take a replacement: the file's own permission decides.
        let target = file.resolvingSymlinksInPath()
        let folder = target.deletingLastPathComponent().path
        let writable = !Self.readOnly && (data == nil ? !fm.fileExists(atPath: folder) || fm.isWritableFile(atPath: folder) : fm.isWritableFile(atPath: target.path))
        return ["text": text, "name": file.lastPathComponent, "path": file.path, "writable": writable,
                "base": digest.map(Self.hex) as Any? ?? ""]
    }

    /// `data` over the file, if the file is still what this block last saw
    /// (`force`: whatever it is now). The answer says which: `conflict` when
    /// it changed elsewhere and nothing was written. Through a replacement
    /// file (a crash mid-write leaves the old one whole), at a symbolic
    /// link's target, keeping permissions; in place when the file has other
    /// hard links or its folder can't take a replacement.
    private func write(_ data: Data, base: String?, force: Bool) throws -> [String: Any] {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        let target = file.resolvingSymlinksInPath()
        let current = (try? Data(contentsOf: target)).map { SHA256.hash(data: $0) }
        // What the page read, not what was read after it (a reread that the
        // page never took in mustn't let the next save pass for clean).
        // An empty base: the page read no file (a new board, a new drawing).
        let expected = base.map { $0.isEmpty ? nil : $0 } ?? known.map(Self.hex)
        guard force || current.map(Self.hex) == expected else { return ["written": false, "conflict": true] }
        let attributes = try? fm.attributesOfItem(atPath: target.path)
        let links = (attributes?[.referenceCount] as? NSNumber)?.intValue ?? 1
        let folder = target.deletingLastPathComponent()
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        let previous = known
        // Set first: the watcher may hear the replacement before this returns.
        let written = SHA256.hash(data: data)
        known = written
        do {
            if attributes != nil, links > 1 || !fm.isWritableFile(atPath: folder.path) {
                let handle = try FileHandle(forWritingTo: target)
                defer { try? handle.close() }
                try handle.truncate(atOffset: 0)
                try handle.write(contentsOf: data)
                try handle.synchronize()
            } else {
                try data.write(to: target, options: .atomic)
                if let permissions = attributes?[.posixPermissions] {
                    try? fm.setAttributes([.posixPermissions: permissions], ofItemAtPath: target.path)
                }
            }
        } catch {
            known = previous
            throw BlockError("Couldn't save \(file.lastPathComponent): \(error.localizedDescription)")
        }
        // The page's base from now on: what it wrote.
        return ["written": true, "base": Self.hex(written)]
    }

    /// Hear the file change (or be replaced, as editors and our own writes do).
    private func watch() {
        retry?.cancel()
        retry = nil
        watcher?.cancel()
        watcher = nil
        guard !closed else { return }
        let fd = open(file.path, O_EVTONLY)
        guard fd >= 0 else {
            // Not there (mid-replace, or moved away): look again soon.
            let again = DispatchWorkItem { [weak self] in self?.watch() }
            retry = again
            DispatchQueue.main.asyncAfter(deadline: .now() + 1, execute: again)
            return
        }
        let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .rename, .delete, .extend], queue: .main)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let replaced = source.data.contains(.rename) || source.data.contains(.delete)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if replaced { self.watch() } else { self.checkDisk() }
            }
        }
        source.setCancelHandler { Darwin.close(fd) }
        source.resume()
        watcher = source
        // Whatever happened while nothing watched (a replacement, a file come back).
        checkDisk()
    }

    private func checkDisk() {
        DispatchQueue.global(qos: .utility).async { [weak self] in
            guard let self else { return }
            // Under the lock: a write of ours mid-way isn't someone else's change.
            self.lock.lock()
            let current = (try? Data(contentsOf: self.file)).map { SHA256.hash(data: $0) }
            let news = current != nil && current != self.known
            self.lock.unlock()
            if news { DispatchQueue.main.async { self.host?.send("fileChanged", [:]) } }
        }
    }

    // MARK: Unsaved changes

    private func setUnsaved(_ on: Bool) {
        guard hasUnsavedChanges != on else { return }
        hasUnsavedChanges = on
        host?.unsavedChanged(on)
    }

    func save(completion: @escaping (Bool) -> Void) {
        if saving { return nextWaiters.append(completion) }
        guard hasUnsavedChanges else { return completion(true) }
        startRound([completion])
    }

    private func startRound(_ waiters: [(Bool) -> Void]) {
        saveRound += 1
        let round = saveRound
        saving = true
        roundWaiters = waiters
        host?.send("save", ["id": round])
        // A page that never answers (its process died) doesn't hold a quit forever.
        DispatchQueue.main.asyncAfter(deadline: .now() + 10) { [weak self] in self?.finishSave(false, round: round) }
    }

    private func finishSave(_ ok: Bool, round: Int) {
        guard saving, round == saveRound else { return }
        saving = false
        let done = roundWaiters
        roundWaiters = []
        done.forEach { $0(ok) }
        let next = nextWaiters
        nextWaiters = []
        if next.isEmpty { return }
        if hasUnsavedChanges { startRound(next) } else { next.forEach { $0(ok) } }
    }

    /// The page started (again: a reload, a crash): it has nothing unsaved,
    /// and a save it was asked for won't come.
    func pageStarted() {
        if saving { finishSave(false, round: saveRound) }
        setUnsaved(false)
    }

    private func export(_ data: Data, as format: String, reply: @escaping (Result<Any, BlockError>) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = file.deletingPathExtension().lastPathComponent + "." + format
        panel.allowedContentTypes = [format == "png" ? .png : .svg]
        panel.directoryURL = file.deletingLastPathComponent()
        let done: (NSApplication.ModalResponse) -> Void = { response in
            guard response == .OK, let url = panel.url else { return reply(.success(false)) }
            do { try data.write(to: url, options: .atomic); reply(.success(true)) } catch {
                reply(.failure(BlockError("Couldn't export: \(error.localizedDescription)")))
            }
        }
        if let window = host?.blockWindow { panel.beginSheetModal(for: window, completionHandler: done) } else { done(panel.runModal()) }
    }

    /// (Declared here so a kind can override it: the protocol's default
    /// would otherwise be what a FileBlock's conformance calls.)
    func suspend() {}

    func close() {
        closed = true
        retry?.cancel()
        watcher?.cancel()
        watcher = nil
    }
}

/// The canvas block (Tern's canvas): an Excalidraw drawing, kept in an
/// `.excalidraw` file, written back as it's drawn.
final class CanvasBlock: FileBlock {
    override class var symbol: String { "scribble.variable" }

    static var folder: URL { Blocks.dataDirectory.appendingPathComponent("Canvases", isDirectory: true) }
    /// What a new drawing's file holds until something is drawn.
    private static let empty = Data(#"{"type":"excalidraw","version":2,"source":"libertty","elements":[],"appState":{},"files":{}}"#.utf8)

    /// A new drawing's file, among Libertty's own (until it's moved): made
    /// now, exclusively, so two new canvases never share one.
    static func newFile() -> URL {
        let dir = folder
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        for n in 1...999 {
            let url = dir.appendingPathComponent("Canvas \(stamp.string(from: Date()))\(n == 1 ? "" : " \(n)").excalidraw")
            let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL, 0o644)
            guard fd >= 0 else { continue }
            _ = empty.withUnsafeBytes { Darwin.write(fd, $0.baseAddress, $0.count) }
            Darwin.close(fd)
            return url
        }
        return dir.appendingPathComponent("Canvas \(UUID().uuidString).excalidraw")
    }

    /// A new drawing nothing was drawn in leaves no file behind.
    override func close() {
        super.close()
        let url = file
        guard url.deletingLastPathComponent().standardizedFileURL.path == Self.folder.standardizedFileURL.path,
              (try? Data(contentsOf: url)) == Self.empty else { return }
        try? FileManager.default.removeItem(at: url)
    }
}

/// The profile block: a profile file shown in speedscope (MIT) — a `sample`
/// report (the profiler's), Chrome's .cpuprofile, folded stacks or
/// speedscope's own JSON. It only reads.
final class ProfileBlock: FileBlock {
    override class var symbol: String { "flame" }
    override class var readOnly: Bool { true }

    /// The files it shows, by name.
    static func shows(_ url: URL) -> Bool {
        let name = url.lastPathComponent.lowercased()
        return name.hasSuffix(".sample.txt") || name.hasSuffix(".speedscope.json") || name.hasSuffix(".cpuprofile")
            || name.hasSuffix(".folded")
    }
}

/// The board block (Tern's board): a kanban kept as Markdown, `## Column`
/// headings and `- [ ] card` items, readable and editable as text anywhere.
final class BoardBlock: FileBlock {
    override class var symbol: String { "rectangle.split.3x1" }

    /// A folder's BOARD.md is that folder's board.
    override var title: String {
        file.lastPathComponent == "BOARD.md" ? "Board — " + file.deletingLastPathComponent().lastPathComponent : file.lastPathComponent
    }

    /// The board for a folder: its repository's (or the folder's) BOARD.md.
    static func file(for directory: String) -> URL {
        URL(fileURLWithPath: GitCLI.root(of: directory) ?? directory).appendingPathComponent("BOARD.md")
    }
}
