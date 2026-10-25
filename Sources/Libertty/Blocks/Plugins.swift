import AppKit
import JavaScriptCore

/// Plugins (Tern's plugins): JavaScript in the config folder's `plugins/`,
/// each a folder with `plugin.json` and its `main.js` (or one `NAME.js`).
/// Each runs in a JavaScriptCore context of its own, on a queue of its own
/// (a plugin stuck in a loop stops only itself), with a small API:
///
///     libertty.command("Title", fn)     a command in the palette
///     libertty.on("commandFinished", fn) {command, exitCode, duration, cwd}
///     libertty.notify(title, body)       a notification
///     libertty.send(text)                typed into the focused terminal
///     libertty.open(pathOrURL)           a file or page in Libertty
///     libertty.cwd(), libertty.screen(n) the focused terminal's folder, its last n lines
///     libertty.storage.get/set(key, v)   the plugin's own JSON storage
///     console.log, setTimeout, setInterval
///
/// No files, no network, no processes: only that. A plugin is off until
/// it's turned on in the Plugins block (what's in the folder may not be
/// yours); saving its file reloads it.
final class PluginHost {
    static let shared = PluginHost()
    static let changed = Notification.Name("LiberttyPluginsChanged")

    static var folder: URL { ConfigStore.directory.appendingPathComponent("plugins", isDirectory: true) }
    private static var stateFile: URL { Blocks.dataDirectory.appendingPathComponent("plugins.json") }
    static var storageFolder: URL { Blocks.dataDirectory.appendingPathComponent("plugin-storage", isDirectory: true) }

    /// Every plugin found, by name (main thread).
    private(set) var plugins: [Plugin] = []
    private var enabled: Set<String> = []
    private var started = false
    private var watchers: [DispatchSourceFileSystemObject] = []
    private var rescanSoon: DispatchWorkItem?
    /// The window plugins act in: the front one (the probe sets its own).
    var frontController: () -> TerminalWindowController? = { (NSApp.delegate as? AppDelegate)?.frontController }

    func start() {
        guard !started else { return }
        started = true
        if let data = try? Data(contentsOf: Self.stateFile),
           let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            enabled = Set(state["enabled"] as? [String] ?? [])
        }
        rescan()
    }

    /// Look at the folder again: new plugins appear (off), gone ones stop,
    /// changed ones reload.
    func rescan() {
        let found = Self.discover()
        for old in plugins where !found.contains(where: { $0.name == old.name }) { old.stop() }
        var next: [Plugin] = []
        for f in found {
            if let existing = plugins.first(where: { $0.name == f.name }) {
                existing.refresh(from: f)
                next.append(existing)
            } else {
                next.append(f)
            }
        }
        plugins = next
        for p in plugins {
            let on = enabled.contains(p.name)
            if on, !p.isRunning || p.sourceChanged { p.startRunning() } else if !on, p.isRunning { p.stop() }
        }
        watch()
        changedNow()
    }

    func setEnabled(_ name: String, _ on: Bool) {
        if on { enabled.insert(name) } else { enabled.remove(name) }
        let state: [String: Any] = ["enabled": enabled.sorted()]
        try? FileManager.default.createDirectory(at: Self.stateFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? JSONSerialization.data(withJSONObject: state).write(to: Self.stateFile, options: .atomic)
        rescan()
    }

    func isEnabled(_ name: String) -> Bool { enabled.contains(name) }

    func reload(_ name: String) {
        guard let p = plugins.first(where: { $0.name == name }), enabled.contains(name) else { return }
        p.stop()
        p.startRunning()
        changedNow()
    }

    /// The palette's plugin commands.
    var commands: [(plugin: Plugin, title: String)] {
        plugins.filter(\.isRunning).flatMap { p in p.commandTitles.map { (p, $0) } }
    }

    func emit(_ event: String, _ payload: [String: Any]) {
        for p in plugins where p.isRunning { p.emit(event, payload) }
    }

    func changedNow() { NotificationCenter.default.post(name: Self.changed, object: nil) }

    /// A new plugin from the template, and its file.
    func create(_ name: String) throws -> URL {
        let id = name.lowercased().replacingOccurrences(of: #"[^a-z0-9]+"#, with: "-", options: .regularExpression)
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        guard !id.isEmpty else { throw BlockError("A plugin needs a name.") }
        let dir = Self.folder.appendingPathComponent(id, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: dir.path) else { throw BlockError("There's a plugin called \(id) already.") }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let manifest: [String: Any] = ["name": name, "description": "", "version": "0.1.0", "main": "main.js"]
        try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys]).write(to: dir.appendingPathComponent("plugin.json"))
        let main = """
            // \(name): a Libertty plugin. Saving this file reloads it.
            // The API: libertty.command, .on, .notify, .send, .open, .cwd, .screen, .storage;
            // console.log shows in the Plugins block.

            libertty.command("\(name.replacingOccurrences(of: "\"", with: ""))", () => {
              libertty.notify("\(name.replacingOccurrences(of: "\"", with: ""))", "in " + libertty.cwd());
            });

            libertty.on("commandFinished", (e) => {
              if (e.exitCode) console.log(`${e.command} failed (${e.exitCode}) after ${e.duration.toFixed(1)} s`);
            });

            """
        try main.write(to: dir.appendingPathComponent("main.js"), atomically: true, encoding: .utf8)
        rescan()
        return dir.appendingPathComponent("main.js")
    }

    private static func discover() -> [Plugin] {
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: folder.path) else { return [] }
        return names.sorted().compactMap { entry -> Plugin? in
            guard !entry.hasPrefix(".") else { return nil }
            let url = folder.appendingPathComponent(entry)
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir) else { return nil }
            if isDir.boolValue {
                let manifest = (try? Data(contentsOf: url.appendingPathComponent("plugin.json")))
                    .flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: Any] } ?? [:]
                let main = (manifest["main"] as? String).flatMap { $0.isEmpty || $0.contains("..") ? nil : $0 } ?? "main.js"
                return Plugin(name: entry, main: url.appendingPathComponent(main), manifest: manifest, folder: url)
            }
            guard url.pathExtension == "js" else { return nil }
            return Plugin(name: url.deletingPathExtension().lastPathComponent, main: url, manifest: [:], folder: nil)
        }
    }

    /// The folder and each plugin's folder: a save there rescans (shortly).
    private func watch() {
        watchers.forEach { $0.cancel() }
        watchers = []
        try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        // The folders hear files replaced (an editor's save) or added; each
        // running plugin's file hears a write in place.
        let watched = [Self.folder] + plugins.compactMap(\.folder) + plugins.filter(\.isRunning).map(\.main)
        for url in watched {
            let fd = open(url.path, O_EVTONLY)
            guard fd >= 0 else { continue }
            let source = DispatchSource.makeFileSystemObjectSource(fileDescriptor: fd, eventMask: [.write, .extend, .rename, .delete], queue: .main)
            source.setEventHandler { [weak self] in self?.scheduleRescan() }
            source.setCancelHandler { Darwin.close(fd) }
            source.resume()
            watchers.append(source)
        }
    }

    private func scheduleRescan() {
        rescanSoon?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.rescan() }
        rescanSoon = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: work)
    }
}

/// One plugin: its files, and while it runs, its context and queue.
final class Plugin {
    let name: String
    private(set) var main: URL
    private(set) var manifest: [String: Any]
    let folder: URL?
    var title: String { manifest["name"] as? String ?? name }
    var summary: String { manifest["description"] as? String ?? "" }
    var version: String { manifest["version"] as? String ?? "" }

    /// What it logged (and its errors), newest last; its commands' titles (main thread).
    private(set) var log: [(level: String, text: String, time: Date)] = []
    private(set) var commandTitles: [String] = []
    private(set) var failure: String?
    private(set) var isRunning = false

    /// One start of it: its queue, and (touched only on that queue) its
    /// context and the prelude's handle. A stopped run's timers and calls find
    /// `stopped` and do nothing.
    private final class Run {
        let queue: DispatchQueue
        var context: JSContext?
        var api: JSValue?
        var stopped = false
        /// Log lines waiting for the main thread, and whether a hop is on its way.
        let pendingLock = NSLock()
        var pending: [(String, String, Date, Bool)] = []
        var flushing = false
        /// When it last notified or typed (each at most a few times a second),
        /// and when its current call began (a call that never returns is stuck).
        var lastNotify = Date.distantPast
        var lastSend = Date.distantPast
        var busySince: Date?
        init(_ name: String) { queue = DispatchQueue(label: "dev.libertty.plugin.\(name)") }
    }
    private var current: Run?
    private var loadedDigest: Int?

    init(name: String, main: URL, manifest: [String: Any], folder: URL?) {
        self.name = name
        self.main = main
        self.manifest = manifest
        self.folder = folder
    }

    func refresh(from found: Plugin) {
        main = found.main
        manifest = found.manifest
    }

    private var source: String? { try? String(contentsOf: main, encoding: .utf8) }
    var sourceChanged: Bool { isRunning && source?.hashValue != loadedDigest }

    func startRunning() {
        // A run stuck in a loop holds its thread for good: another beside it
        // would only take a second core. It needs Libertty restarted.
        if isStuck {
            failure = "Stuck in a loop (a call that never returned): turn it off and restart Libertty to free its thread."
            PluginHost.shared.changedNow()
            return
        }
        stop()
        guard let code = source else {
            failure = "Couldn't read \(main.lastPathComponent)."
            return
        }
        failure = nil
        commandTitles = []
        log = []
        loadedDigest = code.hashValue
        isRunning = true
        let run = Run(name)
        current = run
        let fileURL = main
        // The run's own native functions hold it (until stop() lets its context go).
        run.queue.async { [weak self, run] in
            guard let self, !run.stopped else { return }
            let context = JSContext(virtualMachine: JSVirtualMachine())!
            context.name = "Libertty plugin: \(self.name)"
            context.exceptionHandler = { [weak self, weak run] _, exception in
                let text = exception.map { e -> String in
                    let line = e.objectForKeyedSubscript("line").toString() ?? ""
                    return (e.toString() ?? "error") + (line.isEmpty || line == "undefined" ? "" : " (line \(line))")
                } ?? "error"
                if let run { self?.record("error", text, run: run, failing: true) }
            }
            let prelude = context.evaluateScript(Self.prelude, withSourceURL: URL(string: "libertty-plugin-api.js"))
            run.context = context
            run.api = prelude?.call(withArguments: [self.nativeAPI(run: run)])
            Self.call(run) { context.evaluateScript(code, withSourceURL: fileURL) }
        }
        PluginHost.shared.changedNow()
    }

    func stop() {
        guard isRunning, let run = current else { return }
        isRunning = false
        commandTitles = []
        current = nil
        // Kept to ask whether it's stuck: Reload or off-and-on would
        // otherwise start another run beside a thread that never comes back.
        last = run
        // Its context goes on its own queue, after whatever is running there.
        run.queue.async {
            run.stopped = true
            run.api = nil
            run.context = nil
        }
    }

    /// Run its command `title` (the palette: by its title, so a reload that
    /// reorders them never runs another).
    func runCommand(_ title: String) {
        guard let run = current, !isStuck else { return }
        run.queue.async { Self.call(run) { run.api?.invokeMethod("runTitled", withArguments: [title]) } }
    }

    func emit(_ event: String, _ payload: [String: Any]) {
        guard let run = current, !isStuck else { return }
        run.queue.async { Self.call(run) { run.api?.invokeMethod("emit", withArguments: [event, payload]) } }
    }

    /// One call into the plugin, timed: one that hasn't returned in seconds is a loop.
    private static func call(_ run: Run, _ work: () -> Void) {
        guard !run.stopped else { return }
        run.pendingLock.lock(); run.busySince = Date(); run.pendingLock.unlock()
        work()
        run.pendingLock.lock(); run.busySince = nil; run.pendingLock.unlock()
    }

    /// Its thread has been in one call for over five seconds (an endless loop:
    /// JavaScriptCore can't be interrupted from outside, so it stays until Libertty quits).
    var isStuck: Bool {
        guard let run = current ?? last else { return false }
        run.pendingLock.lock(); defer { run.pendingLock.unlock() }
        return run.busySince.map { Date().timeIntervalSince($0) > 5 } ?? false
    }

    /// The run stopped last (its thread may still be in a call).
    private var last: Run?

    /// Lines logged on the plugin's thread, handed to the main thread in
    /// batches (a plugin printing in a loop mustn't flood it): at most 300 kept,
    /// one hop at a time.
    private func record(_ level: String, _ text: String, run: Run, failing: Bool = false) {
        run.pendingLock.lock()
        run.pending.append((level, String(text.prefix(4000)), Date(), failing))
        if run.pending.count > 300 { run.pending.removeFirst(run.pending.count - 300) }
        let schedule = !run.flushing
        run.flushing = true
        run.pendingLock.unlock()
        guard schedule else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            run.pendingLock.lock()
            let lines = run.pending
            run.pending = []
            run.flushing = false
            run.pendingLock.unlock()
            guard let self, self.current === run else { return }
            for line in lines {
                self.log.append((line.0, line.1, line.2))
                if line.3 { self.failure = line.1 }
            }
            if self.log.count > 300 { self.log.removeFirst(self.log.count - 300) }
            PluginHost.shared.changedNow()
        }
    }

    private func onMain<T>(_ work: () -> T) -> T { Thread.isMainThread ? work() : DispatchQueue.main.sync(execute: work) }

    /// The functions the prelude wraps as `libertty.*` (each checks it's still this run's).
    private func nativeAPI(run: Run) -> [String: Any] {
        let log: @convention(block) (String, String) -> Void = { [weak self] level, text in self?.record(level, text, run: run) }
        let commands: @convention(block) (String) -> Void = { [weak self] json in
            let titles = (try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String]) ?? []
            DispatchQueue.main.async {
                guard let self, self.current === run else { return }
                self.commandTitles = titles
                PluginHost.shared.changedNow()
            }
        }
        let timer: @convention(block) (Int, Double) -> Void = { [weak run] id, ms in
            run?.queue.asyncAfter(deadline: .now() + ms / 1000) { [weak run] in
                guard let run else { return }
                Self.call(run) { run.api?.invokeMethod("fire", withArguments: [id]) }
            }
        }
        let notify: @convention(block) (String, String) -> Void = { [weak self, weak run] title, body in
            // A few a second, not a flood.
            guard let run, Date().timeIntervalSince(run.lastNotify) > 0.5 else { return }
            run.lastNotify = Date()
            DispatchQueue.main.async {
                guard let self, self.current === run else { return }
                Notifier.shared.post(title: title.isEmpty ? self.title : title, body: body, pane: "")
            }
        }
        let send: @convention(block) (String) -> Void = { [weak self, weak run] text in
            guard let run, Date().timeIntervalSince(run.lastSend) > 0.05 else { return }
            run.lastSend = Date()
            let text = String(text.prefix(64_000))
            DispatchQueue.main.async {
                guard let self, self.current === run else { return }
                PluginHost.shared.frontController()?.focusedTerminal.session.sendText(text)
            }
        }
        let open: @convention(block) (String) -> Void = { [weak self] target in
            DispatchQueue.main.async {
                guard let self, self.current === run, let controller = PluginHost.shared.frontController() else { return }
                if let url = URL(string: target), ["http", "https"].contains(url.scheme?.lowercased() ?? "") {
                    controller.openBrowser(url)
                } else {
                    let base = controller.focusedWorkingDirectory ?? NSHomeDirectory()
                    let path = (target as NSString).expandingTildeInPath
                    let url = URL(fileURLWithPath: path.hasPrefix("/") ? path : (base as NSString).appendingPathComponent(path))
                    if FileManager.default.fileExists(atPath: url.path) { controller.openDocument(url) }
                }
            }
        }
        let cwd: @convention(block) () -> String = { [weak self] in
            self?.onMain { PluginHost.shared.frontController()?.focusedWorkingDirectory } ?? ""
        }
        // The last answer, kept a moment: a plugin asking in a loop reads it, not the scrollback each time.
        var screenCache: (at: Date, lines: Int, text: String)?
        let screen: @convention(block) (Int) -> String = { [weak self] lines in
            if let c = screenCache, c.lines == lines, Date().timeIntervalSince(c.at) < 0.25 { return c.text }
            let text = self?.onMain {
                guard let text = PluginHost.shared.frontController()?.focusedTerminal.session.scrollbackText() else { return "" }
                return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(max(1, min(lines, 2000))).joined(separator: "\n")
            } ?? ""
            screenCache = (Date(), lines, text)
            return text
        }
        let storageFile = PluginHost.storageFolder.appendingPathComponent(name + ".json")
        let storageGet: @convention(block) (String) -> String? = { key in
            let all = (try? Data(contentsOf: storageFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
            return all[key]
        }
        let storageSet: @convention(block) (String, String) -> Void = { key, value in
            var all = (try? Data(contentsOf: storageFile)).flatMap { try? JSONSerialization.jsonObject(with: $0) as? [String: String] } ?? [:]
            all[key] = value
            try? FileManager.default.createDirectory(at: storageFile.deletingLastPathComponent(), withIntermediateDirectories: true)
            try? JSONSerialization.data(withJSONObject: all, options: .sortedKeys).write(to: storageFile, options: .atomic)
        }
        return ["log": log, "commands": commands, "timer": timer, "notify": notify, "send": send, "open": open,
                "cwd": cwd, "screen": screen, "storageGet": storageGet, "storageSet": storageSet]
    }

    /// The API around the native functions; it keeps a plugin's functions
    /// on the JavaScript side, so nothing native holds on to them.
    private static let prelude = """
        (function (n) {
          const commands = [], handlers = {}, timers = new Map();
          let nextTimer = 1;
          const show = (args) => args.map((x) => {
            if (typeof x === "string") return x;
            if (x instanceof Error) return String(x.stack || x);
            try { return JSON.stringify(x); } catch (e) { return String(x); }
          }).join(" ");
          globalThis.console = {
            log: (...a) => n.log("log", show(a)), info: (...a) => n.log("log", show(a)),
            warn: (...a) => n.log("warn", show(a)), error: (...a) => n.log("error", show(a)),
          };
          globalThis.setTimeout = (fn, ms, ...args) => {
            const id = nextTimer++;
            timers.set(id, { fn: () => fn(...args), repeat: 0 });
            n.timer(id, Math.max(0, +ms || 0));
            return id;
          };
          globalThis.setInterval = (fn, ms, ...args) => {
            const id = nextTimer++, every = Math.max(10, +ms || 0);
            timers.set(id, { fn: () => fn(...args), repeat: every });
            n.timer(id, every);
            return id;
          };
          globalThis.clearTimeout = globalThis.clearInterval = (id) => { timers.delete(id); };
          const guard = (fn, ...args) => { try { fn(...args); } catch (e) { console.error(e); } };
          globalThis.libertty = Object.freeze({
            command(title, fn) {
              if (typeof fn !== "function") throw new TypeError("libertty.command(title, fn): fn must be a function");
              commands.push({ title: String(title), fn });
              n.commands(JSON.stringify(commands.map((c) => c.title)));
            },
            on(event, fn) {
              if (typeof fn !== "function") throw new TypeError("libertty.on(event, fn): fn must be a function");
              (handlers[event] = handlers[event] || []).push(fn);
            },
            notify(title, body) { n.notify(String(title ?? ""), String(body ?? "")); },
            send(text) { n.send(String(text)); },
            open(target) { n.open(String(target)); },
            cwd() { return n.cwd(); },
            screen(lines) { return n.screen(Math.floor(+lines) || 50); },
            storage: Object.freeze({
              get(key) { const v = n.storageGet(String(key)); return v === null || v === undefined ? undefined : JSON.parse(v); },
              set(key, value) { n.storageSet(String(key), JSON.stringify(value === undefined ? null : value)); },
            }),
          });
          return {
            runTitled(title) { const c = commands.find((x) => x.title === title); if (c) guard(c.fn); },
            emit(event, payload) { for (const fn of handlers[event] || []) guard(fn, payload); },
            fire(id) {
              const t = timers.get(id);
              if (!t) return;
              if (t.repeat) n.timer(id, t.repeat); else timers.delete(id);
              guard(t.fn);
            },
          };
        })
        """
}

/// The Plugins block: what's installed, each one on or off, its commands,
/// its log and errors; a new one from the template.
final class PluginsBlock: BlockService {
    static let symbol = "puzzlepiece.extension"
    weak var host: BlockHost?
    let title = "Plugins"
    private var observer: NSObjectProtocol?

    init() {
        DispatchQueue.main.async { [weak self] in
            PluginHost.shared.start()
            self?.observer = NotificationCenter.default.addObserver(forName: PluginHost.changed, object: nil, queue: .main) { [weak self] _ in
                self?.host?.send("changed", [:])
            }
        }
    }

    func handle(_ method: String, _ params: [String: Any], reply: @escaping (Result<Any, BlockError>) -> Void) {
        DispatchQueue.main.async {
            let pluginHost = PluginHost.shared
            pluginHost.start()
            let name = params["name"] as? String ?? ""
            switch method {
            case "list":
                let formatter = ISO8601DateFormatter()
                reply(.success([
                    "folder": PluginHost.folder.path,
                    "plugins": pluginHost.plugins.map { p -> [String: Any] in
                        ["name": p.name, "title": p.title, "description": p.summary, "version": p.version,
                         "enabled": pluginHost.isEnabled(p.name), "running": p.isRunning, "failure": p.failure as Any? ?? NSNull(),
                         "commands": p.commandTitles, "file": p.main.path,
                         "log": p.log.suffix(200).map { ["level": $0.level, "text": $0.text, "time": formatter.string(from: $0.time)] }]
                    },
                ]))
            case "enable":
                pluginHost.setEnabled(name, params["on"] as? Bool ?? false)
                reply(.success(true))
            case "reload":
                pluginHost.reload(name)
                reply(.success(true))
            case "rescan":
                pluginHost.rescan()
                reply(.success(true))
            case "edit":
                guard let p = pluginHost.plugins.first(where: { $0.name == name }) else { return reply(.failure(BlockError("no such plugin"))) }
                self.host?.editFile(p.main)
                reply(.success(true))
            case "create":
                do {
                    let file = try pluginHost.create(params["title"] as? String ?? "")
                    self.host?.editFile(file)
                    reply(.success(true))
                } catch let error as BlockError { reply(.failure(error)) } catch { reply(.failure(BlockError(error.localizedDescription))) }
            case "reveal":
                try? FileManager.default.createDirectory(at: PluginHost.folder, withIntermediateDirectories: true)
                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: PluginHost.folder.path)
                reply(.success(true))
            default:
                reply(.failure(BlockError("unknown call \(method)")))
            }
        }
    }

    func close() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
    }
}
