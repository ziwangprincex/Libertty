import Foundation
import Testing
@testable import LiberttyApp

/// git runs while every thread of the pool is busy waiting on git (many
/// calls at once on a Mac with few cores, as on CI's three): what reads its
/// stderr and writes its stdin may not wait for a thread of that pool.
struct GitCLITests {
    @Test func manyAtOnceOnEveryThread() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("many-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        _ = GitCLI.run(["init", "-q"], in: dir)
        // More than there are threads to run them: each blocks its own.
        let count = ProcessInfo.processInfo.activeProcessorCount * 3
        let answers = await withTaskGroup(of: Bool.self) { group in
            for i in 0..<count {
                group.addTask {
                    // A command with stdin, and one without.
                    if i % 2 == 0, case .success = GitCLI.execute(["hash-object", "--stdin"], in: dir, input: Data("x\n".utf8)) { return true }
                    return i % 2 == 1 && GitCLI.run(["rev-parse", "--git-dir"], in: dir) != nil
                }
            }
            var all: [Bool] = []
            for await ok in group { all.append(ok) }
            return all
        }
        #expect(answers.count == count)
        #expect(answers.allSatisfy { $0 })
    }
}
