import Foundation

/// `libertty +import-ghostty [--from FILE] [--dry-run] [--yes]`: Ghostty's
/// settings into Libertty's config file (after Rex's "Migrate from
/// Ghostty"). The format is the same; what Libertty knows and accepts comes
/// over, what its own file sets stays as it is.
enum GhosttyImport {
    private static func fail(_ message: String) {
        fflush(stdout)
        FileHandle.standardError.write(Data("libertty: \(message)\n".utf8))
    }

    /// Ghostty's config files, in the order it reads them (a later one wins):
    /// the XDG ones, then (macOS) Application Support's — in each, the older
    /// name, then 1.3's.
    static var ghosttyFiles: [URL] {
        let fm = FileManager.default
        let env = ProcessInfo.processInfo.environment
        let xdg = URL(fileURLWithPath: env["XDG_CONFIG_HOME"].flatMap { $0.isEmpty ? nil : $0 }
            ?? (NSHomeDirectory() as NSString).appendingPathComponent(".config")).appendingPathComponent("ghostty")
        let support = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent("Library/Application Support/com.mitchellh.ghostty")
        return [xdg, support].flatMap { dir in
            ["config", "config.ghostty"].map { dir.appendingPathComponent($0) }.filter { fm.fileExists(atPath: $0.path) }
        }
    }

    /// Every `key = value` of `files` and the files they pull in, in the order
    /// Ghostty reads them: the files, then what they include (`config-file`),
    /// then what those include.
    static func entries(of files: [URL]) -> [(key: String, value: String, raw: String)] {
        var queue = files, seen = Set<String>(), out: [(key: String, value: String, raw: String)] = []
        var i = 0
        while i < queue.count {
            out += entries(of: queue[i], seen: &seen, includes: &queue)
            i += 1
        }
        return out
    }

    /// The `key = value`s of `url`; the files it pulls in (`config-file`,
    /// relative to it, `?` for optional) go on `includes`.
    private static func entries(of url: URL, seen: inout Set<String>, includes: inout [URL])
        -> [(key: String, value: String, raw: String)] {
        let path = url.standardizedFileURL.path
        guard seen.insert(path).inserted, let text = try? String(contentsOf: url, encoding: .utf8) else { return [] }
        var out: [(String, String, String)] = []
        // \r\n is one Character: split at every kind of line end.
        for line in text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline).map(String.init) {
            guard let key = ConfigStore.key(of: line) else { continue }
            let raw = ConfigStore.value(of: line)
            var value = raw
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") { value = String(value.dropFirst().dropLast()) }
            if key == "config-file" {
                var spec = value
                if spec.hasPrefix("?") { spec.removeFirst() }
                guard !spec.isEmpty else { continue }
                spec = (spec as NSString).expandingTildeInPath
                includes.append(spec.hasPrefix("/") ? URL(fileURLWithPath: spec)
                    : url.deletingLastPathComponent().appendingPathComponent(spec))
                continue
            }
            out.append((key, value, raw))
        }
        return out
    }

    /// What an import would do: lines to add, and what stays out and why.
    struct Plan {
        var lines: [String] = []
        var kept: [String] = []       // set in Libertty's file already
        var unknown: [String] = []    // keys Libertty doesn't have
        var refused: [String] = []    // values Libertty doesn't accept
    }

    static func plan(_ entries: [(key: String, value: String, raw: String)],
                     libertty: (keys: Set<String>, lines: Set<String>)) -> Plan {
        var plan = Plan()
        let known = Set(Config.documentation.map(\.key))
        // Ghostty: the last of a key wins (an empty value: its default);
        // repeatable ones add up. font-family repeats for fallbacks:
        // Libertty has one font, the first since the last reset.
        var single: [String: (String, String)] = [:], order: [String] = []
        var repeated: [(String, String, String)] = []
        var fontFamily: (String, String)?
        for (key, value, raw) in entries {
            if Config.repeatable.contains(key) { repeated.append((key, value, raw)); continue }
            if !order.contains(key) { order.append(key) }
            if key == "font-family" {
                if value.isEmpty { fontFamily = nil } else if fontFamily == nil { fontFamily = (value, raw) }
                continue
            }
            single[key] = (value, raw)
        }
        if let fontFamily { single["font-family"] = fontFamily }
        var scratch = Config()
        for key in order {
            guard known.contains(key), key != "browser-automation" else { plan.unknown.append(key); continue }
            // Ghostty's default in the end: Libertty's own stays.
            guard let (value, raw) = single[key], !value.isEmpty else { continue }
            if libertty.keys.contains(key) { plan.kept.append(key); continue }
            if let problem = scratch.set(key, value) { plan.refused.append("\(key) = \(raw): \(problem)"); continue }
            plan.lines.append("\(key) = \(raw)")
        }
        // What Libertty's file binds and colors itself stays its own.
        let ownTriggers = Set(libertty.lines.filter { $0.hasPrefix("keybind = ") }
            .compactMap { Keybinds.trigger(of: ConfigStore.value(of: $0)) })
        let ownColors = Set(libertty.lines.filter { $0.hasPrefix("palette = ") }.compactMap { paletteIndex(ConfigStore.value(of: $0)) })
        for (key, value, raw) in repeated {
            guard known.contains(key) || key == "font-feature" else { plan.unknown.append(key); continue }
            let line = "\(key) = \(raw)"
            if libertty.lines.contains(line) || plan.lines.contains(line) { continue }
            // These would wipe Libertty's own: every keybind, color or feature before them.
            if value.isEmpty || key == "keybind" && value.trimmingCharacters(in: .whitespaces) == "clear" {
                plan.refused.append("\(line): would clear Libertty's own \(key)s too")
                continue
            }
            if key == "keybind", let trigger = Keybinds.trigger(of: value), ownTriggers.contains(trigger) {
                plan.kept.append("keybind \(value.split(separator: "=").first ?? "")")
                continue
            }
            if key == "palette", let index = paletteIndex(value), ownColors.contains(index) {
                plan.kept.append("palette \(index)")
                continue
            }
            if let problem = scratch.set(key, value) { plan.refused.append("\(line): \(problem)"); continue }
            plan.lines.append(line)
        }
        plan.unknown = plan.unknown.reduce(into: []) { if !$0.contains($1) { $0.append($1) } }
        return plan
    }

    /// `N=#rrggbb`'s N.
    private static func paletteIndex(_ value: String) -> Int? {
        value.split(separator: "=", maxSplits: 1).first.flatMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    static func run(_ args: [String]) -> Int32 {
        let usage = "usage: libertty +import-ghostty [--from FILE] [--dry-run] [--yes]"
        var from: URL?
        var i = 0
        while i < args.count {
            switch args[i] {
            case "--from":
                guard i + 1 < args.count else { fail(usage); return 2 }
                from = URL(fileURLWithPath: (args[i + 1] as NSString).expandingTildeInPath)
                i += 1
            case "--dry-run", "--yes": break
            default: fail(usage); return 2
            }
            i += 1
        }
        let files = from.map { [$0] } ?? ghosttyFiles
        guard !files.isEmpty else { fail("no Ghostty config found (~/.config/ghostty/config.ghostty; --from FILE for another)"); return 1 }
        if let from, !FileManager.default.fileExists(atPath: from.path) { fail("\(from.path): no such file"); return 1 }
        let entries = entries(of: files)
        let store = ConfigStore.shared
        let plan = plan(entries, libertty: store.fileEntries)
        let shown = { (url: URL) in (url.path as NSString).abbreviatingWithTildeInPath }

        print("From Ghostty: " + files.map(shown).joined(separator: ", "))
        print("Into: \(shown(store.url))")
        if !plan.lines.isEmpty {
            print("\nTo add:")
            plan.lines.forEach { print("  " + $0) }
        }
        if !plan.kept.isEmpty { print("\nSet in Libertty's file already, kept: " + plan.kept.joined(separator: ", ")) }
        if !plan.unknown.isEmpty { print("\nGhostty settings Libertty doesn't have, left out: " + plan.unknown.joined(separator: ", ")) }
        if !plan.refused.isEmpty {
            print("\nNot accepted:")
            plan.refused.forEach { print("  " + $0) }
        }
        guard !plan.lines.isEmpty else { print("\nNothing to add."); return 0 }
        if args.contains("--dry-run") { print("\n(--dry-run: nothing written)"); return 0 }
        if !args.contains("--yes") {
            guard isatty(STDIN_FILENO) != 0 else { fail("not asked on a terminal: run again with --yes to go ahead"); return 1 }
            print("\nAdd these \(plan.lines.count) lines? [y/N] ", terminator: "")
            fflush(stdout)
            guard let answer = readLine(), ["y", "yes"].contains(answer.lowercased()) else { print("Nothing changed."); return 1 }
        }
        // The file as it was, beside it.
        if FileManager.default.fileExists(atPath: store.url.path) {
            let backup = store.url.deletingLastPathComponent()
                .appendingPathComponent("config.before-ghostty-import-\(Int(Date().timeIntervalSince1970))")
            do { try FileManager.default.copyItem(at: store.url, to: backup) } catch {
                fail("couldn't keep a copy of the config: \(error.localizedDescription)")
                return 1
            }
            print("The config as it was: \(shown(backup))")
        }
        let date = ISO8601DateFormatter.string(from: Date(), timeZone: .current, formatOptions: [.withFullDate])
        guard store.appendBlock(["# From Ghostty (\(files.map(shown).joined(separator: ", "))), \(date)"] + plan.lines) else {
            fail("couldn't write \(shown(store.url)); nothing changed")
            return 1
        }
        print("Added. A running Libertty applies it now.")
        return 0
    }
}
