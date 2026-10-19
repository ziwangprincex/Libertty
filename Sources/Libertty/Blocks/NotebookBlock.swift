import AppKit

/// A `jupyter server` of the user's, started by Libertty for one folder
/// (its notebooks share it): on 127.0.0.1, a free port, a token that never
/// leaves this process. It stops when its last notebook closes, or with Libertty.
final class JupyterServer {
    let root: String
    let port: Int
    let token: String
    private let process: Process
    private var users = 0
    private static var servers: [String: JupyterServer] = [:]
    private static let lock = NSLock()
    private static var quitting: NSObjectProtocol?

    var base: URL { URL(string: "http://127.0.0.1:\(port)")! }

    private init(root: String, port: Int, token: String, process: Process) {
        self.root = root
        self.port = port
        self.token = token
        self.process = process
    }

    /// The jupyter command: the config's, else the login shell's.
    static var command: String? {
        let configured = ConfigStore.shared.config.jupyter
        if !configured.isEmpty { return FileManager.default.isExecutableFile(atPath: configured) ? configured : nil }
        for dir in LoginShell.path.split(separator: ":") {
            let candidate = String(dir) + "/jupyter"
            if FileManager.default.isExecutableFile(atPath: candidate) { return candidate }
        }
        return nil
    }

    /// The server for `root`, started if need be (off the main thread: it takes seconds).
    /// Folders whose server is starting: a second notebook waits for it.
    private static var starting: Set<String> = []
    private static let started = NSCondition()

    static func acquire(root: String) throws -> JupyterServer {
        started.lock()
        while starting.contains(root) { started.wait() }
        lock.lock()
        if let running = servers[root], running.process.isRunning {
            running.users += 1
            lock.unlock()
            started.unlock()
            return running
        }
        lock.unlock()
        starting.insert(root)
        started.unlock()
        defer {
            started.lock()
            starting.remove(root)
            started.broadcast()
            started.unlock()
        }
        guard let jupyter = command else {
            throw BlockError("No jupyter found. Install it (pip install jupyter_server ipykernel) or set `jupyter = /path/to/jupyter` in the config.")
        }
        let port = try freePort()
        var bytes = [UInt8](repeating: 0, count: 24)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = bytes.map { String(format: "%02x", $0) }.joined()
        // The token in a config file only the server reads (0600, removed once
        // it's up): not the command line `ps` shows, nor the environment every
        // kernel inherits (`os.environ` would print it into the notebook).
        let configDir = FileManager.default.temporaryDirectory.appendingPathComponent("libertty-jupyter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: configDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let configFile = configDir.appendingPathComponent("jupyter_server_config.json")
        let config = ["IdentityProvider": ["token": token], "ServerApp": ["token": token]]
        try JSONSerialization.data(withJSONObject: config).write(to: configFile)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configFile.path)
        defer { try? FileManager.default.removeItem(at: configDir) }
        let p = Process()
        // Through a shell that watches Libertty: a crash (or any exit that
        // skips willTerminate) mustn't leave a server and its kernels behind.
        // SIGTERM to the shell stops the server too.
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        let watch = """
            "$0" "$@" & server=$!
            trap 'kill $server 2>/dev/null; wait $server; exit 0' TERM INT HUP
            while kill -0 $LIBERTTY_PID 2>/dev/null && kill -0 $server 2>/dev/null; do sleep 1; done
            kill $server 2>/dev/null; wait $server
            """
        p.arguments = ["-c", watch, jupyter, "server", "--config=\(configFile.path)", "--no-browser", "--ServerApp.ip=127.0.0.1", "--ServerApp.port=\(port)",
                       "--ServerApp.port_retries=0", "--ServerApp.root_dir=\(root)", "--ServerApp.open_browser=False"]
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = LoginShell.path
        env["LIBERTTY_PID"] = String(getpid())
        // Libertty's own (its sockets, its test switches) aren't the kernel's business.
        for key in env.keys where key.hasPrefix("LIBERTTY_") && key != "LIBERTTY_PID" { env[key] = nil }
        p.environment = env
        p.currentDirectoryURL = URL(fileURLWithPath: root)
        let log = Pipe()
        p.standardOutput = log
        p.standardError = log
        p.standardInput = FileHandle.nullDevice
        var said = Data()
        let saidLock = NSLock()
        log.fileHandleForReading.readabilityHandler = { handle in
            let chunk = handle.availableData
            saidLock.lock(); if said.count < 64_000 { said.append(chunk) }; saidLock.unlock()
        }
        try p.run()
        let server = JupyterServer(root: root, port: port, token: token, process: p)
        // Up once its API answers (a first run builds caches: allow time).
        let deadline = Date().addingTimeInterval(45)
        while Date() < deadline {
            if !p.isRunning { break }
            if (try? server.request("GET", "/api/status", timeout: 1)) != nil {
                lock.lock()
                server.users = 1
                servers[root] = server
                watchQuit()
                lock.unlock()
                return server
            }
            Thread.sleep(forTimeInterval: 0.25)
        }
        p.terminate()
        saidLock.lock()
        let text = String(decoding: said, as: UTF8.self)
        saidLock.unlock()
        let last = text.split(separator: "\n").suffix(3).joined(separator: "\n")
        throw BlockError("jupyter server didn't start" + (last.isEmpty ? "." : ": " + last))
    }

    func release() {
        Self.lock.lock()
        users -= 1
        let done = users <= 0
        // Only this one's entry (another may have taken the folder since).
        if done, Self.servers[root] === self { Self.servers[root] = nil }
        Self.lock.unlock()
        if done { process.terminate() }
    }

    private static func watchQuit() {
        guard quitting == nil else { return }
        quitting = NotificationCenter.default.addObserver(forName: NSApplication.willTerminateNotification, object: nil, queue: nil) { _ in
            lock.lock()
            let all = servers.values
            servers = [:]
            lock.unlock()
            all.forEach { $0.process.terminate() }
        }
    }

    private static func freePort() throws -> Int {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw BlockError("no socket") }
        defer { Darwin.close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        addr.sin_port = 0
        var size = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, size) == 0 && getsockname(fd, $0, &size) == 0 }
        }
        guard bound else { throw BlockError("no free port") }
        return Int(UInt16(bigEndian: addr.sin_port))
    }

    /// One call to its REST API (synchronous: callers are off the main thread).
    @discardableResult
    func request(_ method: String, _ path: String, body: [String: Any]? = nil, timeout: TimeInterval = 20) throws -> Any {
        var req = URLRequest(url: base.appendingPathComponent(path), timeoutInterval: timeout)
        req.httpMethod = method
        req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        if let body {
            req.httpBody = try JSONSerialization.data(withJSONObject: body)
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        let done = DispatchSemaphore(value: 0)
        var result: Result<(Data, HTTPURLResponse), Error> = .failure(BlockError("no answer"))
        URLSession.shared.dataTask(with: req) { data, response, error in
            if let error { result = .failure(error) } else if let http = response as? HTTPURLResponse { result = .success((data ?? Data(), http)) }
            done.signal()
        }.resume()
        done.wait()
        let (data, http) = try result.get()
        guard (200..<300).contains(http.statusCode) else {
            let message = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["message"] as? String
            throw BlockError("jupyter: \(message ?? HTTPURLResponse.localizedString(forStatusCode: http.statusCode))")
        }
        return data.isEmpty ? [String: Any]() : (try? JSONSerialization.jsonObject(with: data)) ?? [String: Any]()
    }

    func webSocket(kernel: String, session: String) -> URLSessionWebSocketTask {
        var parts = URLComponents(url: base, resolvingAgainstBaseURL: false)!
        parts.scheme = "ws"
        parts.path = "/api/kernels/\(kernel)/channels"
        parts.queryItems = [URLQueryItem(name: "session_id", value: session)]
        var req = URLRequest(url: parts.url!)
        req.setValue("token \(token)", forHTTPHeaderField: "Authorization")
        return URLSession.shared.webSocketTask(with: req)
    }
}

/// The notebook block (Tern's notebooks): an .ipynb file's cells, edited and
/// saved as the other file blocks are, run in a kernel of the user's own
/// Jupyter (see `JupyterServer`). The page never sees the server or its token:
/// it asks this side to run code and hears the kernel's messages.
final class NotebookBlock: FileBlock {
    override class var symbol: String { "book.pages" }

    private var server: JupyterServer?
    private var sessionID: String?
    private var kernelID: String?
    private var socket: URLSessionWebSocketTask?
    private let clientSession = UUID().uuidString
    private let kernelQueue = DispatchQueue(label: "dev.libertty.notebook")

    override func handleMore(_ method: String, _ params: [String: Any], reply: @escaping (Result<Any, BlockError>) -> Void) {
        switch method {
        case "markdown":
            var renderer = MarkdownRenderer()
            reply(.success(renderer.render(params["text"] as? String ?? "")))
        case "jupyter":
            reply(.success(["found": JupyterServer.command != nil]))
        case "kernelStart":
            let name = params["kernel"] as? String
            kernelQueue.async { do { reply(.success(try self.startKernel(name))) } catch { reply(.failure(error as? BlockError ?? BlockError(error.localizedDescription))) } }
        case "kernelspecs":
            kernelQueue.async {
                do {
                    guard let server = self.server else { throw BlockError("no kernel yet") }
                    let specs = try server.request("GET", "/api/kernelspecs") as? [String: Any] ?? [:]
                    let all = (specs["kernelspecs"] as? [String: Any] ?? [:]).compactMap { key, value -> [String: Any]? in
                        let spec = (value as? [String: Any])?["spec"] as? [String: Any]
                        return ["name": key, "display": spec?["display_name"] as? String ?? key, "language": spec?["language"] as? String ?? ""]
                    }
                    reply(.success(["default": specs["default"] ?? "", "specs": all]))
                } catch { reply(.failure(error as? BlockError ?? BlockError(error.localizedDescription))) }
            }
        case "execute":
            guard let code = params["code"] as? String else { return reply(.failure(BlockError("nothing to run"))) }
            kernelQueue.async {
                do { reply(.success(try self.execute(code))) } catch { reply(.failure(error as? BlockError ?? BlockError(error.localizedDescription))) }
            }
        case "interrupt", "restart":
            kernelQueue.async {
                do {
                    guard let server = self.server, let kernel = self.kernelID else { throw BlockError("no kernel running") }
                    try server.request("POST", "/api/kernels/\(kernel)/\(method)", body: [:], timeout: 60)
                    reply(.success(true))
                } catch { reply(.failure(error as? BlockError ?? BlockError(error.localizedDescription))) }
            }
        case "openLink":
            guard let link = params["url"] as? String, let url = URL(string: link), ["http", "https"].contains(url.scheme?.lowercased() ?? "") else {
                return reply(.failure(BlockError("not a web address")))
            }
            DispatchQueue.main.async { self.host?.openBrowser(url) }
            reply(.success(true))
        default:
            super.handleMore(method, params, reply: reply)
        }
    }

    /// A session for this notebook in its folder's server, and the kernel's channels.
    private func startKernel(_ name: String?) throws -> [String: Any] {
        guard !closed else { throw BlockError("closed") }
        if server == nil { server = try JupyterServer.acquire(root: file.deletingLastPathComponent().path) }
        guard let server else { throw BlockError("no server") }
        if let session = sessionID {
            _ = try? server.request("DELETE", "/api/sessions/\(session)")
            socket?.cancel()
            sessionID = nil
        }
        var kernel: [String: Any] = [:]
        if let name, !name.isEmpty { kernel["name"] = name }
        let made = try server.request("POST", "/api/sessions", body: ["path": file.lastPathComponent, "type": "notebook",
                                                                       "name": file.lastPathComponent, "kernel": kernel], timeout: 60) as? [String: Any] ?? [:]
        guard let session = made["id"] as? String, let k = made["kernel"] as? [String: Any], let kid = k["id"] as? String else {
            throw BlockError("jupyter made no session")
        }
        sessionID = session
        kernelID = kid
        let ws = server.webSocket(kernel: kid, session: clientSession)
        // A plot or a big table is one message of several MB (the default is 1 MB).
        ws.maximumMessageSize = 64 << 20
        socket = ws
        ws.resume()
        listen(ws)
        // Closed while it started: nothing is kept.
        if closed { letGo(); throw BlockError("closed") }
        return ["kernel": k["name"] as? String ?? name ?? "", "id": kid]
    }

    private func execute(_ code: String) throws -> String {
        guard let socket else { throw BlockError("no kernel running") }
        let id = UUID().uuidString
        let message: [String: Any] = [
            "header": ["msg_id": id, "username": NSUserName(), "session": clientSession, "msg_type": "execute_request",
                       "version": "5.3", "date": ISO8601DateFormatter().string(from: Date())],
            "parent_header": [:], "metadata": [:], "channel": "shell", "buffers": [],
            "content": ["code": code, "silent": false, "store_history": true, "user_expressions": [:], "allow_stdin": false, "stop_on_error": true],
        ]
        let data = try JSONSerialization.data(withJSONObject: message)
        socket.send(.string(String(decoding: data, as: UTF8.self))) { [weak self] error in
            if let error { DispatchQueue.main.async { self?.host?.send("kernelError", ["message": error.localizedDescription]) } }
        }
        return id
    }

    /// The kernel's messages, each to the page: what it answers to, its type and content.
    private func listen(_ ws: URLSessionWebSocketTask) {
        ws.receive { [weak self, weak ws] result in
            guard let self, let ws, ws === self.socket else { return }
            switch result {
            case .failure(let error):
                self.kernelQueue.async { if self.socket === ws { self.socket = nil } }
                DispatchQueue.main.async { self.host?.send("kernelError", ["message": "The kernel's connection closed: \(error.localizedDescription)"]) }
            case .success(let message):
                var data: Data?
                switch message {
                case .string(let s): data = Data(s.utf8)
                case .data(let d): data = d
                @unknown default: break
                }
                if let data, let msg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
                    let header = msg["header"] as? [String: Any] ?? [:], parent = msg["parent_header"] as? [String: Any] ?? [:]
                    let forward: [String: Any] = ["parent": parent["msg_id"] as? String ?? "", "type": header["msg_type"] as? String ?? "",
                                                  "channel": msg["channel"] as? String ?? "", "content": msg["content"] ?? [:]]
                    DispatchQueue.main.async { self.host?.send("kernel", forward) }
                }
                self.listen(ws)
            }
        }
    }

    /// The kernel and the server let go of (the next Run starts them again).
    /// On the kernel's queue, after whatever start is running there.
    override func suspend() {
        kernelQueue.async { self.letGo() }
    }

    private func letGo() {
        let server = self.server, session = sessionID, socket = self.socket
        self.socket = nil
        self.server = nil
        sessionID = nil
        kernelID = nil
        if server != nil { DispatchQueue.main.async { self.host?.send("kernelStopped", [:]) } }
        socket?.cancel(with: .goingAway, reason: nil)
        if let server {
            if let session { _ = try? server.request("DELETE", "/api/sessions/\(session)", timeout: 5) }
            server.release()
        }
    }

    /// Gone for good: a start still on its way lets go of what it gets.
    private var closed = false

    override func close() {
        super.close()
        kernelQueue.async {
            self.closed = true
            self.letGo()
        }
    }
}
