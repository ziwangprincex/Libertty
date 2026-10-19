import AppKit
import CPty

/// The profiler block (Tern's profiler): macOS's `sample` on a process in a
/// terminal (or any of yours) for a few seconds; each report is kept among
/// Libertty's own and opens in the profile block (speedscope). A recording
/// can be stopped early: `sample` writes what it has.
final class ProfilerBlock: BlockService {
    static let symbol = "flame"
    weak var host: BlockHost?
    let title = "Profiler"
    /// The process the address names (Tasks ▸ Profile), picked to start with.
    let initialPID: Int?

    private var recording: Process?
    private var busy = false
    private let lock = NSLock()

    init(url: URL) {
        initialPID = Blocks.parameter("pid", of: url).flatMap { Int($0) }
    }

    static var folder: URL { Blocks.dataDirectory.appendingPathComponent("Profiles", isDirectory: true) }

    func handle(_ method: String, _ params: [String: Any], reply: @escaping (Result<Any, BlockError>) -> Void) {
        switch method {
        case "start": reply(.success(["pid": initialPID as Any? ?? NSNull()]))
        case "targets":
            let terminals = host?.terminals() ?? []
            blockWork(reply) { Self.targets(terminals) }
        case "record":
            guard let pid = (params["pid"] as? Int).flatMap(Int32.init(exactly:)), pid > 1,
                  let seconds = params["seconds"] as? Int, (1...120).contains(seconds) else {
                return reply(.failure(BlockError("which process, and for how long?")))
            }
            blockWork(reply) { try self.record(pid, seconds: seconds) }
        case "stop":
            lock.lock()
            let running = recording
            lock.unlock()
            if let running, running.isRunning { running.interrupt() }
            reply(.success(running != nil))
        case "recent": blockWork(reply) { Self.recent() }
        case "open", "remove":
            guard let path = params["path"] as? String, let url = Self.kept(path) else { return reply(.failure(BlockError("no such profile"))) }
            if method == "open" {
                DispatchQueue.main.async { self.host?.openFile(url, line: nil) }
                return reply(.success(true))
            }
            blockWork(reply) { try FileManager.default.trashItem(at: url, resultingItemURL: nil); return true }
        case "reveal":
            try? FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: Self.folder.path)
            reply(.success(true))
        default:
            reply(.failure(BlockError("unknown call \(method)")))
        }
    }

    /// A profile of ours (in the folder, by its own name).
    private static func kept(_ path: String) -> URL? {
        let url = URL(fileURLWithPath: path).standardizedFileURL
        return url.deletingLastPathComponent().path == folder.standardizedFileURL.path && FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// What runs in this window's terminals (not the shells), newest first.
    private static func targets(_ terminals: [BlockTerminal]) -> [[String: Any]] {
        let cap = 8192
        var buffer = [libertty_proc](repeating: libertty_proc(), count: cap)
        let n = Int(libertty_proc_snapshot(&buffer, Int32(cap)))
        var parent: [Int32: Int32] = [:]
        for i in 0..<n { parent[buffer[i].pid] = buffer[i].ppid }
        let shells = Dictionary(terminals.map { ($0.shell, $0) }, uniquingKeysWith: { a, _ in a })
        var rows: [[String: Any]] = []
        for i in 0..<n {
            var p = buffer[i]
            guard p.known != 0, shells[p.pid] == nil else { continue }
            var up = p.ppid, steps = 0, owner: BlockTerminal?
            while up > 1, steps < 64 {
                if let t = shells[up] { owner = t; break }
                guard let next = parent[up], next != up else { break }
                up = next
                steps += 1
            }
            guard let owner else { continue }
            let name = withUnsafePointer(to: &p.name) { $0.withMemoryRebound(to: CChar.self, capacity: 64) { String(cString: $0) } }
            rows.append(["pid": Int(p.pid), "name": name, "terminal": owner.name, "started": Int(p.started)])
        }
        return rows.sorted { ($0["started"] as? Int ?? 0) > ($1["started"] as? Int ?? 0) }
    }

    private func record(_ pid: Int32, seconds: Int) throws -> [String: Any] {
        lock.lock()
        guard !busy else { lock.unlock(); throw BlockError("A recording is already running.") }
        busy = true
        lock.unlock()
        let p = Process()
        defer { lock.lock(); recording = nil; busy = false; lock.unlock() }
        var name = [CChar](repeating: 0, count: 256)
        libertty_proc_name(pid, &name, 256)
        let program = String(cString: name).isEmpty ? "pid \(pid)" : String(cString: name)
        let stamp = DateFormatter()
        stamp.dateFormat = "yyyy-MM-dd HH.mm.ss"
        let safe = program.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        try FileManager.default.createDirectory(at: Self.folder, withIntermediateDirectories: true)
        let out = Self.folder.appendingPathComponent("\(safe) \(stamp.string(from: Date())).sample.txt")
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sample")
        // Every millisecond; `-mayDie`: symbols read up front, so a process
        // that ends mid-way still gets its report.
        p.arguments = [String(pid), String(seconds), "1", "-mayDie", "-file", out.path]
        let said = Pipe()
        p.standardOutput = said
        p.standardError = said
        try p.run()
        // Stop can reach it only once it runs (an unlaunched one can't be interrupted).
        lock.lock(); recording = p; lock.unlock()
        let text = String(decoding: said.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        guard FileManager.default.fileExists(atPath: out.path) else {
            let why = text.split(separator: "\n").first { $0.contains("cannot") || $0.contains("rror") }.map(String.init)
            throw BlockError(why.map { $0.replacingOccurrences(of: #"^sample\[\d+\]: "#, with: "", options: .regularExpression) }
                             ?? "sample couldn't record \(program).")
        }
        DispatchQueue.main.async { self.host?.openFile(out, line: nil) }
        return ["path": out.path, "name": out.lastPathComponent]
    }

    private static func recent() -> [[String: Any]] {
        let fm = FileManager.default
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey]
        let files = (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys)) ?? []
        return files.filter { $0.lastPathComponent.hasSuffix(".sample.txt") }.compactMap { url -> [String: Any]? in
            let values = try? url.resourceValues(forKeys: Set(keys))
            return ["path": url.path, "name": url.lastPathComponent.replacingOccurrences(of: ".sample.txt", with: ""),
                    "time": Int(values?.contentModificationDate?.timeIntervalSince1970 ?? 0), "size": values?.fileSize ?? 0]
        }.sorted { ($0["time"] as? Int ?? 0) > ($1["time"] as? Int ?? 0) }
    }

    func close() {
        lock.lock()
        if let recording, recording.isRunning { recording.interrupt() }
        lock.unlock()
    }
}
