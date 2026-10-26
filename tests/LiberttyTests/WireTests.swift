import Foundation
import Testing
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
}
