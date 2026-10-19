import AppKit

/// The Git block (Tern's Git client; through the git command line, as the
/// Inspector's panel): the changes with stage / unstage / discard, by file or
/// by hunk; a commit box (amend too); the history with its graph and each
/// commit's diff; branches to switch, make and delete; fetch, pull, push;
/// stashes. Everything runs at the repository's root, off the main thread.
final class GitBlock: BlockService {
    static let symbol = "arrow.triangle.branch"
    weak var host: BlockHost?
    /// The folder it was opened for (anywhere in the repository).
    let directory: String
    /// The repository's top, once there is one (`init` makes one). Calls run
    /// on several threads at once.
    private var root: String? {
        get { rootLock.lock(); defer { rootLock.unlock() }; return _root }
        set { rootLock.lock(); _root = newValue; rootLock.unlock() }
    }
    private var _root: String?
    private let rootLock = NSLock()

    init?(url: URL) {
        guard let dir = Blocks.parameter("root", of: url), !dir.isEmpty else { return nil }
        directory = dir
        _root = GitCLI.root(of: dir)
    }

    var title: String {
        "Git — " + ((root ?? directory) as NSString).lastPathComponent
    }

    /// What the page's diffs are cut to: a vendored dump would take it down.
    static let diffLimit = 2_000_000

    func promptArrived() { host?.send("changed", [:]) }

    // MARK: Calls

    func handle(_ method: String, _ params: [String: Any], reply: @escaping (Result<Any, BlockError>) -> Void) {
        let paths = (params["paths"] as? [String] ?? []).filter { !$0.isEmpty }
        // A call about files names some: `git clean --` with none would clean everything.
        if ["diff", "stage", "unstage", "discard", "resolve", "openFile"].contains(method), paths.isEmpty {
            return reply(.failure(BlockError("which file?")))
        }
        switch method {
        case "status": blockWork(reply) { try self.status() }
        case "log":
            let skip = max(0, params["skip"] as? Int ?? 0), limit = min(5000, max(1, params["limit"] as? Int ?? 200))
            let all = params["all"] as? Bool ?? false
            blockWork(reply) { try self.log(skip: skip, limit: limit, all: all) }
        case "show":
            guard let hash = params["hash"] as? String, Self.isRevision(hash) else { return reply(.failure(BlockError("no such commit"))) }
            blockWork(reply) { try self.show(hash) }
        case "diff":
            // A rename names both its paths, so it reads as one.
            let staged = params["staged"] as? Bool ?? false, untracked = params["untracked"] as? Bool ?? false
            blockWork(reply) { try self.diff(paths, staged: staged, untracked: untracked) }
        case "stage": blockWork(reply) { try self.git(["add", "--"] + paths); return true }
        case "stageAll": blockWork(reply) { try self.git(["add", "-A"]); return true }
        case "unstage": blockWork(reply) { try self.unstage(paths); return true }
        case "unstageAll": blockWork(reply) { try self.unstage([]); return true }
        case "discard":
            let untracked = params["untracked"] as? Bool ?? false
            blockWork(reply) {
                // An edit goes back to the index; something new is deleted.
                try self.git(untracked ? ["clean", "-f", "-d", "--"] + paths : ["checkout", "--"] + paths)
                return true
            }
        case "resolve":
            // A conflict settled with one side's version of the file, and marked so.
            guard let side = params["side"] as? String, side == "ours" || side == "theirs" else {
                return reply(.failure(BlockError("ours or theirs?")))
            }
            blockWork(reply) {
                try self.git(["checkout", "--" + side, "--"] + paths)
                try self.git(["add", "--"] + paths)
                return true
            }
        case "applyPatch":
            // A hunk the page cut from a diff this side gave it: staged
            // (`cached`), unstaged (`cached` + `reverse`) or discarded (`reverse`).
            guard let patch = params["patch"] as? String, patch.hasPrefix("diff --git ") else {
                return reply(.failure(BlockError("not a patch")))
            }
            var args = ["apply", "--recount", "--whitespace=nowarn"]
            if params["cached"] as? Bool == true { args.append("--cached") }
            if params["reverse"] as? Bool == true { args.append("-R") }
            args.append("-")
            blockWork(reply) { try self.git(args, input: Data(patch.utf8)); return true }
        case "commit":
            let message = (params["message"] as? String ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
            let amend = params["amend"] as? Bool ?? false
            guard !message.isEmpty || amend else { return reply(.failure(BlockError("A commit needs a message."))) }
            blockWork(reply) {
                var args = ["commit", "-F", "-"]
                if amend { args.append("--amend") }
                if amend && message.isEmpty { args = ["commit", "--amend", "--no-edit"] }
                try self.git(args, input: Data(message.utf8))
                return true
            }
        case "lastMessage": blockWork(reply) { (try? self.git(["log", "-1", "--format=%B"])) ?? "" }
        case "branches": blockWork(reply) { try self.branches() }
        case "checkout":
            guard let name = params["name"] as? String, Self.isRefName(name) else { return reply(.failure(BlockError("not a branch name"))) }
            let remote = params["remote"] as? Bool ?? false
            blockWork(reply) { try self.git(remote ? ["switch", "--track", name] : ["switch", name]); self.titleMayChange(); return true }
        case "createBranch":
            guard let name = params["name"] as? String, Self.isRefName(name) else { return reply(.failure(BlockError("not a branch name"))) }
            let start = params["from"] as? String
            if let start, !Self.isRevision(start) { return reply(.failure(BlockError("no such commit"))) }
            blockWork(reply) { try self.git(["switch", "-c", name] + (start.map { [$0] } ?? [])); return true }
        case "deleteBranch":
            guard let name = params["name"] as? String, Self.isRefName(name) else { return reply(.failure(BlockError("not a branch name"))) }
            let force = params["force"] as? Bool ?? false
            blockWork(reply) { try self.git(["branch", force ? "-D" : "-d", name]); return true }
        case "fetch": blockWork(reply) { try self.git(["fetch", "--all", "--prune"], network: true); return true }
        case "pull": blockWork(reply) { try self.git(["pull", "--ff-only"], network: true); return true }
        case "push": blockWork(reply) { try self.push(); return true }
        case "stashes": blockWork(reply) { try self.stashes() }
        case "stash":
            let message = params["message"] as? String ?? ""
            blockWork(reply) {
                try self.git(["stash", "push", "--include-untracked"] + (message.isEmpty ? [] : ["-m", message]))
                return true
            }
        case "stashPop", "stashApply", "stashDrop", "stashShow":
            guard let ref = params["ref"] as? String, ref.range(of: #"^stash@\{\d+\}$"#, options: .regularExpression) != nil else {
                return reply(.failure(BlockError("no such stash")))
            }
            let verb = ["stashPop": "pop", "stashApply": "apply", "stashDrop": "drop", "stashShow": "show"][method]!
            blockWork(reply) {
                if verb == "show" { return Self.capped(try self.git(["stash", "show", "-p", "--no-color", "--include-untracked", ref])) }
                try self.git(["stash", verb, ref])
                return true
            }
        case "init":
            blockWork(reply) {
                _ = try GitCLI.execute(["init"], in: self.directory).get()
                self.root = GitCLI.root(of: self.directory)
                self.titleMayChange()
                return true
            }
        case "openFile":
            guard let root, let url = Self.inside(root, paths[0]) else { return reply(.failure(BlockError("no such file"))) }
            guard FileManager.default.fileExists(atPath: url.path) else { return reply(.failure(BlockError("It isn't there anymore."))) }
            let line = params["line"] as? Int
            if !DocumentView.canShow(url) && !EditorAssets.canEdit(url) {
                // Something Libertty doesn't show (a binary, an app): its own app opens it.
                DispatchQueue.main.async { NSWorkspace.shared.open(url) }
            } else {
                DispatchQueue.main.async { self.host?.openFile(url, line: line) }
            }
            reply(.success(true))
        default:
            reply(.failure(BlockError("unknown call \(method)")))
        }
    }

    func titleMayChange() { DispatchQueue.main.async { self.host?.titleChanged() } }

    // MARK: Git

    private func repository() throws -> String {
        if let root { return root }
        if let found = GitCLI.root(of: directory) { root = found; return found }
        throw BlockError("not a git repository")
    }

    @discardableResult
    private func git(_ args: [String], input: Data? = nil, network: Bool = false) throws -> String {
        switch GitCLI.execute(args, in: try repository(), input: input, network: network) {
        case .success(let out): return out
        case .failure(let why): throw BlockError(why.message)
        }
    }

    private var hasHead: Bool { (try? git(["rev-parse", "--verify", "-q", "HEAD"])) != nil }

    private func unstage(_ paths: [String]) throws {
        // Before the first commit there's no HEAD to restore from.
        if hasHead {
            try git(["restore", "--staged", "--"] + (paths.isEmpty ? ["."] : paths))
        } else {
            try git(["rm", "--cached", "-r", "-q", "--"] + (paths.isEmpty ? ["."] : paths))
        }
    }

    private func push() throws {
        let upstream = try? git(["rev-parse", "--abbrev-ref", "--symbolic-full-name", "@{u}"])
        if upstream?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false {
            try git(["push"], network: true)
            return
        }
        // A branch's first push sets where it goes.
        let remotes = (try? git(["remote"]))?.split(separator: "\n").map(String.init) ?? []
        guard let remote = remotes.contains("origin") ? "origin" : remotes.first else { throw BlockError("This repository has no remote to push to.") }
        try git(["push", "-u", remote, "HEAD"], network: true)
    }

    /// `status --porcelain=v2 --branch -z`: the branch, its upstream and how far
    /// apart they are, and every change with both its marks.
    private func status() throws -> [String: Any] {
        guard let root = try? repository() else { return ["repository": false, "directory": directory] }
        let raw = try git(["status", "--porcelain=v2", "--branch", "-z", "--untracked-files=all"])
        var branch = "", upstream = "", ahead = 0, behind = 0, oid = ""
        var staged: [[String: Any]] = [], unstaged: [[String: Any]] = [], conflicted: [[String: Any]] = []
        let fields = raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        var i = 0
        while i < fields.count {
            let f = fields[i]
            i += 1
            if f.hasPrefix("# branch.oid ") { oid = String(f.dropFirst(13)) }
            else if f.hasPrefix("# branch.head ") { branch = String(f.dropFirst(14)) }
            else if f.hasPrefix("# branch.upstream ") { upstream = String(f.dropFirst(18)) }
            else if f.hasPrefix("# branch.ab ") {
                let parts = f.dropFirst(12).split(separator: " ")
                ahead = Int(parts.first?.dropFirst() ?? "") ?? 0
                behind = Int(parts.last?.dropFirst() ?? "") ?? 0
            } else if f.hasPrefix("1 ") || f.hasPrefix("2 ") {
                // "1 XY sub mH mI mW hH hI path"; "2 …  Xscore path" then the old path.
                let parts = f.split(separator: " ", maxSplits: f.hasPrefix("1 ") ? 8 : 9, omittingEmptySubsequences: false)
                guard let xy = parts.dropFirst().first, xy.count == 2, let path = parts.last else { continue }
                var old: String?
                if f.hasPrefix("2 "), i < fields.count { old = fields[i]; i += 1 }
                let x = String(xy.first!), y = String(xy.last!)
                if x != "." { staged.append(["path": String(path), "mark": x, "old": old as Any? ?? NSNull()]) }
                if y != "." { unstaged.append(["path": String(path), "mark": y]) }
            } else if f.hasPrefix("u ") {
                if let path = f.split(separator: " ", maxSplits: 10, omittingEmptySubsequences: false).last {
                    conflicted.append(["path": String(path), "mark": "U"])
                }
            } else if f.hasPrefix("? ") {
                unstaged.append(["path": String(f.dropFirst(2)), "mark": "?", "untracked": true])
            }
        }
        let state: String
        let dir = (try? git(["rev-parse", "--git-dir"]))?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ".git"
        let gitDir = dir.hasPrefix("/") ? dir : (root as NSString).appendingPathComponent(dir)
        let fm = FileManager.default
        if fm.fileExists(atPath: gitDir + "/MERGE_HEAD") { state = "merging" }
        else if fm.fileExists(atPath: gitDir + "/rebase-merge") || fm.fileExists(atPath: gitDir + "/rebase-apply") { state = "rebasing" }
        else if fm.fileExists(atPath: gitDir + "/CHERRY_PICK_HEAD") { state = "cherry-picking" }
        else { state = "" }
        return [
            "repository": true, "root": root, "name": (root as NSString).lastPathComponent,
            "branch": branch == "(detached)" ? "" : branch, "detached": branch == "(detached)",
            "head": String(oid.prefix(8)), "upstream": upstream, "ahead": ahead, "behind": behind,
            "staged": staged, "unstaged": unstaged, "conflicted": conflicted, "state": state,
            "hasHead": oid != "(initial)",
        ]
    }

    /// Fields git writes apart with NUL: the one byte no name or message holds.
    private static func fields(_ raw: String) -> [String] {
        raw.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
    }

    private func log(skip: Int, limit: Int, all: Bool) throws -> [[String: Any]] {
        guard hasHead else { return [] }
        // Seven fields a commit, each ended by NUL (`-z` ends the commit's last).
        var args = ["log", "--topo-order", "--no-color", "-z", "--skip=\(skip)", "-n", "\(limit)",
                    "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%s%x00%D"]
        if all { args.append("--all") }
        let f = Self.fields(try git(args))
        var commits: [[String: Any]] = []
        var i = 0
        while i + 6 < f.count {
            let hash = f[i].trimmingCharacters(in: .whitespacesAndNewlines)
            if !hash.isEmpty {
                let refs = f[i + 6].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                commits.append(["hash": hash, "parents": f[i + 1].split(separator: " ").map(String.init), "author": f[i + 2],
                                "email": f[i + 3], "time": Int(f[i + 4]) ?? 0, "subject": f[i + 5], "refs": refs])
            }
            i += 7
        }
        return commits
    }

    /// `text` cut to `diffLimit` at the end of a line (never inside a
    /// character), and whether it was.
    static func capped(_ text: String) -> [String: Any] {
        let bytes = text.utf8
        guard bytes.count > diffLimit else { return ["diff": text, "truncated": false] }
        let head = Data(bytes.prefix(diffLimit))
        let end = head.lastIndex(of: UInt8(ascii: "\n")).map { $0 + 1 } ?? 0
        return ["diff": String(decoding: head.prefix(end), as: UTF8.self), "truncated": true]
    }

    /// A commit: who, when, its whole message, its files and its diff (cut
    /// at `diffLimit`).
    private func show(_ hash: String) throws -> [String: Any] {
        let head = try git(["show", "-s", "--no-color", "--format=%H%x00%P%x00%an%x00%ae%x00%at%x00%cn%x00%B", hash])
        let f = head.split(separator: "\0", maxSplits: 6, omittingEmptySubsequences: false).map(String.init)
        guard f.count >= 7 else { throw BlockError("no such commit") }
        let files = try git(["show", "--no-color", "--format=", "--name-status", "-M", "-z", hash])
            .split(separator: "\0").map(String.init)
        var list: [[String: String]] = []
        var i = 0
        while i < files.count {
            let status = files[i]
            i += 1
            guard i < files.count else { break }
            if status.hasPrefix("R") || status.hasPrefix("C"), i + 1 < files.count {
                list.append(["status": String(status.prefix(1)), "old": files[i], "path": files[i + 1]])
                i += 2
            } else {
                list.append(["status": String(status.prefix(1)), "path": files[i]])
                i += 1
            }
        }
        var result = Self.capped(try git(["show", "--no-color", "--format=", "-M", "--no-ext-diff", hash]))
        result.merge(["hash": f[0], "parents": f[1].split(separator: " ").map(String.init), "author": f[2], "email": f[3],
                      "time": Int(f[4]) ?? 0, "committer": f[5], "message": f[6].trimmingCharacters(in: .whitespacesAndNewlines),
                      "files": list]) { _, new in new }
        return result
    }

    private func diff(_ paths: [String], staged: Bool, untracked: Bool) throws -> [String: Any] {
        if untracked {
            // A new file against nothing: git says "they differ" with exit 1.
            let root = try repository()
            // The path as checked (`a/../b` comes out `b`), not as sent.
            guard let url = Self.inside(root, paths[0]) else { throw BlockError("no such file") }
            let base = URL(fileURLWithPath: root).standardizedFileURL.path
            let relative = String(url.path.dropFirst(base.count + 1))
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["--no-optional-locks", "-c", "core.quotePath=false", "-C", root,
                           "diff", "--no-color", "--no-ext-diff", "--no-index", "--", "/dev/null", relative]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return Self.capped(String(decoding: data, as: UTF8.self))
        }
        return Self.capped(try git(["diff", "--no-color", "--no-ext-diff", "-M"] + (staged ? ["--cached"] : []) + ["--"] + paths))
    }

    private func branches() throws -> [String: Any] {
        let format = "%(refname)%00%(refname:short)%00%(HEAD)%00%(upstream:short)%00%(upstream:track)%00%(subject)%00%(committerdate:unix)"
        let raw = try git(["for-each-ref", "--format=" + format, "--sort=-committerdate", "refs/heads", "refs/remotes"])
        var local: [[String: Any]] = [], remote: [[String: Any]] = []
        for line in raw.split(separator: "\n") {
            let f = Self.fields(String(line))
            guard f.count >= 7 else { continue }
            if f[0].hasSuffix("/HEAD") { continue }  // origin/HEAD points at a branch listed anyway
            let entry: [String: Any] = ["name": f[1], "current": f[2] == "*", "upstream": f[3], "track": f[4],
                                        "subject": f[5], "time": Int(f[6]) ?? 0]
            if f[0].hasPrefix("refs/heads/") { local.append(entry) } else { remote.append(entry) }
        }
        return ["local": local, "remote": remote]
    }

    private func stashes() throws -> [[String: Any]] {
        let f = Self.fields((try? git(["stash", "list", "-z", "--format=%gd%x00%s%x00%ct"])) ?? "")
        var list: [[String: Any]] = []
        var i = 0
        while i + 2 < f.count {
            if !f[i].isEmpty { list.append(["ref": f[i], "message": f[i + 1], "time": Int(f[i + 2]) ?? 0]) }
            i += 3
        }
        return list
    }

    // MARK: Checks on what the page sends

    /// A commit or ref the page names: something git reads as a revision,
    /// never an option.
    static func isRevision(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && s.count < 256 && !s.contains("..") && s.range(of: #"^[\w./@{}^~-]+$"#, options: .regularExpression) != nil
    }

    /// A branch name git would take (and never an option).
    static func isRefName(_ s: String) -> Bool {
        !s.isEmpty && !s.hasPrefix("-") && !s.hasPrefix("/") && !s.hasSuffix("/") && !s.hasSuffix(".lock") && !s.contains("..")
            && s.count < 256 && s.range(of: #"^[^\s~^:?*\[\\]+$"#, options: .regularExpression) != nil
    }

    /// `path` (from the repository's root), if it stays inside it — after
    /// symbolic links too (a committed link to ~/.ssh is outside).
    static func inside(_ root: String, _ path: String) -> URL? {
        let base = URL(fileURLWithPath: root).standardizedFileURL
        let url = base.appendingPathComponent(path).standardizedFileURL
        guard url.path.hasPrefix(base.path + "/") else { return nil }
        let realBase = base.resolvingSymlinksInPath().path
        return url.resolvingSymlinksInPath().path.hasPrefix(realBase + "/") ? url : nil
    }
}
