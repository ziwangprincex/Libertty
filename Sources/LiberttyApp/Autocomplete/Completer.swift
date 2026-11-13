import Foundation

/// Subcommands and options of common tools, for the completion list: read
/// from Resources/autocomplete/commands.txt (Libertty's own compact format,
/// described at its top).
final class CommandSpec {
    enum Argument: String { case path, dir, branch, remote, host, script, target }

    struct Option: Equatable {
        var names: [String]
        var takesValue: Bool
        var description: String
    }

    let names: [String]
    let description: String
    var subcommands: [CommandSpec] = []
    var options: [Option] = []
    var argument: Argument?

    init(names: [String], description: String) {
        self.names = names
        self.description = description
    }

    func subcommand(_ name: String) -> CommandSpec? { subcommands.first { $0.names.contains(name) } }

    func option(_ word: String) -> Option? {
        let name = word.split(separator: "=", maxSplits: 1).first.map(String.init) ?? word
        return options.first { $0.names.contains(name) }
    }

    /// The commands in `text`, by each of their names.
    static func parse(_ text: String) -> [String: CommandSpec] {
        var top: [String: CommandSpec] = [:]
        var stack: [(level: Int, spec: CommandSpec)] = []
        for raw in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = String(raw)
            if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty { continue }
            let indent = line.prefix { $0 == " " }.count
            let level = indent / 2
            let body = line.dropFirst(indent)
            // NAMES, then (after two spaces or more) what it does.
            let words: Substring, description: String
            if let gap = body.range(of: "  ") {
                words = body[..<gap.lowerBound]
                description = body[gap.upperBound...].trimmingCharacters(in: .whitespaces)
            } else {
                words = body
                description = ""
            }
            while let last = stack.last, last.level >= level { stack.removeLast() }
            let parent = stack.last?.spec
            if words.hasPrefix("@") {
                parent?.argument = Argument(rawValue: String(words.dropFirst()))
            } else if words.hasPrefix("-") {
                let takesValue = words.hasSuffix("=")
                let names = (takesValue ? words.dropLast() : words).split(separator: "|").map(String.init)
                parent?.options.append(Option(names: names, takesValue: takesValue, description: description))
            } else {
                let spec = CommandSpec(names: words.split(separator: "|").map(String.init), description: description)
                if let parent { parent.subcommands.append(spec) } else { spec.names.forEach { top[$0] = spec } }
                stack.append((level, spec))
            }
        }
        return top
    }

    static let bundled: [String: CommandSpec] = {
        guard let url = AppResources.url("autocomplete/commands.txt"),
              let text = try? String(contentsOf: url, encoding: .utf8) else { return [:] }
        return parse(text)
    }()
}

/// One way to go on: what it completes the word (or line) to, what to type
/// for that, and what it is.
struct Completion: Equatable {
    enum Kind: Equatable { case history, command, subcommand, option, path, folder, value }
    /// What the list shows: the whole word (or, for history, the whole line).
    var title: String
    /// What's typed when it's chosen: the rest after what's there already.
    var insert: String
    var detail: String
    var kind: Kind
}

/// What the line being typed can go on with (the completion list): whole
/// lines from your history, then the word under the cursor completed from
/// the command specs, the commands on PATH, files, and a few things read
/// from the folder (branches, package.json's scripts, a Makefile's targets,
/// ~/.ssh/config's hosts). Only completions that start with what's typed:
/// choosing one types the rest, and never takes anything back.
enum Completer {
    /// The words of the last command on a line (after `|`, `&&`, `;`…) and the
    /// word being typed ("" after a space), with the quote it's inside if any.
    struct Words: Equatable {
        var words: [String]
        var current: String
        var quote: Character?
    }

    static func words(_ line: String) -> Words {
        var words: [String] = [], current = "", quote: Character?, escaped = false
        var inWord = false
        for ch in line {
            if escaped { current.append(ch); escaped = false; inWord = true; continue }
            if let q = quote {
                if ch == q { quote = nil } else if ch == "\\", q == "\"" { escaped = true } else { current.append(ch) }
                continue
            }
            switch ch {
            case "\\": escaped = true; inWord = true
            case "'", "\"": quote = ch; inWord = true
            case " ", "\t":
                if inWord { words.append(current); current = ""; inWord = false }
            case "|", "&", ";", "(", ")":
                // A new command starts after these.
                words = []; current = ""; inWord = false
            default:
                current.append(ch)
                inWord = true
            }
        }
        return Words(words: words, current: current, quote: quote)
    }

    /// Commands that run the next word as a command.
    static let wrappers: Set<String> = ["sudo", "time", "nohup", "command", "exec", "nice", "caffeinate", "env", "noglob"]

    /// What the list offers for `line` typed in `folder` (nil: unknown). On
    /// another machine (`local` false) only what doesn't need this one's
    /// files: history and the specs.
    static func completions(for line: String, folder: String?, local: Bool,
                            history: CommandHistory = .shared, historyFolder: String = "",
                            executables: ExecutableIndex = .shared, specs: [String: CommandSpec] = CommandSpec.bundled,
                            limit: Int = 200) -> [Completion] {
        var found: [Completion] = []
        // Whole lines first, from history, best first.
        if !line.trimmingCharacters(in: .whitespaces).isEmpty {
            for command in history.matches(prefix: line, folder: historyFolder, limit: 3) {
                found.append(Completion(title: command, insert: String(command.dropFirst(line.count)), detail: "",
                                        kind: .history))
            }
        }
        var w = words(line)
        // `sudo git …`: complete git's.
        while let first = w.words.first, wrappers.contains(first) || first.contains("=") && !first.hasPrefix("-") {
            w.words.removeFirst()
        }
        let current = w.current
        func add(_ title: String, _ detail: String, _ kind: Completion.Kind, space: Bool = true) {
            guard title.hasPrefix(current), title != current else { return }
            var rest = String(title.dropFirst(current.count))
            if kind == .path || kind == .folder { rest = escape(rest, in: w.quote) }
            if space, w.quote == nil { rest += " " }
            found.append(Completion(title: title, insert: rest, detail: detail, kind: kind))
        }
        if w.words.isEmpty {
            // The command itself.
            var seen = Set<String>()
            for (name, spec) in specs.sorted(by: { $0.key < $1.key }) where seen.insert(name).inserted {
                add(name, spec.description, .command)
            }
            if local, !current.isEmpty, !current.contains("/") {
                for name in executables.names(prefix: current, limit: limit) where seen.insert(name).inserted {
                    add(name, "", .command)
                }
            }
            if current.contains("/") || current.hasPrefix(".") || current.hasPrefix("~"), local, let folder {
                addPaths(current, folder: folder, onlyFolders: false, quote: w.quote, into: &found)
            }
            return Array(found.prefix(limit))
        }

        // Down the spec's subcommands, past options (and their values).
        let command = (w.words[0] as NSString).lastPathComponent
        var spec = specs[command]
        var expectingValue = false
        for word in w.words.dropFirst() {
            if expectingValue { expectingValue = false; continue }
            guard let s = spec else { break }
            if word.hasPrefix("-") {
                if let option = s.option(word), option.takesValue, !word.contains("=") { expectingValue = true }
            } else if let sub = s.subcommand(word) {
                spec = sub
            }
        }
        // An option's value: nothing to offer but files, for a path-ish one.
        if expectingValue {
            if local, let folder, current.contains("/") || current.hasPrefix(".") || current.hasPrefix("~") {
                addPaths(current, folder: folder, onlyFolders: false, quote: w.quote, into: &found)
            }
            return Array(found.prefix(limit))
        }
        if current.hasPrefix("-") {
            // Once each, by the first of its names that fits (-m, else --message).
            for option in spec?.options ?? [] {
                if let name = option.names.first(where: { $0.hasPrefix(current) && $0 != current }) {
                    add(name, option.description, .option)
                }
            }
            return Array(found.prefix(limit))
        }
        for sub in spec?.subcommands ?? [] {
            if let name = sub.names.first(where: { $0.hasPrefix(current) && $0 != current }) {
                add(name, sub.description, .subcommand)
            }
        }
        let argument = spec?.argument
        if local, let folder {
            switch argument {
            case .branch?: for b in Generators.branches(in: folder) { add(b, L10n.t("branch"), .value) }
            case .remote?: for r in Generators.remotes(in: folder) { add(r, L10n.t("remote"), .value) }
            case .script?: for (name, body) in Generators.scripts(in: folder) { add(name, body, .value) }
            case .target?: for t in Generators.targets(in: folder) { add(t, L10n.t("target"), .value) }
            default: break
            }
            if argument == .host { for h in Generators.sshHosts() { add(h, L10n.t("host"), .value) } }
            // Files: where the spec says so, for a command it doesn't know, or a word that's a path.
            let pathish = current.contains("/") || current.hasPrefix(".") || current.hasPrefix("~")
            if argument == .path || argument == .dir || spec == nil || pathish {
                addPaths(current, folder: folder, onlyFolders: argument == .dir, quote: w.quote, into: &found)
            }
        } else if argument == .host {
            for h in Generators.sshHosts() { add(h, L10n.t("host"), .value) }
        }
        return Array(found.prefix(limit))
    }

    /// The entries of the folder a word names (relative to `folder`), that
    /// start with its last part: folders with a "/", files with a space.
    /// Hidden ones only for a word starting with ".".
    static func addPaths(_ word: String, folder: String, onlyFolders: Bool, quote: Character?, into found: inout [Completion]) {
        let slash = word.lastIndex(of: "/")
        let dirPart = slash.map { String(word[...$0]) } ?? ""
        let namePrefix = slash.map { String(word[word.index(after: $0)...]) } ?? word
        var base = dirPart
        if base.hasPrefix("~") { base = NSHomeDirectory() + base.dropFirst() }
        let dir = base.hasPrefix("/") ? base : (folder as NSString).appendingPathComponent(base)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: dir.isEmpty ? folder : dir) else { return }
        var entries: [(String, Bool)] = []
        for name in names where name.hasPrefix(namePrefix) {
            if name.hasPrefix("."), !namePrefix.hasPrefix(".") { continue }
            var isDir: ObjCBool = false
            FileManager.default.fileExists(atPath: (dir as NSString).appendingPathComponent(name), isDirectory: &isDir)
            if onlyFolders, !isDir.boolValue { continue }
            entries.append((name, isDir.boolValue))
        }
        for (name, isDir) in entries.sorted(by: { $0.0.localizedStandardCompare($1.0) == .orderedAscending }).prefix(200) {
            let title = dirPart + name + (isDir ? "/" : "")
            var rest = escape(String(name.dropFirst(namePrefix.count)), in: quote) + (isDir ? "/" : "")
            if !isDir, quote == nil { rest += " " }
            found.append(Completion(title: title, insert: rest, detail: isDir ? L10n.t("folder") : "", kind: isDir ? .folder : .path))
        }
    }

    /// Characters a shell would take as its own, escaped outside quotes.
    static func escape(_ text: String, in quote: Character?) -> String {
        guard quote == nil else { return text }
        let special = Set(" \t\\'\"$`&;|()<>*?[]#~!{}")
        var out = ""
        for ch in text {
            if special.contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }
}

/// The commands on PATH (this app's, and the usual places shells add),
/// read off the main thread and again a minute later when asked.
final class ExecutableIndex: @unchecked Sendable {
    static let shared = ExecutableIndex()
    private let lock = NSLock()
    private var sorted: [String] = []
    private var readAt: Date?
    private var reading = false

    func names(prefix: String, limit: Int) -> [String] {
        refreshIfDue()
        return lock.withLock {
            var lo = 0, hi = sorted.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if sorted[mid] < prefix { lo = mid + 1 } else { hi = mid }
            }
            var out: [String] = []
            var i = lo
            while i < sorted.count, sorted[i].hasPrefix(prefix), out.count < limit {
                out.append(sorted[i])
                i += 1
            }
            return out
        }
    }

    private func refreshIfDue() {
        let due: Bool = lock.withLock {
            guard !reading, readAt.map({ Date().timeIntervalSince($0) > 60 }) ?? true else { return false }
            reading = true
            return true
        }
        guard due else { return }
        DispatchQueue.global(qos: .utility).async { [self] in
            let names = Self.read()
            lock.withLock {
                sorted = names
                readAt = Date()
                reading = false
            }
        }
    }

    static func read() -> [String] {
        let home = NSHomeDirectory()
        var dirs = (ProcessInfo.processInfo.environment["PATH"] ?? "").split(separator: ":").map(String.init)
        dirs += ["/opt/homebrew/bin", "/usr/local/bin", home + "/.local/bin", home + "/.cargo/bin", home + "/go/bin", home + "/bin"]
        var names = Set<String>()
        let fm = FileManager.default
        for dir in Set(dirs) {
            guard let entries = try? fm.contentsOfDirectory(atPath: dir) else { continue }
            for name in entries where !name.hasPrefix(".") && fm.isExecutableFile(atPath: (dir as NSString).appendingPathComponent(name)) {
                names.insert(name)
            }
        }
        return names.sorted()
    }
}

/// Arguments read from a folder (the completion list's).
enum Generators {
    /// The repository's branches, local then remote (a second at most).
    static func branches(in folder: String) -> [String] {
        run(["for-each-ref", "--format=%(refname:short)", "refs/heads/", "refs/remotes/"], in: folder)
            .filter { !$0.hasSuffix("/HEAD") }
    }

    static func remotes(in folder: String) -> [String] { run(["remote"], in: folder) }

    private static func run(_ args: [String], in folder: String) -> [String] {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "--no-optional-locks", "-C", folder] + args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return [] }
        // Read as it comes (a long list fills the pipe), for a second at most.
        let done = DispatchSemaphore(value: 0)
        var data = Data()
        DispatchQueue.global(qos: .userInitiated).async {
            data = out.fileHandleForReading.readDataToEndOfFile()
            done.signal()
        }
        if done.wait(timeout: .now() + 1) == .timedOut {
            p.terminate()
            return []
        }
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { return [] }
        return String(decoding: data, as: UTF8.self).split(separator: "\n").map(String.init)
    }

    /// package.json's scripts, with what each runs.
    static func scripts(in folder: String) -> [(String, String)] {
        let url = URL(fileURLWithPath: folder).appendingPathComponent("package.json")
        guard let data = try? Data(contentsOf: url),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let scripts = json["scripts"] as? [String: String] else { return [] }
        return scripts.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    /// A Makefile's targets (not its special ones, nor pattern rules).
    static func targets(in folder: String) -> [String] {
        for name in ["GNUmakefile", "makefile", "Makefile"] {
            guard let text = try? String(contentsOfFile: (folder as NSString).appendingPathComponent(name), encoding: .utf8)
            else { continue }
            var found: [String] = []
            for line in text.split(separator: "\n") {
                guard let colon = line.firstIndex(of: ":"), !line.hasPrefix("\t"), !line.hasPrefix(".") else { continue }
                let after = line[line.index(after: colon)...]
                if after.hasPrefix("=") { continue }  // a := variable
                let names = line[..<colon].split(separator: " ")
                for n in names where !n.contains("%") && !n.contains("$") && !n.contains("=") {
                    found.append(String(n))
                }
            }
            return Array(NSOrderedSet(array: found)) as? [String] ?? found
        }
        return []
    }

    /// ~/.ssh/config's hosts (not its patterns).
    static func sshHosts() -> [String] {
        guard let text = try? String(contentsOfFile: NSHomeDirectory() + "/.ssh/config", encoding: .utf8) else { return [] }
        var hosts: [String] = []
        for line in text.split(separator: "\n") {
            let parts = line.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard parts.first?.lowercased() == "host" else { continue }
            hosts += parts.dropFirst().map(String.init).filter { !$0.contains("*") && !$0.contains("?") && !$0.hasPrefix("!") }
        }
        return Array(NSOrderedSet(array: hosts)) as? [String] ?? hosts
    }
}
