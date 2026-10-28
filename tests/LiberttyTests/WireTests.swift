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
}
