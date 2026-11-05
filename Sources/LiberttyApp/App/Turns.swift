import Foundation

/// The working tree as git sees it, written as trees nothing refers to
/// (Kero's turn snapshots): what an agent's turn started from, and what's
/// there now, so that a diff shows what the turn changed and nothing from
/// before — without touching the repository's index or its files.
enum WorkTree {
    /// A tree of the working tree as it is: its tracked files and the
    /// untracked ones git doesn't ignore. Through an index of its own,
    /// seeded with a copy of the repository's so that git hashes only what
    /// changed. The tree and its blobs are loose objects git's gc prunes
    /// once they're old.
    static func snapshot(root: String) -> String? {
        guard let indexPath = GitCLI.run(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: root) else { return nil }
        let fm = FileManager.default
        let dir = fm.temporaryDirectory.appendingPathComponent("libertty-index-\(UUID().uuidString)")
        guard (try? fm.createDirectory(at: dir, withIntermediateDirectories: true)) != nil else { return nil }
        defer { try? fm.removeItem(at: dir) }
        let index = dir.appendingPathComponent("index")
        if fm.fileExists(atPath: indexPath) { try? fm.copyItem(atPath: indexPath, toPath: index.path) }
        let env = ["GIT_INDEX_FILE": index.path]
        guard case .success = GitCLI.execute(["add", "--all", "--", "."], in: root, environment: env),
              case .success(let tree) = GitCLI.execute(["write-tree"], in: root, environment: env) else { return nil }
        let id = tree.trimmingCharacters(in: .whitespacesAndNewlines)
        return isObjectID(id) ? id : nil
    }

    /// What the working tree's snapshot depends on, read without hashing
    /// or writing anything: the files git lists as changed, new or deleted,
    /// each by its size and time, and the index (a branch switch rewrites
    /// it). The same key, the same snapshot: taking one hashes every new
    /// file, which needn't happen at every look.
    static func stateKey(root: String) -> String? {
        guard case .success(let listed) = GitCLI.execute(["ls-files", "-z", "-m", "-o", "-d", "--exclude-standard"], in: root),
              let index = GitCLI.run(["rev-parse", "--path-format=absolute", "--git-path", "index"], in: root) else { return nil }
        func stamp(_ path: String) -> String {
            guard let a = try? FileManager.default.attributesOfItem(atPath: path) else { return "-" }
            return "\((a[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0):\(a[.size] as? Int ?? 0)"
        }
        var key = root + "\0index:" + stamp(index)
        for path in listed.split(separator: "\0") {
            key += "\0" + path + ":" + stamp((root as NSString).appendingPathComponent(String(path)))
        }
        return key
    }

    /// The repository's default branch, as a pull request would be made
    /// against it: its remote's, else a local main or master.
    static func defaultBranch(root: String) -> String? {
        if let head = GitCLI.run(["symbolic-ref", "--quiet", "--short", "refs/remotes/origin/HEAD"], in: root), !head.isEmpty {
            return head
        }
        for name in ["origin/main", "origin/master", "main", "master"]
        where GitCLI.run(["rev-parse", "--verify", "--quiet", name + "^{commit}"], in: root) != nil {
            return name
        }
        return nil
    }

    /// Where HEAD left the default branch: a pull request's base.
    static func branchBase(root: String) -> (commit: String, branch: String)? {
        guard let branch = defaultBranch(root: root),
              let base = GitCLI.run(["merge-base", "HEAD", branch], in: root), isObjectID(base) else { return nil }
        return (base, branch)
    }

    static func isObjectID(_ s: String) -> Bool {
        (s.count == 40 || s.count == 64) && s.allSatisfy(\.isHexDigit)
    }
}

/// The last turn of an agent in each repository: the tree it started from.
struct Turn: Codable, Equatable {
    var tree: String
    var time: Double
    /// The agent's name ("claude", "codex"…), and the pane's session.
    var agent: String
    var session: String
}

enum Turns {
    static var url: URL { Blocks.dataDirectory.appendingPathComponent("turns.json") }

    /// By repository root.
    static func load(from url: URL = url) -> [String: Turn] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Turn].self, from: data)) ?? [:]
    }

    static func last(root: String, from url: URL = url) -> Turn? { load(from: url)[root] }

    /// Under a file lock: Claude Code's hook (another process) and the app both write it.
    static func record(_ turn: Turn, root: String, at url: URL = url) {
        FileLock.withLock(url) {
            var all = load(from: url)
            all[root] = turn
            // The 100 latest repositories.
            if all.count > 100, let oldest = all.min(by: { $0.value.time < $1.value.time })?.key { all[oldest] = nil }
            try? JSONEncoder().encode(all).write(to: url, options: .atomic)
        }
    }

    /// An agent starts a turn in `directory`: its repository's tree as it is
    /// now, recorded as where the turn began. Returns the repository's root.
    @discardableResult
    static func take(directory: String, agent: String, session: String, at url: URL = url) -> String? {
        guard let root = GitCLI.root(of: directory), let tree = WorkTree.snapshot(root: root) else { return nil }
        record(Turn(tree: tree, time: Date().timeIntervalSince1970, agent: agent, session: session), root: root, at: url)
        return root
    }

    /// The same, off the main thread (the app, for agents it hears of as
    /// they start: their screens, Codex's Return). `done` gets the root, on the main queue.
    static func begin(directory: String, agent: String, session: String, done: ((String) -> Void)? = nil) {
        DispatchQueue.global(qos: .userInitiated).async {
            guard let root = take(directory: directory, agent: agent, session: session) else { return }
            if let done { DispatchQueue.main.async { done(root) } }
        }
    }
}
