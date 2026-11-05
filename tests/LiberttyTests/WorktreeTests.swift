import Foundation
import Testing
@testable import LiberttyApp

/// Tabs in a worktree of their own: where it goes, git ignoring it, what
/// closing asks, and removing it — on a real repository.
struct WorktreeTests {
    private func repo() throws -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("wt-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.com"], ["config", "user.name", "t"]] {
            _ = GitCLI.run(args, in: dir)
        }
        try "one\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        _ = GitCLI.run(["add", "-A"], in: dir)
        _ = GitCLI.run(["commit", "-qm", "First"], in: dir)
        return GitCLI.root(of: dir) ?? dir
    }

    @Test func whereItGoes() {
        #expect(Worktrees.path(root: "/r", branch: "fix/login", setting: "") == "/r/.libertty/worktrees/fix/login")
        #expect(Worktrees.path(root: "/r", branch: "b", setting: "../trees") == "/trees/b")
        #expect(Worktrees.path(root: "/r", branch: "b", setting: "/tmp/w") == "/tmp/w/b")
        #expect(Worktrees.excludeLine(root: "/r", path: "/r/.libertty/worktrees/b") == "/.libertty/")
        #expect(Worktrees.excludeLine(root: "/r", path: "/elsewhere/b") == nil)
    }

    @Test func excludeWrites() throws {
        let root = try repo()
        defer { try? FileManager.default.removeItem(atPath: root) }
        Worktrees.exclude("/x/", root: root)
        let text = try String(contentsOfFile: root + "/.git/info/exclude", encoding: .utf8)
        #expect(text.hasSuffix("/x/\n"))
        // Once.
        Worktrees.exclude("/x/", root: root)
        #expect(try String(contentsOfFile: root + "/.git/info/exclude", encoding: .utf8).components(separatedBy: "/x/").count == 2)
    }

    private func list() -> URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("worktrees-\(UUID().uuidString).json")
    }

    @Test func makeUseAndRemove() throws {
        let root = try repo(), made = list()
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(at: made) }
        #expect(!Worktrees.isValidBranch("two words", in: root))
        #expect(!Worktrees.isValidBranch("-x", in: root))
        guard case .success(let path) = Worktrees.create(root: root, branch: "fix-login", base: nil, setting: "", made: made) else {
            Issue.record("no worktree"); return
        }
        #expect(path == root + "/.libertty/worktrees/fix-login")
        // Libertty made it: a tab in it (or in a folder in it) is a tab of it.
        #expect(Worktrees.made(at: made) == [WorktreeInfo(root: root, path: path, branch: "fix-login")])
        try FileManager.default.createDirectory(atPath: path + "/src", withIntermediateDirectories: true)
        #expect(Worktrees.made(containing: path + "/src", among: Worktrees.made(at: made))?.path == path)
        #expect(Worktrees.made(containing: root, among: Worktrees.made(at: made)) == nil)
        #expect(GitCLI.run(["branch", "--show-current"], in: path) == "fix-login")
        // Ignored through info/exclude, not .gitignore: the main checkout stays clean.
        #expect(!FileManager.default.fileExists(atPath: root + "/.gitignore"))
        #expect(Worktrees.uncommitted(root) == 0)
        let linked = try #require(Worktrees.linked(at: path))
        #expect(linked == WorktreeInfo(root: root, path: path, branch: "fix-login"))
        #expect(Worktrees.linked(at: root) == nil)
        // Making it again: it's there.
        if case .success = Worktrees.create(root: root, branch: "fix-login", base: nil, setting: "", made: made) { Issue.record("made twice") }
        try "two\n".write(toFile: path + "/b.txt", atomically: true, encoding: .utf8)
        #expect(Worktrees.uncommitted(path) == 1)
        // Not without force while it has changes.
        if case .success = Worktrees.remove(linked, force: false, made: made) { Issue.record("removed with changes") }
        #expect(Worktrees.made(at: made).count == 1)
        guard case .success = Worktrees.remove(linked, force: true, made: made) else { Issue.record("not removed"); return }
        #expect(!FileManager.default.fileExists(atPath: path))
        // Gone: no longer Libertty's to ask about.
        #expect(Worktrees.made(at: made).isEmpty)
        // Merged (nothing new on it): its branch went too.
        #expect(GitCLI.run(["branch", "--list", "fix-login"], in: root) == "")
    }

    @Test func anUnmergedBranchStays() throws {
        let root = try repo(), made = list()
        defer { try? FileManager.default.removeItem(atPath: root); try? FileManager.default.removeItem(at: made) }
        guard case .success(let path) = Worktrees.create(root: root, branch: "work", base: "HEAD", setting: "", made: made) else {
            Issue.record("no worktree"); return
        }
        try "x\n".write(toFile: path + "/c.txt", atomically: true, encoding: .utf8)
        _ = GitCLI.run(["add", "-A"], in: path)
        _ = GitCLI.run(["commit", "-qm", "On work"], in: path)
        guard case .success = Worktrees.remove(WorktreeInfo(root: root, path: path, branch: "work"), force: false, made: made) else {
            Issue.record("not removed"); return
        }
        #expect(GitCLI.run(["branch", "--list", "work"], in: root)?.contains("work") == true)
    }
}

/// Last Turn's start: Claude Code's prompt hook takes the snapshot itself,
/// before the agent edits anything, of the repository its session is in.
struct TurnTests {
    @Test func thePromptHookRecordsWhereTheTurnBegins() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("turn-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir + "/src", withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.com"], ["config", "user.name", "t"]] {
            _ = GitCLI.run(args, in: dir)
        }
        try "one\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        _ = GitCLI.run(["add", "-A"], in: dir)
        _ = GitCLI.run(["commit", "-qm", "First"], in: dir)
        // Changed before the prompt, and a new file: both part of where the turn begins.
        try "two\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        try "new\n".write(toFile: dir + "/src/b.txt", atomically: true, encoding: .utf8)
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("turns-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: url) }
        let env = ["LIBERTTY_SESSION": "pane1", "PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin"]
        // Not in a repository: nothing.
        AgentCLI.beginTurn(input: ["cwd": FileManager.default.temporaryDirectory.path], environment: env, at: url)
        #expect(Turns.load(from: url).isEmpty)
        AgentCLI.beginTurn(input: ["cwd": dir + "/src"], environment: env, at: url)
        let root = try #require(GitCLI.root(of: dir))
        let turn = try #require(Turns.last(root: root, from: url))
        #expect(turn.agent == "claude" && turn.session == "pane1" && WorkTree.isObjectID(turn.tree))
        // The turn's own edit is all a diff since it shows; the index is as it was.
        try "three\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        let now = try #require(WorkTree.snapshot(root: root))
        #expect(GitCLI.run(["diff", "--name-only", turn.tree, now], in: root) == "a.txt")
        #expect(GitCLI.run(["diff", "--cached", "--name-only"], in: root) == "")
    }
}

/// Revert never races an agent: one working in the repository, or in a
/// folder above it, holds it off; one next to it doesn't.
struct RevertGuardTests {
    @Test func whereAnAgentMayEdit() {
        let root = "/Users/me/src/app"
        #expect(TerminalWindowController.mayEdit(from: root, root: root))
        #expect(TerminalWindowController.mayEdit(from: root + "/Sources", root: root))
        #expect(TerminalWindowController.mayEdit(from: "/Users/me/src", root: root))
        #expect(TerminalWindowController.mayEdit(from: "/", root: root))
        #expect(!TerminalWindowController.mayEdit(from: "/Users/me/src/app2", root: root))
        #expect(!TerminalWindowController.mayEdit(from: "/Users/me/other", root: root))
    }
}

/// The Git block takes the working tree's snapshot again only when its key
/// changes: the same tree, the same key; any change, another.
struct SnapshotKeyTests {
    @Test func theKeyFollowsTheWorkingTree() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("key-\(UUID().uuidString)").path
        try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: dir) }
        for args in [["init", "-q", "-b", "main"], ["config", "user.email", "t@example.com"], ["config", "user.name", "t"]] {
            _ = GitCLI.run(args, in: dir)
        }
        try "one\n".write(toFile: dir + "/a.txt", atomically: true, encoding: .utf8)
        try "two\n".write(toFile: dir + "/b.txt", atomically: true, encoding: .utf8)
        _ = GitCLI.run(["add", "-A"], in: dir)
        _ = GitCLI.run(["commit", "-qm", "First"], in: dir)
        let root = try #require(GitCLI.root(of: dir))
        func key() throws -> String { try #require(WorkTree.stateKey(root: root)) }
        var last = try key()
        #expect(try key() == last)  // nothing changed
        func changes(_ what: String, _ change: () throws -> Void) throws {
            try change()
            let now = try key()
            #expect(now != last, "\(what) left the key as it was")
            last = now
        }
        try changes("a clean file edited") { try "one more\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8) }
        try changes("an edited file edited again") { try "and more again\n".write(toFile: root + "/a.txt", atomically: true, encoding: .utf8) }
        try changes("a new file") { try "new\n".write(toFile: root + "/c.txt", atomically: true, encoding: .utf8) }
        try changes("a file deleted") { try FileManager.default.removeItem(atPath: root + "/b.txt") }
        try changes("the index") { _ = GitCLI.run(["add", "-A"], in: root) }
        #expect(try key() == last)
    }
}
