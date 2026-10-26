import AppKit
import WebKit

/// A block (Tern's workspace blocks): a tool that lives in a tab or beside a
/// terminal like a document — a Git client, a task manager, a board — drawn
/// by a page of Libertty's own (blocks/NAME) that asks this side for what it
/// shows. Its address says which tool and on what:
/// `libertty-block://git?root=/path/to/repo`.
///
/// The page runs our script only (its CSP), and shows what it's given as
/// text, never as markup: file names, commit messages and process names are
/// someone else's words.
protocol BlockService: AnyObject {
    /// The tab's name ("Git — libertty").
    var title: String { get }
    /// SF Symbol for its tab and the palette.
    static var symbol: String { get }
    /// The title changed, or the page should hear something (`send`).
    var host: BlockHost? { get set }
    /// Answer the page's call `method` (`block.call(method, params)` there).
    func handle(_ method: String, _ params: [String: Any], reply: @escaping (Result<Any, BlockError>) -> Void)
    /// A command finished in some terminal: what it ran may have changed what this shows.
    func promptArrived()
    /// The block is going away.
    func close()
    /// Its tab or pane closed (it may come back with Undo): let go of what
    /// costs (a kernel, a server) until it's used again.
    func suspend()
    /// Changes the page hasn't written yet (a file block's).
    var hasUnsavedChanges: Bool { get }
    /// Write them (⌘S, or closing): `completion` says whether they're on disk.
    func save(completion: @escaping (Bool) -> Void)
}

extension BlockService {
    func promptArrived() {}
    func close() {}
    func suspend() {}
    var hasUnsavedChanges: Bool { false }
    func save(completion: @escaping (Bool) -> Void) { completion(true) }
}

/// What a service can do to the page and the window holding it.
protocol BlockHost: AnyObject {
    /// Tell the page `event` (it hears it with `block.on(event, …)`).
    func send(_ event: String, _ payload: Any)
    /// Its title changed.
    func titleChanged()
    /// Show a file in Libertty (the editor, for text).
    func openFile(_ url: URL, line: Int?)
    /// The terminals of every window: their shells' pids, what each is called, and its pane.
    func terminals() -> [BlockTerminal]
    /// Bring a pane forward.
    func reveal(paneID: String)
    /// Open an address in a browser block.
    func openBrowser(_ url: URL)
    /// Open a file in the editor, as text (not in the block that edits its kind).
    func editFile(_ url: URL)
    /// Unsaved changes came or went.
    func unsavedChanged(_ unsaved: Bool)
    /// The window it's in (for a save panel).
    var blockWindow: NSWindow? { get }
}

struct BlockTerminal {
    var shell: Int32
    var name: String
    var paneID: String
}

struct BlockError: Error {
    var message: String
    init(_ message: String) { self.message = message }
}

enum Blocks {
    static let scheme = "libertty-block"

    /// A command finished in some terminal (posted by its window, heard by every block).
    static let commandFinished = Notification.Name("LiberttyBlocksCommandFinished")

    /// The tools there are, by the name in their address.
    static let kinds: [String: (URL) -> BlockService?] = [
        "git": { GitBlock(url: $0) },
        "tasks": { _ in TasksBlock() },
        "canvas": { CanvasBlock(url: $0) },
        "profiler": { ProfilerBlock(url: $0) },
        "profile": { ProfileBlock(url: $0) },
        "board": { BoardBlock(url: $0) },
        "sqlite": { SQLiteBlock(url: $0) },
        "plugins": { _ in PluginsBlock() },
        "notebook": { NotebookBlock(url: $0) },
        "screen": { ScreenShareBlock(url: $0) },
    ]

    /// The block that edits a file of this kind (a drawing), if one does.
    static func address(forFile url: URL) -> URL? {
        guard url.isFileURL else { return nil }
        if ProfileBlock.shows(url) { return Blocks.url("profile", ["file": url.standardizedFileURL.path]) }
        if url.lastPathComponent.lowercased().hasSuffix(".board.md") { return Blocks.url("board", ["file": url.standardizedFileURL.path]) }
        if SQLiteBlock.isDatabase(url) { return Blocks.url("sqlite", ["file": url.standardizedFileURL.path]) }
        switch url.pathExtension.lowercased() {
        case "excalidraw": return Blocks.url("canvas", ["file": url.standardizedFileURL.path])
        case "ipynb": return Blocks.url("notebook", ["file": url.standardizedFileURL.path])
        default: return nil
        }
    }

    /// Where blocks keep what they make (drawings, profiles, plugins'
    /// storage): Application Support, or `LIBERTTY_DATA_DIR` (a test run's
    /// own folder; every probe run gets one).
    static var dataDirectory: URL {
        if let dir = ProcessInfo.processInfo.environment["LIBERTTY_DATA_DIR"], !dir.isEmpty {
            return URL(fileURLWithPath: dir, isDirectory: true)
        }
        return FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Libertty", isDirectory: true)
    }

    static func isBlock(_ url: URL) -> Bool { url.scheme == scheme }

    static func name(of url: URL) -> String? { isBlock(url) ? url.host : nil }

    /// The address of tool `name` with these parameters.
    static func url(_ name: String, _ query: [String: String] = [:]) -> URL {
        var parts = URLComponents()
        parts.scheme = scheme
        parts.host = name
        parts.path = "/"
        if !query.isEmpty { parts.queryItems = query.sorted { $0.key < $1.key }.map { URLQueryItem(name: $0.key, value: $0.value) } }
        return parts.url!
    }

    static func parameter(_ name: String, of url: URL) -> String? {
        URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems?.first { $0.name == name }?.value
    }

    static func make(_ url: URL) -> BlockService? {
        guard let name = name(of: url), let make = kinds[name] else { return nil }
        return make(url)
    }

    static func symbol(of url: URL) -> String {
        switch name(of: url) {
        case "git": GitBlock.symbol
        case "tasks": TasksBlock.symbol
        case "canvas": CanvasBlock.symbol
        case "profiler", "profile": ProfilerBlock.symbol
        case "board": BoardBlock.symbol
        case "sqlite": SQLiteBlock.symbol
        case "plugins": PluginsBlock.symbol
        case "notebook": NotebookBlock.symbol
        case "screen": ScreenShareBlock.symbol
        default: "square.grid.2x2"
        }
    }

    /// The pages' folder: the app's Resources/blocks, or the repository's when
    /// running from `swift build`.
    static var root: URL? {
        var dirs: [URL] = []
        if let resources = Bundle.main.resourceURL { dirs.append(resources.appendingPathComponent("blocks")) }
        dirs.append(URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent().appendingPathComponent("blocks"))
        return dirs.first { FileManager.default.fileExists(atPath: $0.appendingPathComponent("common/block.js").path) }
    }

    static func page(for url: URL) -> URL? {
        guard let name = name(of: url), let root else { return nil }
        let page = root.appendingPathComponent(name).appendingPathComponent("index.html")
        return FileManager.default.fileExists(atPath: page.path) ? page : nil
    }

    /// The theme as the pages' CSS variables (the same tokens as documents).
    static func theme(_ t: Theme) -> [String: Any] {
        func mix(_ a: RGB, _ b: RGB, _ f: Double) -> String {
            func c(_ x: UInt8, _ y: UInt8) -> Int { Int((Double(x) * (1 - f) + Double(y) * f).rounded()) }
            return String(format: "#%02x%02x%02x", c(a.r, b.r), c(a.g, b.g), c(a.b, b.b))
        }
        let dark = t.isDark
        return [
            "dark": dark,
            "bg": t.background.hexString, "t1": t.foreground.hexString,
            "t2": mix(t.foreground, t.background, 0.28), "t3": mix(t.foreground, t.background, 0.45),
            "t4": mix(t.foreground, t.background, 0.65),
            "l1": dark ? "rgba(255,255,255,0.06)" : "rgba(24,26,44,0.05)",
            "l2": dark ? "rgba(255,255,255,0.10)" : "rgba(24,26,44,0.09)",
            "l3": dark ? "rgba(255,255,255,0.16)" : "rgba(24,26,44,0.16)",
            "panel": mix(t.background, dark ? RGB(255, 255, 255) : RGB(0, 0, 0), dark ? 0.04 : 0.025),
            "selection": t.selection.hexString,
            "add": t.ansi[2].hexString, "del": t.ansi[1].hexString, "warn": t.ansi[3].hexString,
            "fontURL": EditorAssets.fontURL?.absoluteString ?? "",
            // The bundled fonts' folder (Geist for text), without its trailing slash.
            "fontDir": EditorAssets.fontURL.map { String($0.deletingLastPathComponent().absoluteString.dropLast()) } ?? "",
            "accent": (Accent.color.usingColorSpace(.sRGB)).map {
                String(format: "#%02x%02x%02x", Int($0.redComponent * 255), Int($0.greenComponent * 255), Int($0.blueComponent * 255))
            } ?? "#3d82f6",
        ]
    }
}

/// The page's calls, answered by its service (a reply per call: the page
/// awaits it as a promise). Weak both ways: the page's controller retains
/// its handlers, and must not keep the block alive.
final class BlockBridge: NSObject, WKScriptMessageHandlerWithReply {
    weak var service: BlockService?
    init(_ service: BlockService) { self.service = service }

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage,
                               replyHandler: @escaping @MainActor @Sendable (Any?, String?) -> Void) {
        guard let body = message.body as? [String: Any], let method = body["method"] as? String else {
            return replyHandler(nil, "a call needs a method")
        }
        guard let service else { return replyHandler(nil, "the block has closed") }
        let params = body["params"] as? [String: Any] ?? [:]
        service.handle(method, params) { result in
            // Replies come back on the main thread, whatever thread did the work.
            let send = {
                switch result {
                case .success(let value): replyHandler(Self.plain(value), nil)
                case .failure(let error): replyHandler(nil, error.message)
                }
            }
            if Thread.isMainThread { MainActor.assumeIsolated { send() } } else { DispatchQueue.main.async { send() } }
        }
    }

    /// What a reply may carry: JSON-like values (WebKit refuses anything else).
    private static func plain(_ value: Any) -> Any {
        switch value {
        case let d as [String: Any]: return d.mapValues(plain)
        case let a as [Any]: return a.map(plain)
        case is String, is Bool, is Int, is Double, is NSNumber, is NSNull: return value
        case let i as Int64: return NSNumber(value: i)
        case let i as Int32: return NSNumber(value: i)
        case let u as UInt64: return NSNumber(value: u)
        case let f as Float: return Double(f)
        case let c as CGFloat: return Double(c)
        case is Void: return NSNull()
        default: return String(describing: value)
        }
    }
}

/// Run `work` off the main thread and reply with what it returns.
func blockWork(_ reply: @escaping (Result<Any, BlockError>) -> Void, _ work: @escaping () throws -> Any) {
    DispatchQueue.global(qos: .userInitiated).async {
        do { reply(.success(try work())) } catch let error as BlockError { reply(.failure(error)) } catch {
            reply(.failure(BlockError(error.localizedDescription)))
        }
    }
}
