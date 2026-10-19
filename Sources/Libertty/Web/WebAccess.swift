import AppKit
import CryptoKit
import Network

/// One terminal pane a browser can show.
struct WebPane {
    var id: String
    var title: String
    /// Window and tab, for the list.
    var place: String
    var host: String?
    var session: TerminalSession
}

/// Libertty ▸ Web Access… (`web-access`): this Mac's panes in a browser — a
/// phone on the sofa checking a long build, or answering an agent that
/// waits for you. The page shows a pane's live screen as libghostty-vt
/// formats it (colors and all) and sends keys back through the same key
/// encoder as typing here.
///
/// Off by default. `local` listens on this Mac only (use it through an ssh
/// tunnel or Tailscale); `network` on the local network too, in plain HTTP.
/// Every connection needs the secret in the link (256 random bits, kept
/// until New Link replaces it), so nobody without it can see or type
/// anything; a page from another site can't connect either.
@MainActor
final class WebAccess {
    static let shared = WebAccess()

    enum Mode: String { case off, local, network }

    private var listener: NWListener?
    private var clients: [ObjectIdentifier: WebClient] = [:]
    private(set) var mode: Mode = .off
    private(set) var port: UInt16 = 0
    private(set) var listening = false
    private(set) var lastError: String?
    var allowsInput = true

    /// What the page can show; the app's windows unless a probe replaces it.
    var panes: () -> [WebPane] = {
        ((NSApp.delegate as? AppDelegate)?.windowControllers ?? []).flatMap(\.webPanes)
    }

    static let changed = Notification.Name("LiberttyWebAccessChanged")
    private static let tokenKey = "WebAccessToken"

    /// The secret every connection must present. Tests bring their own
    /// (`LIBERTTY_WEB_TOKEN`), which is never saved.
    private(set) lazy var token: String = ProcessInfo.processInfo.environment["LIBERTTY_WEB_TOKEN"]
        ?? UserDefaults.standard.string(forKey: Self.tokenKey) ?? newToken()

    private func newToken() -> String {
        var bytes = [UInt8](repeating: 0, count: 32)
        _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
        let token = Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
        UserDefaults.standard.set(token, forKey: Self.tokenKey)
        return token
    }

    /// New Link: the old one stops working, and its open pages disconnect.
    func resetToken() {
        token = newToken()
        clients.values.forEach { $0.close() }
        clients = [:]
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    func apply(_ config: Config) {
        allowsInput = config.webAccessInput
        let wanted = Mode(rawValue: config.webAccess) ?? .off
        let wantedPort = UInt16(clamping: config.webAccessPort)
        guard wanted != mode || wantedPort != port || (wanted != .off && listener == nil) else { return }
        stop()
        mode = wanted
        port = wantedPort
        if wanted != .off { start() }
    }

    private func start() {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        if mode == .local {
            parameters.requiredLocalEndpoint = .hostPort(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!)
        }
        do {
            let listener = mode == .local ? try NWListener(using: parameters)
                : try NWListener(using: parameters, on: NWEndpoint.Port(rawValue: port)!)
            listener.stateUpdateHandler = { [weak self] state in
                MainActor.assumeIsolated { self?.listenerChanged(state) }
            }
            listener.newConnectionHandler = { [weak self] connection in
                MainActor.assumeIsolated { self?.accept(connection) }
            }
            listener.start(queue: .main)
            self.listener = listener
        } catch {
            lastError = error.localizedDescription
            NotificationCenter.default.post(name: Self.changed, object: nil)
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        listening = false
        clients.values.forEach { $0.close() }
        clients = [:]
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func listenerChanged(_ state: NWListener.State) {
        switch state {
        case .ready:
            listening = true
            lastError = nil
        case .failed(let error):
            listening = false
            lastError = error.localizedDescription
            listener?.cancel()
            listener = nil
        case .cancelled:
            listening = false
        default:
            break
        }
        NotificationCenter.default.post(name: Self.changed, object: nil)
    }

    private func accept(_ connection: NWConnection) {
        let client = WebClient(connection: connection, server: self)
        clients[ObjectIdentifier(client)] = client
        client.start()
    }

    func forget(_ client: WebClient) { clients[ObjectIdentifier(client)] = nil }

    // MARK: Who may connect

    /// Constant time, so timing says nothing about the secret.
    func accepts(_ presented: String) -> Bool {
        let a = Array(presented.utf8), b = Array(token.utf8)
        guard a.count == b.count else { return false }
        return zip(a, b).reduce(0) { $0 | ($1.0 ^ $1.1) } == 0
    }

    private var failures: [Date] = []

    /// Wrong secrets, recently: past a few a minute, everyone waits.
    var throttled: Bool {
        failures.removeAll { Date().timeIntervalSince($0) > 60 }
        return failures.count >= 10
    }

    func recordFailure() { failures.append(Date()) }

    // MARK: Links

    /// Where to open it: this Mac's name and addresses (local network), or 127.0.0.1.
    var links: [String] {
        guard mode != .off else { return [] }
        let fragment = ":\(port)/#\(token)"
        if mode == .local { return ["http://127.0.0.1" + fragment] }
        var hosts: [String] = []
        if let name = Host.current().localizedName?.replacingOccurrences(of: " ", with: "-"), !name.isEmpty {
            hosts.append(name + ".local")
        }
        hosts += Self.addresses()
        return hosts.map { "http://" + $0 + fragment }
    }

    private static func addresses() -> [String] {
        var result: [String] = []
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return [] }
        defer { freeifaddrs(ifaddr) }
        for ptr in sequence(first: first, next: { $0.pointee.ifa_next }) {
            let flags = Int32(ptr.pointee.ifa_flags)
            guard let addr = ptr.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_INET),
                  flags & IFF_UP != 0, flags & IFF_LOOPBACK == 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(addr, socklen_t(addr.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                result.append(String(cString: host))
            }
        }
        return result
    }
}

/// One browser connection: a page request, or a WebSocket that watches a pane.
@MainActor
final class WebClient {
    private let connection: NWConnection
    private weak var server: WebAccess?
    private var buffer = Data()
    private var upgraded = false
    private var fragments = Data()

    private var watched: String?
    private var sentStyle = ""
    private var sentScreen: TerminalSession.WebScreen?
    private var sentPanes = ""
    private var lastMark: UInt64 = .max
    private var timer: Timer?
    private var ticks = 0

    init(connection: NWConnection, server: WebAccess) {
        self.connection = connection
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            MainActor.assumeIsolated {
                switch state {
                case .failed, .cancelled: self?.finish()
                default: break
                }
            }
        }
        connection.start(queue: .main)
        receive()
    }

    func close() {
        if upgraded { sendFrame(opcode: 0x8, Data()) }
        connection.cancel()
        finish()
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        server?.forget(self)
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 16) { [weak self] data, _, complete, error in
            MainActor.assumeIsolated {
                guard let self else { return }
                if let data { self.buffer.append(data) }
                if self.upgraded { self.parseFrames() } else { self.parseRequest() }
                if complete || error != nil { return self.close() }
                self.receive()
            }
        }
    }

    // MARK: HTTP

    private func parseRequest() {
        guard let end = buffer.range(of: Data("\r\n\r\n".utf8)) else {
            if buffer.count > 16_384 { respond(431, "Request Header Fields Too Large") }
            return
        }
        let head = String(decoding: buffer[..<end.lowerBound], as: UTF8.self)
        buffer.removeSubrange(..<end.upperBound)
        let lines = head.components(separatedBy: "\r\n")
        let parts = lines.first?.split(separator: " ").map(String.init) ?? []
        guard parts.count >= 2, parts[0] == "GET" else { return respond(405, "Method Not Allowed") }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { continue }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        let target = URLComponents(string: parts[1])
        switch target?.path {
        case "/", "/index.html":
            // A fresh nonce each time: only the page's own script may run.
            var bytes = [UInt8](repeating: 0, count: 16)
            _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes)
            let nonce = Data(bytes).base64EncodedString()
            respond(200, "OK", type: "text/html; charset=utf-8", body: Data(WebPage.html(nonce: nonce).utf8),
                    extra: "Content-Security-Policy: default-src 'none'; script-src 'nonce-\(nonce)'; style-src 'unsafe-inline'; connect-src ws: wss:; img-src 'self' data:\r\n")
        case "/favicon.ico":
            if let icon = AppResources.url("favicon.ico").flatMap({ try? Data(contentsOf: $0) }) {
                respond(200, "OK", type: "image/x-icon", body: icon)
            } else {
                respond(404, "Not Found")
            }
        case "/ws":
            upgrade(headers: headers, token: target?.queryItems?.first { $0.name == "t" }?.value ?? "")
        default:
            respond(404, "Not Found")
        }
    }

    private func respond(_ status: Int, _ reason: String, type: String = "text/plain", body: Data? = nil, extra: String = "") {
        let body = body ?? Data((reason + "\n").utf8)
        var head = "HTTP/1.1 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\n" + extra
        head += "Cache-Control: no-store\r\nX-Frame-Options: DENY\r\nReferrer-Policy: no-referrer\r\n"
        head += "X-Content-Type-Options: nosniff\r\nConnection: close\r\n\r\n"
        connection.send(content: Data(head.utf8) + body, completion: .contentProcessed { [weak self] _ in
            MainActor.assumeIsolated { self?.connection.cancel() }
        })
    }

    private func upgrade(headers: [String: String], token: String) {
        guard let server, headers["upgrade"]?.lowercased() == "websocket", let key = headers["sec-websocket-key"] else {
            return respond(400, "Bad Request")
        }
        // Only the page Libertty served (same host and port) may open it.
        if let origin = headers["origin"], let host = headers["host"], URL(string: origin)?.hostAndPort != host {
            return respond(403, "Forbidden")
        }
        guard !server.throttled else { return respond(429, "Too Many Requests") }
        guard server.accepts(token) else {
            server.recordFailure()
            return respond(403, "Forbidden")
        }
        let accept = Data(Insecure.SHA1.hash(data: Data((key + "258EAFA5-E914-47DA-95CA-C5AB0DC85B11").utf8))).base64EncodedString()
        let head = "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: \(accept)\r\n\r\n"
        connection.send(content: Data(head.utf8), completion: .idempotent)
        upgraded = true
        let theme = ConfigStore.shared.config.resolvedTheme
        send(["t": "hello", "input": server.allowsInput, "fg": theme.foreground.hexString, "bg": theme.background.hexString,
              "cursor": theme.cursor.hexString])
        sendPanes()
        timer = Timer.scheduledTimer(withTimeInterval: 1.0 / 20, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        parseFrames()
    }

    // MARK: WebSocket

    private func parseFrames() {
        while buffer.count >= 2 {
            let bytes = [UInt8](buffer.prefix(14))
            let fin = bytes[0] & 0x80 != 0, opcode = bytes[0] & 0x0F
            let masked = bytes[1] & 0x80 != 0
            var length = Int(bytes[1] & 0x7F), offset = 2
            if length == 126 {
                guard bytes.count >= 4 else { return }
                length = Int(bytes[2]) << 8 | Int(bytes[3])
                offset = 4
            } else if length == 127 {
                guard bytes.count >= 10 else { return }
                length = bytes[2..<10].reduce(0) { $0 << 8 | Int($1) }
                offset = 10
            }
            // Browsers always mask; anything big here isn't a browser typing.
            guard masked, length <= 1 << 20 else { return close() }
            guard buffer.count >= offset + 4 + length else { return }
            let start = buffer.startIndex
            let mask = [UInt8](buffer[(start + offset)..<(start + offset + 4)])
            var payload = [UInt8](buffer[(start + offset + 4)..<(start + offset + 4 + length)])
            for i in payload.indices { payload[i] ^= mask[i % 4] }
            buffer.removeSubrange(start..<(start + offset + 4 + length))
            switch opcode {
            case 0x0, 0x1:
                fragments.append(contentsOf: payload)
                if fin {
                    handle(fragments)
                    fragments = Data()
                }
            case 0x8: return close()
            case 0x9: sendFrame(opcode: 0xA, Data(payload))
            default: break
            }
        }
    }

    private func sendFrame(opcode: UInt8, _ payload: Data) {
        var frame = Data([0x80 | opcode])
        if payload.count < 126 {
            frame.append(UInt8(payload.count))
        } else if payload.count < 1 << 16 {
            frame.append(126)
            frame.append(UInt8(payload.count >> 8))
            frame.append(UInt8(payload.count & 0xFF))
        } else {
            frame.append(127)
            for shift in stride(from: 56, through: 0, by: -8) { frame.append(UInt8((payload.count >> shift) & 0xFF)) }
        }
        frame.append(payload)
        connection.send(content: frame, completion: .idempotent)
    }

    private func send(_ message: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: message) else { return }
        sendFrame(opcode: 0x1, data)
    }

    // MARK: Messages

    private func handle(_ data: Data) {
        guard let message = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let kind = message["t"] as? String else { return }
        switch kind {
        case "watch":
            watched = message["id"] as? String
            sentScreen = nil
            lastMark = .max
            tick()
        case "key":
            guard server?.allowsInput == true, let pane = watchedPane, !pane.session.hasExited else { return }
            pane.session.sendWebKey(code: message["code"] as? String ?? "", key: message["key"] as? String ?? "",
                                    ctrl: message["ctrl"] as? Bool ?? false, alt: message["alt"] as? Bool ?? false,
                                    shift: message["shift"] as? Bool ?? false, meta: message["meta"] as? Bool ?? false)
        case "text":
            guard server?.allowsInput == true, let pane = watchedPane, !pane.session.hasExited,
                  let text = message["text"] as? String, !text.isEmpty else { return }
            // Typing goes as typed; anything with a line break is a paste
            // (bracketed for programs that ask, and nothing that could run
            // commands unasked).
            if !text.contains(where: { $0.isNewline }) {
                pane.session.sendText(text)
            } else if pane.session.paste(text, allowUnsafe: false) == .needsConfirmation {
                send(["t": "notice", "text": "Libertty didn't send that: it could run commands. Paste it on the Mac."])
            }
        case "history":
            guard let pane = watchedPane else { return }
            send(["t": "history", "id": pane.id, "text": pane.session.scrollbackText()])
        default:
            break
        }
    }

    private var watchedPane: WebPane? {
        guard let watched, let server else { return nil }
        return server.panes().first { $0.id == watched }
    }

    private func tick() {
        ticks += 1
        if ticks % 40 == 0 { sendPanes() }
        guard let watched else { return }
        guard let pane = watchedPane else {
            send(["t": "gone", "id": watched])
            self.watched = nil
            return
        }
        // Only when there was output (or once a second, for a resize).
        let mark = pane.session.outputMark.count
        guard mark != lastMark || ticks % 20 == 0 else { return }
        lastMark = mark
        guard let screen = pane.session.webScreen(), screen != sentScreen else { return }
        sentScreen = screen
        var html = screen.html
        if let end = html.range(of: "</style>") {
            let style = String(html[..<end.upperBound])
            html = String(html[end.upperBound...])
            if style != sentStyle {
                sentStyle = style
                send(["t": "style", "css": style.replacingOccurrences(of: "<style>", with: "").replacingOccurrences(of: "</style>", with: "")])
            }
        }
        send(["t": "screen", "id": pane.id, "html": html, "cols": screen.cols, "rows": screen.rows,
              "cursor": screen.cursor ?? NSNull(), "title": pane.title, "exited": pane.session.hasExited])
    }

    private func sendPanes() {
        guard let server else { return }
        let list = server.panes().map { ["id": $0.id, "title": $0.title, "place": $0.place, "host": $0.host ?? ""] }
        guard let data = try? JSONSerialization.data(withJSONObject: list), let text = String(data: data, encoding: .utf8),
              text != sentPanes else { return }
        sentPanes = text
        send(["t": "panes", "panes": list])
    }
}

private extension URL {
    /// "host:port" as a Host header says it.
    var hostAndPort: String? { host.map { h in port.map { "\(h):\($0)" } ?? h } }
}
