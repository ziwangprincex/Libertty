import Foundation
import Testing
import CGhosttyVt
import LiberttyCore

/// liberttyd's protocol: frames over a socket pair, as the app and the daemon send them.
struct WireTests {
    private func pair() -> (Connection, Connection) {
        var fds: [Int32] = [0, 0]
        precondition(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        return (Connection(fd: fds[0]), Connection(fd: fds[1]))
    }

    @Test func jsonFrameArrives() throws {
        let (a, b) = pair()
        #expect(a.send(.list, json: ["probe": 1]))
        let frame = try #require(b.receive())
        #expect(frame.kind == .list)
        #expect(frame.json["probe"] as? Int == 1)
    }

    @Test func headerAndBodySplit() throws {
        let body = Data("screen bytes".utf8)
        let payload = body.withUnsafeBytes { Connection.headed(["session": "abc"], body: $0) }
        let (a, b) = pair()
        payload.withUnsafeBytes { _ = a.send(.attached, $0) }
        let frame = try #require(b.receive())
        let (header, rest) = try #require(frame.headerAndBody)
        #expect(header["session"] as? String == "abc")
        #expect(rest == body)
    }

    @Test func manyFramesInOrder() {
        let (a, b) = pair()
        for i in 0..<200 { _ = a.send(.input, Data("\(i)".utf8)) }
        var seen: [String] = []
        while seen.count < 200, let f = b.receive() { seen.append(String(decoding: f.payload, as: UTF8.self)) }
        #expect(seen == (0..<200).map(String.init))
    }

    /// `+wait --timeout inf` (or a number too big for a time) waits forever
    /// instead of trapping; a real one still runs out.
    @Test func timeoutsThatArentTimes() {
        let (a, b) = pair()
        for seconds in [Double.infinity, -.infinity, .nan, 1e300, -1, 0] {
            a.setReceiveTimeout(seconds)
            a.setSendTimeout(seconds)
        }
        b.setReceiveTimeout(0.2)
        let start = Date()
        #expect(b.receive() == nil)
        #expect(Date().timeIntervalSince(start) < 5)
        #expect(a.send(.list, json: [:]))
    }

    /// A host's liberttyd could answer with any numbers: a window clamps
    /// them rather than trap (and take the whole app down).
    @Test func numbersOutOfRangeFromLiberttyd() throws {
        let (app, daemon) = pair()
        let address = DaemonAddress(host: "host") { app }
        let server = Thread {
            guard let create = daemon.receive(), create.kind == .create else { return }
            let header: [String: Any] = ["id": "s", "pid": Int.max, "cols": 1 << 40, "rows": -7, "sizes": true]
            _ = daemon.send(.attached, header: header, body: UnsafeRawBufferPointer(start: nil, count: 0))
            _ = daemon.send(.ptySize, json: ["cols": -1, "rows": Int.max])
            _ = daemon.send(.exited, json: ["status": Int.min])
            daemon.close()
        }
        server.start()
        let request = CreateRequest(id: "s", executable: "/bin/sh", arguments: [], environment: [:], workingDirectory: "/",
                                    size: GridSize(cols: 80, rows: 24, widthPx: 0, heightPx: 0), scrollback: 0)
        let queue = DispatchQueue(label: "test.remote")
        let pty = try RemotePTY.create(request, address: address, queue: queue)
        #expect(pty.pid == pid_t.max)
        #expect(pty.ptySize?.cols == UInt16.max && pty.ptySize?.rows == 0)
        let ended = DispatchSemaphore(value: 0)
        nonisolated(unsafe) var status: Int32?
        pty.onExit = { status = $0; ended.signal() }
        pty.startReading()
        #expect(ended.wait(timeout: .now() + 5) == .success)
        #expect(status == 0)
        #expect(pty.ptySize?.cols == 0 && pty.ptySize?.rows == UInt16.max)
        pty.detach()
    }

    /// A liberttyd handing its sessions over refuses to start one; a window
    /// asks again — through the moment nothing answers — and the newer one does.
    @Test func aSessionAskedForMidTakeoverStartsInTheNewerOne() throws {
        let dials = NSLock()
        nonisolated(unsafe) var dialed = 0
        let address = DaemonAddress(host: "") { [self] in
            let n = dials.withLock { dialed += 1; return dialed }
            if n == 2 { return nil }  // the old one gone, the newer not yet listening
            let (app, end) = pair()
            nonisolated(unsafe) let daemon = end
            Thread {
                guard let create = daemon.receive(), create.kind == .create else { return }
                if n == 1 {
                    _ = daemon.send(.result, json: ["ok": false, "error": Wire.handingOver])
                } else {
                    _ = daemon.send(.attached, header: ["id": "s", "pid": 42], body: UnsafeRawBufferPointer(start: nil, count: 0))
                }
                _ = daemon.receive()
            }.start()
            return app
        }
        let request = CreateRequest(id: "s", executable: "/bin/sh", arguments: [], environment: [:], workingDirectory: "/",
                                    size: GridSize(cols: 80, rows: 24, widthPx: 0, heightPx: 0), scrollback: 0)
        let pty = try RemotePTY.create(request, address: address, queue: DispatchQueue(label: "test.remote"))
        #expect(pty.pid == 42)
        #expect(dials.withLock { dialed } == 3)
        pty.detach()
    }

    @Test func osc7Paths() {
        #expect(SessionInfo.fileURL("file://mac/Users/me/%E6%88%91%E7%9A%84%20%E6%96%87%E6%A1%A3")! == ("mac", "/Users/me/我的 文档"))
        #expect(SessionInfo.fileURL("file://mac/tmp/a#b?c")! == ("mac", "/tmp/a#b?c"))
        #expect(SessionInfo.fileURL("file:///tmp/x")! == ("", "/tmp/x"))
        #expect(SessionInfo.fileURL("http://x/y") == nil)
        #expect(SessionInfo.percentDecoded("100%") == nil)
        #expect(SessionInfo.percentDecoded("%ff") == nil)
        #expect(SessionInfo.percentDecoded("a%2Fb") == "a/b")
    }
}

/// A session's snapshot, which a window attaching to liberttyd starts from.
struct SnapshotTests {
    /// A terminal holding `count` kitty images of `side`×`side` RGBA pixels.
    private func terminal(images count: Int, side: Int) -> GhosttyTerminal {
        var t: GhosttyTerminal?
        _ = ghostty_terminal_new(nil, &t, 80, 24)
        KittyGraphics.enableForDaemon(on: t!)
        let pixels = Array(Data(repeating: 0x7f, count: side * side * 4).base64EncodedString().utf8)
        for id in 1...count {
            var bytes: [UInt8] = []
            var offset = 0
            repeat {
                let end = min(pixels.count, offset + 4096)
                let more = end < pixels.count ? 1 : 0
                let head = offset == 0 ? "\u{1b}_Ga=t,f=32,s=\(side),v=\(side),i=\(id),q=2,m=\(more);" : "\u{1b}_Gm=\(more);"
                bytes += Array(head.utf8) + pixels[offset..<end] + Array("\u{1b}\\".utf8)
                offset = end
            } while offset < pixels.count
            bytes.withUnsafeBufferPointer { ghostty_terminal_vt_write(t!, $0.baseAddress, $0.count) }
        }
        return t!
    }

    private func images(_ terminal: GhosttyTerminal, upTo count: Int) -> [Int] {
        var graphics: GhosttyKittyGraphics?
        guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics) == GHOSTTY_SUCCESS,
              let graphics else { return [] }
        return (1...count).filter { ghostty_kitty_graphics_image(graphics, UInt32($0)) != nil }
    }

    /// 16 MB of images: more than libghostty keeps by default when it decodes.
    @Test func aSnapshotKeepsItsImages() throws {
        let source = terminal(images: 4, side: 1024)
        defer { ghostty_terminal_free(source) }
        #expect(images(source, upTo: 4) == [1, 2, 3, 4])
        let snapshot = try #require(Snapshots.encode(source))
        let restored = try #require(Snapshots.decode(snapshot, trackContinuation: false))
        defer { ghostty_terminal_free(restored) }
        #expect(images(restored, upTo: 4) == [1, 2, 3, 4])
    }

    /// A snapshot too big for a frame (images' raw pixels: up to 320 MB a
    /// screen) keeps its screen and as many of its newest images as fit.
    @Test func aSnapshotFitsInAFrame() throws {
        let source = terminal(images: 4, side: 1024)
        defer { ghostty_terminal_free(source) }
        Array("kept\r\n".utf8).withUnsafeBufferPointer { ghostty_terminal_vt_write(source, $0.baseAddress, $0.count) }
        let full = try #require(Snapshots.encode(source))
        #expect(Snapshots.fitting(full, limit: full.count) == full)
        let limit = 10 << 20
        let fitted = try #require(Snapshots.encode(source, fitting: limit))
        #expect(fitted.count <= limit && fitted.count < full.count)
        let restored = try #require(Snapshots.decode(fitted, trackContinuation: false))
        defer { ghostty_terminal_free(restored) }
        let kept = images(restored, upTo: 4)
        #expect(!kept.isEmpty && kept.contains(4) && !kept.contains(1))
        #expect(Snapshots.plainText(restored, scrollback: true).contains("kept"))
        // Not even the screen fits: none.
        #expect(Snapshots.fitting(full, limit: 16) == nil)
    }

    /// A frame bigger than the other side takes isn't sent (it would hang
    /// up on it as garbage): the send fails, and the connection goes on.
    @Test func noFrameOverTheLimit() throws {
        var fds: [Int32] = [0, 0]
        #expect(socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0)
        let (a, b) = (Connection(fd: fds[0]), Connection(fd: fds[1]))
        // (Never touched: it's refused for its size.)
        let huge = UnsafeMutableRawPointer.allocate(byteCount: Wire.maxFrame, alignment: 16)
        defer { huge.deallocate() }
        #expect(!a.send(.snapshot, UnsafeRawBufferPointer(start: huge, count: Wire.maxFrame)))
        #expect(a.send(.list, json: ["after": 1]))
        let frame = try #require(b.receive())
        #expect(frame.kind == .list && frame.json["after"] as? Int == 1)
    }
}
