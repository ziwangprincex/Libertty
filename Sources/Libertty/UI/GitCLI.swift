import Foundation

/// One file in `git status`: its index (staged) and worktree marks, and
/// its path from the repository's root — which is how git reports it,
/// wherever the command ran.
struct GitChange: Equatable {
    var path: String
    var index: Character
    var worktree: Character
    /// '?' is untracked, 'U' a conflict.
    var isUntracked: Bool { worktree == "?" }
    /// An untracked folder comes as one entry, its path ending in "/".
    var isDirectory: Bool { path.hasSuffix("/") }
}

/// `git` through its command line (no libgit2): the Inspector's Git panel,
/// Show Changes, and the sidebar tree's Git marks all share it.
enum GitCLI {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// Runs `git -C directory args` and trims its output (a branch name, a
    /// log); nil when it fails (not a repository, ...).
    static func run(_ args: [String], in directory: String) -> String? {
        guard case .success(let out) = execute(args, in: directory) else { return nil }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Runs git: its output byte for byte, or what it said when it failed.
    /// (`status --porcelain` starts its first entry with the index's mark,
    /// a space for a file changed only in the worktree: never trim it.)
    ///
    /// `--no-optional-locks`: the panel and the file tree read the status
    /// at every prompt, and plain `git status` refreshes the index on the
    /// way — taking .git/index.lock just when the user's own `git commit`
    /// or rebase in the pane may want it.
    ///
    /// `input` goes to git's stdin (a patch for `apply`). `network`: it may
    /// talk to a remote (fetch, pull, push) — never at a prompt nobody can
    /// answer (a password, an unknown host key): it fails and says why.
    ///
    /// Paths named after `--` are paths, never patterns (`--literal-pathspecs`:
    /// a file named `*` discards itself, not every file). Only then: git's own
    /// steps inherit the mode, and `stash push -u` cleans with the pattern
    /// `:/`, which it reads as a file name and so leaves new files behind.
    /// Paths come back unquoted (`core.quotePath`). Hooks and helpers find
    /// what the login shell would (Homebrew's gpg, husky's node, git-lfs).
    static func execute(_ args: [String], in directory: String, input: Data? = nil,
                        network: Bool = false) -> Result<String, Failure> {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        p.arguments = ["--no-optional-locks"] + (args.contains("--") ? ["--literal-pathspecs"] : [])
            + ["-c", "core.quotePath=false", "-C", directory] + args
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = LoginShell.path
        // No terminal to ask at: a prompt fails instead of waiting forever
        // (ssh has no tty here either; its own settings stay the user's).
        if network { env["GIT_TERMINAL_PROMPT"] = "0" }
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        let stdin = input.map { _ in Pipe() }
        if let stdin { p.standardInput = stdin } else { p.standardInput = FileHandle.nullDevice }
        do { try p.run() } catch { return .failure(Failure(message: error.localizedDescription)) }
        if let stdin, let input {
            // Off this thread: a patch bigger than the pipe would block until
            // git reads it. A git that quits early (a hook said no) mustn't
            // take Libertty down with SIGPIPE.
            let writer = stdin.fileHandleForWriting
            _ = fcntl(writer.fileDescriptor, F_SETNOSIGPIPE, 1)
            DispatchQueue.global(qos: .userInitiated).async {
                try? writer.write(contentsOf: input)
                try? writer.close()
            }
        }
        // A remote that never answers (or a credential window nobody sees)
        // ends after two minutes rather than holding the block.
        var timedOut = false
        if network {
            DispatchQueue.global().asyncAfter(deadline: .now() + 120) {
                if p.isRunning { timedOut = true; p.terminate() }
            }
        }
        // Both pipes drain at once: a hook that fills stderr while we wait
        // on stdout would otherwise never finish.
        let errors = Drain(err.fileHandleForReading)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let said = String(decoding: errors.wait(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        p.waitUntilExit()
        if timedOut { return .failure(Failure(message: "git \(args.first ?? "") got no answer in two minutes (the remote, or a password nobody was asked for)")) }
        guard p.terminationStatus == 0 else {
            return .failure(Failure(message: said.isEmpty ? "git \(args.first ?? "") failed" : said))
        }
        return .success(String(decoding: data, as: UTF8.self))
    }

    /// The root of the repository `directory` is in, symlinks resolved (as
    /// git reports it); nil outside a repository. Works before the first
    /// commit, unlike anything about HEAD.
    static func root(of directory: String) -> String? {
        run(["rev-parse", "--show-toplevel"], in: directory).flatMap { $0.isEmpty ? nil : $0 }
    }

    /// Every changed file with both its marks, in git's order; nil when git
    /// can't say (not a repository).
    static func changes(in directory: String) -> [GitChange]? {
        guard case .success(let raw) = execute(["status", "--porcelain", "-z"], in: directory) else { return nil }
        return entries(raw)
    }

    /// The changed files of the repository `directory` is in, by real path,
    /// for coloring the file tree: "A" added or staged, "M" modified, "D"
    /// deleted, "R" renamed, "?" untracked, "U" unmerged. The worktree's
    /// mark wins over the index's.
    ///
    /// Real paths on both sides: git names files from the real root, and the
    /// tree lists what FileManager hands back — /private/tmp/… for /tmp/….
    /// Keyed by the directory as given instead, every mark would miss as
    /// soon as a symlink is on the way.
    static func marks(in directory: String) -> [String: Character] {
        guard let root = root(of: directory), let changes = changes(in: root) else { return [:] }
        let base = URL(fileURLWithPath: root)
        var result: [String: Character] = [:]
        for change in changes {
            let mark: Character = change.isUntracked ? "?" : (change.worktree != " " ? change.worktree : change.index)
            result[base.appendingPathComponent(change.path).path] = mark
        }
        return result
    }

    /// `status --porcelain -z`, entry by entry. Read as bytes: "XY " is
    /// three of them, and a name starting with a combining mark would fuse
    /// with that space into one Character.
    private static func entries(_ raw: String) -> [GitChange] {
        let fields = Array(raw.utf8.split(separator: 0, omittingEmptySubsequences: false))
        var result: [GitChange] = []
        var i = 0
        while i < fields.count {
            let field = Array(fields[i])
            i += 1
            guard field.count > 3 else { continue }
            let index = Character(Unicode.Scalar(field[0]))
            let worktree = Character(Unicode.Scalar(field[1]))
            // A rename or a copy is followed by its old path as a field of
            // its own ("R  new\0old\0"): step over it.
            if "RC".contains(index) || "RC".contains(worktree) { i += 1 }
            result.append(GitChange(path: String(decoding: field[3...], as: UTF8.self), index: index, worktree: worktree))
        }
        return result
    }
}

/// Reads a pipe to its end on a thread of its own.
private final class Drain: @unchecked Sendable {
    private var data = Data()
    private let done = DispatchSemaphore(value: 0)

    init(_ handle: FileHandle) {
        DispatchQueue.global(qos: .utility).async {
            self.data = handle.readDataToEndOfFile()
            self.done.signal()
        }
    }

    func wait() -> Data {
        done.wait()
        return data
    }
}

/// The login shell's PATH, read once (in the background, with a deadline)
/// and kept: what a terminal has, for the programs git's hooks run.
enum LoginShell {
    private static let lock = NSLock()
    private nonisolated(unsafe) static var cached: String?

    static var path: String {
        lock.lock()
        defer { lock.unlock() }
        if let cached { return cached }
        let found = read() ?? fallback
        cached = found
        return found
    }

    private static var fallback: String {
        let base = ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin"
        let extra = ["/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin"].filter { !base.contains($0) }
        return (extra + [base]).joined(separator: ":")
    }

    private static func read() -> String? {
        let shell = ProcessInfo.processInfo.environment["SHELL"].flatMap { $0.isEmpty ? nil : $0 } ?? "/bin/zsh"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: shell)
        // -i too: many put PATH in .zshrc. The marker keeps a chatty rc's output out.
        p.arguments = ["-l", "-i", "-c", "printf '\\n__LIBERTTY_PATH__%s' \"$PATH\""]
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch { return nil }
        DispatchQueue.global().asyncAfter(deadline: .now() + 3) { if p.isRunning { p.terminate() } }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let range = text.range(of: "__LIBERTTY_PATH__", options: .backwards) else { return nil }
        let path = text[range.upperBound...].trimmingCharacters(in: .whitespacesAndNewlines)
        return path.isEmpty ? nil : path
    }
}
