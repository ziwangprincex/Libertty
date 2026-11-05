import Foundation

/// A repository's state as a pane shows it (Kero's branches at a glance):
/// its branch, the lines its changes add and remove since the last commit,
/// how many files changed, and a merge or rebase under way.
struct RepoStatus: Equatable {
    var root: String
    var branch: String
    var added = 0, removed = 0, files = 0
    var ahead = 0, behind = 0
    /// "merging", "rebasing", "cherry-picking", or "".
    var operation = ""

    /// "fix-login +40 −2", "main +3", "main", "main (rebasing)".
    var summary: String {
        var s = branch
        if added > 0 { s += " +\(added)" }
        if removed > 0 { s += " −\(removed)" }
        if !operation.isEmpty { s += " (\(operation))" }
        return s
    }

    /// The `git status --porcelain=v2 --branch` and `git diff --numstat
    /// HEAD` it's read from, apart from running them (tests).
    static func parse(root: String, status: String, numstat: String, operation: String = "") -> RepoStatus {
        var r = RepoStatus(root: root, branch: "", operation: operation)
        var oid = ""
        for line in status.split(separator: "\n") {
            if line.hasPrefix("# branch.head ") { r.branch = String(line.dropFirst(14)) }
            else if line.hasPrefix("# branch.oid ") { oid = String(line.dropFirst(13)) }
            else if line.hasPrefix("# branch.ab ") {
                let parts = line.dropFirst(12).split(separator: " ")
                r.ahead = Int(parts.first?.dropFirst() ?? "") ?? 0
                r.behind = Int(parts.last?.dropFirst() ?? "") ?? 0
            } else if !line.hasPrefix("#") {
                r.files += 1
            }
        }
        if r.branch == "(detached)" { r.branch = oid == "(initial)" ? "(no commits)" : String(oid.prefix(7)) }
        for line in numstat.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 2)
            guard parts.count == 3 else { continue }
            // A binary file says "-": changed, no lines to count.
            r.added += Int(parts[0]) ?? 0
            r.removed += Int(parts[1]) ?? 0
        }
        return r
    }

    /// Reads it with git, off the main thread; nil outside a repository.
    static func read(directory: String) -> RepoStatus? {
        GitCLI.root(of: directory).flatMap(read(root:))
    }

    /// The same for a repository's root.
    static func read(root: String) -> RepoStatus? {
        guard case .success(let status) = GitCLI.execute(["status", "--porcelain=v2", "--branch", "--untracked-files=normal"], in: root)
        else { return nil }
        let numstat: String
        if case .success(let out) = GitCLI.execute(["diff", "--numstat", "HEAD"], in: root) { numstat = out } else { numstat = "" }
        var operation = ""
        if let gitDir = GitCLI.run(["rev-parse", "--path-format=absolute", "--git-dir"], in: root) {
            let fm = FileManager.default
            func has(_ name: String) -> Bool { fm.fileExists(atPath: (gitDir as NSString).appendingPathComponent(name)) }
            operation = has("rebase-merge") || has("rebase-apply") ? "rebasing"
                : has("MERGE_HEAD") ? "merging" : has("CHERRY_PICK_HEAD") ? "cherry-picking" : ""
        }
        return parse(root: root, status: status, numstat: numstat, operation: operation)
    }
}

/// Each repository's state as panes show it, read off the main thread
/// (`git-status`): once for all the panes in one repository, again when it's
/// older than the caller allows — a few seconds for the tab in front, half a
/// minute for the others — or at once after a command in a pane (`force`).
final class RepoStatusCache {
    static let shared = RepoStatusCache()
    /// How old an answer may be before a look asks git again: for a pane in
    /// the tab in front, and for the others.
    static let freshFor: TimeInterval = 4
    static let freshBehind: TimeInterval = 30
    /// How long a folder's repository is taken as known: a folder hardly
    /// ever changes repository (and a new folder is a new key).
    static let rootFreshFor: TimeInterval = 60

    /// Each folder's repository (nil: not in one), when it was looked up.
    private var roots: [String: (root: String?, at: Date)] = [:]
    private var byRoot: [String: (status: RepoStatus?, at: Date)] = [:]
    /// Repositories (or folders not yet placed) being read now.
    private var reading: Set<String> = []
    private let queue = DispatchQueue(label: "libertty.git-status", qos: .utility)

    /// What's known now (on the main thread); asks git again when it's
    /// older than `maxAge` (or `force`), and calls `changed` on the main
    /// queue when the answer differs.
    func status(of directory: String, force: Bool = false, maxAge: TimeInterval = freshFor,
                changed: @escaping () -> Void) -> RepoStatus? {
        let now = Date()
        // (A command in a pane may have made a repository of its folder: `force` looks again.)
        let placed = roots[directory].flatMap {
            now.timeIntervalSince($0.at) < Self.rootFreshFor && !(force && $0.root == nil) ? $0 : nil
        }
        let known = placed?.root.flatMap { byRoot[$0] }
        let stale: Bool
        if let placed {
            // Not in a repository, as recently looked up: nothing to read.
            stale = placed.root != nil && (force || known.map { now.timeIntervalSince($0.at) > maxAge } ?? true)
        } else {
            stale = true
        }
        let readingKey = placed?.root ?? "folder:" + directory
        if stale, !reading.contains(readingKey) {
            reading.insert(readingKey)
            let knownRoot = placed?.root
            queue.async { [weak self] in
                let root = knownRoot ?? GitCLI.root(of: directory)
                let status = root.flatMap(RepoStatus.read(root:))
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.reading.remove(readingKey)
                    let before = known?.status
                    if knownRoot == nil { self.roots[directory] = (root, Date()) }
                    if let root { self.byRoot[root] = (status, Date()) }
                    if status != before || placed == nil { changed() }
                }
            }
        }
        return known?.status
    }
}
