import AppKit

/// Tabs in a git worktree of their own (Kero's sessions in their own
/// worktree): agents working side by side in one checkout trip over each
/// other's changes, so each gets a folder checking out a branch of its own.
struct WorktreeInfo: Codable, Equatable {
    /// The repository it was made from, its folder, and its branch.
    var root: String
    var path: String
    var branch: String
}

enum Worktrees {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Where a branch's worktree goes: `worktree-dir` (relative to the
    /// repository, or a path of its own), by default .libertty/worktrees
    /// inside the repository.
    static func path(root: String, branch: String, setting: String) -> String {
        let dir: String
        if setting.isEmpty {
            dir = (root as NSString).appendingPathComponent(".libertty/worktrees")
        } else if setting.hasPrefix("/") || setting.hasPrefix("~") {
            dir = (setting as NSString).expandingTildeInPath
        } else {
            dir = (root as NSString).appendingPathComponent(setting)
        }
        // A branch's slashes make folders, as they do in .git/refs.
        // (`standardized`, not `standardizedFileURL`: that one drops /private
        // from a path that exists, and not from one yet to be made.)
        return URL(fileURLWithPath: dir).appendingPathComponent(branch).standardized.path
    }

    /// A name git takes for a new branch.
    static func isValidBranch(_ name: String, in root: String) -> Bool {
        guard !name.isEmpty, !name.hasPrefix("-"), !name.contains(" ") else { return false }
        return GitCLI.run(["check-ref-format", "--branch", name], in: root) != nil
    }

    /// The line .git/info/exclude needs so git (and the Git block) ignores
    /// the worktrees inside the repository; nil when they're outside it.
    static func excludeLine(root: String, path: String) -> String? {
        let base = URL(fileURLWithPath: root).standardized.path + "/"
        guard path.hasPrefix(base) else { return nil }
        let inside = String(path.dropFirst(base.count))
        guard let top = inside.split(separator: "/").first else { return nil }
        return "/" + top + "/"
    }

    /// `git worktree add -b BRANCH PATH BASE`: base nil is the default
    /// branch (`worktree-base = default`), else what's given (HEAD for
    /// `current`). Returns the worktree's folder.
    static func create(root: String, branch: String, base: String?, setting: String,
                       made url: URL = madeURL) -> Result<String, Failure> {
        guard GitCLI.executable != nil else { return .failure(Failure(message: GitCLI.missing)) }
        guard isValidBranch(branch, in: root) else { return .failure(Failure(message: "“\(branch)” isn't a name git takes for a branch")) }
        let path = path(root: root, branch: branch, setting: setting)
        if FileManager.default.fileExists(atPath: path) { return .failure(Failure(message: "\(path) is there already")) }
        if let line = excludeLine(root: root, path: path) { exclude(line, root: root) }
        let start = base ?? WorkTree.defaultBranch(root: root) ?? "HEAD"
        switch GitCLI.execute(["worktree", "add", "-b", branch, path, start], in: root) {
        case .success:
            remember(WorktreeInfo(root: root, path: path, branch: branch), at: url)
            return .success(path)
        case .failure(let why): return .failure(Failure(message: why.message))
        }
    }

    // MARK: The ones Libertty made

    /// The worktrees Libertty made (New Tab in Worktree…, `+new-session
    /// --worktree`) and still looks after: closing the last tab in one asks
    /// whether it goes too. Kept, it's yours: it leaves the list.
    static var madeURL: URL { Blocks.dataDirectory.appendingPathComponent("worktrees.json") }

    static func made(at url: URL = madeURL) -> [WorktreeInfo] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return (try? JSONDecoder().decode([WorktreeInfo].self, from: data)) ?? []
    }

    static func remember(_ w: WorktreeInfo, at url: URL = madeURL) {
        changeMade(at: url) { list in
            list.removeAll { $0.path == w.path }
            list.append(w)
        }
    }

    static func forget(_ w: WorktreeInfo, at url: URL = madeURL) {
        changeMade(at: url) { list in list.removeAll { $0.path == w.path } }
    }

    private static func changeMade(at url: URL, _ change: (inout [WorktreeInfo]) -> Void) {
        FileLock.withLock(url) {
            var list = made(at: url)
            change(&list)
            try? JSONEncoder().encode(list).write(to: url, options: .atomic)
        }
    }

    /// The one of `list` that `directory` is in.
    static func made(containing directory: String, among list: [WorktreeInfo]) -> WorktreeInfo? {
        list.first { contains($0, directory) }
    }

    /// Adds `line` to the repository's info/exclude (not its .gitignore) once.
    static func exclude(_ line: String, root: String) {
        guard let file = GitCLI.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: root)
            .map({ ($0 as NSString).appendingPathComponent("info/exclude") }) else { return }
        let text = (try? String(contentsOfFile: file, encoding: .utf8)) ?? ""
        guard !text.split(separator: "\n").contains(where: { $0.trimmingCharacters(in: .whitespaces) == line }) else { return }
        try? FileManager.default.createDirectory(atPath: (file as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        let joined = (text.isEmpty || text.hasSuffix("\n") ? text : text + "\n")
            + "# Libertty's worktrees (New Tab in Worktree…)\n" + line + "\n"
        try? joined.write(toFile: file, atomically: true, encoding: .utf8)
    }

    /// How many files in it have changes not committed (new ones too).
    static func uncommitted(_ path: String) -> Int {
        guard case .success(let out) = GitCLI.execute(["status", "--porcelain", "--untracked-files=all"], in: path) else { return 0 }
        return out.split(separator: "\n").count
    }

    /// Removes it (`force`: with uncommitted changes), and its branch once
    /// it's merged — else the branch stays, with its commits.
    static func remove(_ w: WorktreeInfo, force: Bool, made url: URL = madeURL) -> Result<Void, Failure> {
        let args = ["worktree", "remove"] + (force ? ["--force"] : []) + [w.path]
        if case .failure(let why) = GitCLI.execute(args, in: w.root) { return .failure(Failure(message: why.message)) }
        _ = GitCLI.execute(["branch", "-d", w.branch], in: w.root)
        forget(w, at: url)
        return .success(())
    }

    /// The linked worktree `directory` is in (not a repository's main
    /// checkout): its repository, folder and branch.
    static func linked(at directory: String) -> WorktreeInfo? {
        guard let top = GitCLI.run(["rev-parse", "--show-toplevel"], in: directory),
              let gitDir = GitCLI.run(["rev-parse", "--path-format=absolute", "--git-dir"], in: directory),
              let common = GitCLI.run(["rev-parse", "--path-format=absolute", "--git-common-dir"], in: directory),
              gitDir != common, (common as NSString).lastPathComponent == ".git" else { return nil }
        let root = (common as NSString).deletingLastPathComponent
        let branch = GitCLI.run(["branch", "--show-current"], in: directory) ?? ""
        return WorktreeInfo(root: root, path: top, branch: branch)
    }

    /// Whether `directory` is the worktree or a folder in it.
    static func contains(_ w: WorktreeInfo, _ directory: String) -> Bool {
        // Both as the file system has them (/tmp is /private/tmp).
        func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().path }
        let dir = resolved(directory), top = resolved(w.path)
        return dir == top || dir.hasPrefix(top + "/")
    }
}
