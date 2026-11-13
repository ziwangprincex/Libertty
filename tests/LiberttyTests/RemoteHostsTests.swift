import Foundation
import Testing
@testable import LiberttyApp

/// Remote Hosts: what ssh's failures say can be fixed, and the list's order.
struct RemoteHostsTests {
    static let changedKey = """
    @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    @    WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!     @
    @@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@@
    IT IS POSSIBLE THAT SOMEONE IS DOING SOMETHING NASTY!
    Someone could be eavesdropping on you right now (man-in-the-middle attack)!
    It is also possible that a host key has just been changed.
    The fingerprint for the ED25519 key sent by the remote host is
    SHA256:zR3cXxV6L6Xl0Jm0Ap7Gm7lR8yA3q1x7rC9mZ2sQb4E.
    Please contact your system administrator.
    Add correct host key in /Users/me/.ssh/known_hosts to get rid of this message.
    Offending ED25519 key in /Users/me/.ssh/known_hosts:12
    Host key for [devbox.example]:2222 has changed and you have requested strict checking.
    Host key verification failed.
    """

    @Test func changedHostKey() {
        let problem = SSHRecovery.diagnose(Self.changedKey)
        #expect(problem == .changedHostKey(host: "[devbox.example]:2222",
                                           fingerprint: "SHA256:zR3cXxV6L6Xl0Jm0Ap7Gm7lR8yA3q1x7rC9mZ2sQb4E.",
                                           file: "/Users/me/.ssh/known_hosts", line: 12))
    }

    @Test func keysNotLoaded() {
        let refused = "me@devbox: Permission denied (publickey,password)."
        #expect(SSHRecovery.diagnose(refused, agentHasKeys: { false }, keysOnDisk: { ["/k/id_ed25519"] })
                == .keysNotLoaded(["/k/id_ed25519"]))
        // ssh-agent has some: nothing to offer.
        #expect(SSHRecovery.diagnose(refused, agentHasKeys: { true }, keysOnDisk: { ["/k/id_ed25519"] }) == nil)
        #expect(SSHRecovery.diagnose("ssh: connect to host devbox port 22: Operation timed out") == nil)
    }

    /// The old key goes from the file that has it (ssh-keygen keeps the file as it was beside it).
    @Test func removesTheOldKey() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("known-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let file = dir.appendingPathComponent("known_hosts")
        let other = "other.example ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIOMqqnkVzrm0SdG6UOoqKLsabgH5C9okWi0dh2l9GKJl"
        try """
        [devbox.example]:2222 ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIBCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrs
        \(other)

        """.write(to: file, atomically: true, encoding: .utf8)
        #expect(SSHRecovery.removeOldKey(host: "[devbox.example]:2222", file: file.path) == nil)
        let left = try String(contentsOf: file, encoding: .utf8)
        #expect(!left.contains("devbox") && left.contains(other))
        #expect(FileManager.default.fileExists(atPath: file.path + ".old"))
    }

    @Test func reorders() {
        let list = ["a", "b", "c", "d"]
        #expect(SavedHosts.reordered(list, fromOffsets: [0], toOffset: 3) == ["b", "c", "a", "d"])
        #expect(SavedHosts.reordered(list, fromOffsets: [3], toOffset: 0) == ["d", "a", "b", "c"])
        #expect(SavedHosts.reordered(list, fromOffsets: [1, 2], toOffset: 4) == ["a", "d", "b", "c"])
        #expect(SavedHosts.isValid("me@box") && !SavedHosts.isValid("-oProxy=x") && !SavedHosts.isValid("a b"))
    }
}
