import Foundation
import Testing
@testable import LiberttyApp

/// `git diff` into the file a document shows (Show Changes, the Git panel's
/// file diffs, `libertty +diff`): cut where the Git block cuts its own.
struct GitDiffTests {
    @Test func aBigDiffIsCutShortAndSaysSo() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("gitdiff-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        _ = GitCLI.run(["init", "-q"], in: dir.path)
        try Data("one\ntwo\n".utf8).write(to: dir.appendingPathComponent("small.txt"))
        let line = String(repeating: "x", count: 99) + "\n"
        try Data(String(repeating: line, count: 30_000).utf8).write(to: dir.appendingPathComponent("big.log"))
        func diff(_ file: String) throws -> String {
            let written = try GitDiff.write(directory: dir.path, arguments: ["--no-index", "--", "/dev/null", file],
                                            name: "test/\(UUID().uuidString)/\(file)", literal: true).get()
            defer { try? FileManager.default.removeItem(at: written) }
            return try String(contentsOf: written, encoding: .utf8)
        }

        let small = try diff("small.txt")
        #expect(small.hasPrefix("diff --git") && small.hasSuffix("+two\n"))

        // A new 3 MB log: its first 2 MB, in whole lines, after a word on the rest.
        let big = try diff("big.log")
        #expect(big.hasPrefix("The diff is cut short: it's over 2 MB."))
        #expect(big.utf8.count <= GitBlock.diffLimit + 200 && big.utf8.count > GitBlock.diffLimit - 200)
        #expect(big.hasSuffix("+" + line))
        #expect(DiffRenderer.html(big).contains("<pre class=\"preamble\">The diff is cut short"))
    }
}
