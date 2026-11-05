import Foundation
import Testing
@testable import LiberttyApp

/// A pane's branch and changes, as headers and sidebar rows say them.
struct RepoStatusTests {
    @Test func parse() {
        let status = """
        # branch.oid 0123456789abcdef
        # branch.head fix-login
        # branch.upstream origin/fix-login
        # branch.ab +2 -1
        1 .M N... 100644 100644 100644 a a app.swift
        ? notes.txt
        """
        let numstat = "40\t2\tapp.swift\n-\t-\timage.png\n"
        let r = RepoStatus.parse(root: "/r", status: status, numstat: numstat)
        #expect(r.branch == "fix-login" && r.added == 40 && r.removed == 2 && r.files == 2)
        #expect(r.ahead == 2 && r.behind == 1)
        #expect(r.summary == "fix-login +40 −2")
        var clean = RepoStatus.parse(root: "/r", status: "# branch.head main\n", numstat: "", operation: "rebasing")
        #expect(clean.summary == "main (rebasing)")
        clean.added = 3
        #expect(clean.summary == "main +3 (rebasing)")
        let detached = RepoStatus.parse(root: "/r", status: "# branch.oid abcdef123456\n# branch.head (detached)\n", numstat: "")
        #expect(detached.branch == "abcdef1")
    }

    @Test func readsARealRepository() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("rs-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for args in [["init", "-q", "-b", "trunk"], ["config", "user.email", "t@e"], ["config", "user.name", "t"]] { _ = GitCLI.run(args, in: dir) }
        try "one\ntwo\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        _ = GitCLI.run(["add", "-A"], in: dir)
        _ = GitCLI.run(["commit", "-qm", "First"], in: dir)
        try "one\nthree\nfour\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        let r = try #require(RepoStatus.read(directory: dir))
        #expect(r.summary == "trunk +2 −1")
        #expect(RepoStatus.read(directory: NSTemporaryDirectory()) == nil || GitCLI.root(of: NSTemporaryDirectory()) != nil)
    }
}
