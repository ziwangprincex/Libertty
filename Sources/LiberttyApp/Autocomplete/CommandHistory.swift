import AppKit

/// The command lines your shells ran, for autocomplete's suggestions (fish's
/// and zsh-autosuggestions' idea, Otty's per-folder ranking): each line with
/// the folder it ran in, how often and how lately, ranked by frecency with
/// the current folder's first. Recorded from shell integration (OSC 133 C's
/// command line), never what looks like a secret (`SecretFilter`), kept
/// private in the data folder (0600) and capped.
///
/// Thread-safe: the renderer asks from the main thread, saving happens on a
/// queue of its own.
final class CommandHistory: @unchecked Sendable {
    static let shared = CommandHistory(file: Blocks.dataDirectory.appendingPathComponent("autocomplete-history.json"))

    struct Entry: Codable, Equatable {
        var command: String
        /// Where it ran ("" when the shell didn't say); a host's are "host:path".
        var folder: String
        var count: Int
        /// When it last ran (seconds since 1970).
        var last: Double
    }

    /// The most (command, folder) pairs kept; past it the least used go.
    static let limit = 8000
    /// The longest line kept.
    static let maxLength = 1000

    private let file: URL
    private let lock = NSLock()
    /// By command, then folder.
    private var entries: [String: [String: Entry]] = [:]
    private var count = 0
    /// The index (`buildIndex`) needs making again.
    private var indexDirty = false
    private var loaded = false
    /// Bumped whenever what it would suggest may have changed.
    private var changes = 0
    var generation: Int { lock.withLock { changes } }
    private var pendingSave: DispatchWorkItem?
    private let saveQueue = DispatchQueue(label: "libertty.autocomplete.history", qos: .utility)

    init(file: URL) {
        self.file = file
    }

    /// The folder a session's commands are filed under: its shell's (OSC 7),
    /// a host's prefixed with the host ("" when the shell doesn't say).
    static func folder(of session: TerminalSession) -> String {
        let dir = session.workingDirectory ?? ""
        guard let host = session.host else { return dir }
        return host.destination + ":" + dir
    }

    /// Read the file once, off the main thread (until it's read there are
    /// no suggestions; nothing waits for it). Asked again while it reads: once.
    func loadInBackground(then done: (() -> Void)? = nil) {
        let (isLoaded, start): (Bool, Bool) = lock.withLock {
            if loaded { return (true, false) }
            if loading { return (false, false) }
            loading = true
            return (false, true)
        }
        if isLoaded, let done { return DispatchQueue.main.async(execute: done) }
        guard start else { return }
        saveQueue.async { [self] in
            loadIfNeeded()
            // (Made here too, so the first suggestion doesn't make it on the main thread.)
            lock.withLock { if indexDirty { buildIndex(now: Date().timeIntervalSince1970) } }
            if let done { DispatchQueue.main.async(execute: done) }
        }
    }
    private var loading = false

    private func loadIfNeeded() {
        guard !lock.withLock({ loaded }) else { return }
        let read = (try? JSONDecoder().decode([Entry].self, from: Data(contentsOf: file))) ?? []
        lock.withLock {
            guard !loaded else { return }
            for e in read where Self.keeps(e.command) {
                if let mine = entries[e.command]?[e.folder] {
                    // Recorded before the file was read: both count.
                    entries[e.command]?[e.folder] = Entry(command: e.command, folder: e.folder, count: mine.count + e.count,
                                                          last: max(mine.last, e.last))
                } else {
                    entries[e.command, default: [:]][e.folder] = e
                    count += 1
                }
            }
            loaded = true
            indexDirty = true
            changes += 1
        }
    }

    var isLoaded: Bool { lock.withLock { loaded } }

    /// Whether a line is one to keep: one line, not too long, not starting
    /// with a space (shells' ignorespace: "don't remember this one"), and
    /// nothing that looks like a secret.
    static func keeps(_ command: String) -> Bool {
        guard !command.isEmpty, command.count <= maxLength, !command.hasPrefix(" "), !command.hasPrefix("\t") else { return false }
        guard !command.unicodeScalars.contains(where: { $0.properties.generalCategory == .control }) else { return false }
        guard !command.trimmingCharacters(in: .whitespaces).isEmpty else { return false }
        return !SecretFilter.looksSecret(command)
    }

    /// A command that ran in `folder`.
    func record(_ command: String, folder: String, now: Double = Date().timeIntervalSince1970) {
        guard Self.keeps(command) else { return }
        let line = command.trimmingCharacters(in: .whitespaces)
        lock.withLock {
            var e = entries[line]?[folder] ?? Entry(command: line, folder: folder, count: 0, last: now)
            if entries[line]?[folder] == nil { count += 1 }
            e.count += 1
            e.last = now
            entries[line, default: [:]][folder] = e
            if count > Self.limit { evict(now: now) }
            indexDirty = true
            changes += 1
        }
        scheduleSave()
    }

    /// Under `lock`: the least worth keeping tenth goes.
    private func evict(now: Double) {
        let ranked = entries.values.flatMap(\.values).sorted { Self.frecency($0, now: now) < Self.frecency($1, now: now) }
        for e in ranked.prefix(count - Self.limit * 9 / 10) {
            entries[e.command]?[e.folder] = nil
            if entries[e.command]?.isEmpty == true { entries[e.command] = nil }
            count -= 1
        }
    }

    /// Forget everything (Settings ▸ Terminal ▸ Autocomplete, `clear_autocomplete_history`).
    func clear() {
        lock.withLock {
            entries.removeAll()
            count = 0
            index.removeAll()
            folderIDs.removeAll()
            indexDirty = false
            loaded = true
            changes += 1
        }
        pendingSave?.cancel()
        pendingSave = nil
        saveQueue.async { [file] in try? FileManager.default.removeItem(at: file) }
    }

    /// How often and how lately, as Firefox's and zoxide's frecency do:
    /// each use counts more the more recent the last was.
    static func frecency(_ e: Entry, now: Double) -> Double {
        let age = now - e.last
        let recency: Double = age < 3600 ? 4 : age < 86400 ? 2 : age < 7 * 86400 ? 1 : age < 30 * 86400 ? 0.5 : 0.25
        return Double(e.count) * recency
    }

    /// The commands starting with `prefix` (not equal to it), best first:
    /// those run in `folder` count four times over.
    func matches(prefix: String, folder: String, limit: Int = 8, now: Double = Date().timeIntervalSince1970) -> [String] {
        guard !prefix.isEmpty, limit > 0 else { return [] }
        return lock.withLock { () -> [String] in
            // Never made: now. Out of date (a command since, or a minute old):
            // made again off this thread, this answer from the one there is.
            if index.isEmpty, !entries.isEmpty {
                buildIndex(now: now)
            } else if indexDirty || abs(now - indexedAt) > 60 {
                scheduleIndex()
            }
            // The first command not before the prefix; then as long as they start with it.
            var lo = 0, hi = index.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if index[mid].command < prefix { lo = mid + 1 } else { hi = mid }
            }
            let here = folderIDs[folder]
            // The best `limit`, kept in order as they're scored (no sort of them all).
            var best: [(String, Double)] = []
            best.reserveCapacity(limit + 1)
            var i = lo
            while i < index.count, index[i].command.hasPrefix(prefix) {
                let item = index[i]
                i += 1
                guard item.command != prefix else { continue }
                // Everywhere's once, and this folder's three times more.
                var s = item.everywhere
                if let here, !folder.isEmpty { for (f, frecency) in item.folders where f == here { s += 3 * frecency } }
                if best.count == limit, let last = best.last, last.1 >= s { continue }
                let at = best.firstIndex { $0.1 < s } ?? best.count
                best.insert((item.command, s), at: at)
                if best.count > limit { best.removeLast() }
            }
            return best.map(\.0)
        }
    }

    /// The best one (ghost text's).
    func suggestion(for prefix: String, folder: String, now: Double = Date().timeIntervalSince1970) -> String? {
        matches(prefix: prefix, folder: folder, limit: 1, now: now).first
    }

    /// Every command once, sorted, with its frecency everywhere and in each
    /// of its folders (by number): a prefix's matches are a range, each
    /// scored without hashing a string. Made again after a command is
    /// recorded, and once a minute (frecency moves with the clock).
    private struct Indexed {
        var command: String
        var everywhere: Double
        var folders: [(Int, Double)]
    }
    private var index: [Indexed] = []
    private var folderIDs: [String: Int] = [:]
    private var indexedAt: Double = 0
    private var indexScheduled = false

    /// Under `lock`: make it again on the queue (from a copy, the lock not
    /// held meanwhile), once however often asked.
    private func scheduleIndex() {
        guard !indexScheduled else { return }
        indexScheduled = true
        saveQueue.async { [self] in
            let (snapshot, seen) = lock.withLock { (entries, changes) }
            let now = Date().timeIntervalSince1970
            let (built, ids) = Self.makeIndex(snapshot, now: now)
            lock.withLock {
                indexScheduled = false
                index = built
                folderIDs = ids
                indexedAt = now
                // (A command recorded meanwhile: it's still to be made again.)
                if changes == seen { indexDirty = false }
                changes += 1
            }
        }
    }

    /// Under `lock`.
    private func buildIndex(now: Double) {
        (index, folderIDs) = Self.makeIndex(entries, now: now)
        indexDirty = false
        indexedAt = now
    }

    private static func makeIndex(_ entries: [String: [String: Entry]], now: Double) -> ([Indexed], [String: Int]) {
        var ids: [String: Int] = [:]
        let index = entries.keys.sorted().map { command in
            var item = Indexed(command: command, everywhere: 0, folders: [])
            for (folder, e) in entries[command] ?? [:] {
                let f = frecency(e, now: now)
                item.everywhere += f
                let id = ids[folder] ?? ids.count
                ids[folder] = id
                item.folders.append((id, f))
            }
            return item
        }
        return (index, ids)
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.save() }
        pendingSave = work
        saveQueue.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Save now what's waiting to be (quitting).
    func flush() {
        guard let work = pendingSave else { return }
        work.cancel()
        pendingSave = nil
        saveQueue.sync { save() }
    }

    private func save() {
        loadIfNeeded()
        let all = lock.withLock { entries.values.flatMap(\.values) }.sorted { $0.last > $1.last }
        let dir = file.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        guard let data = try? JSONEncoder().encode(all) else { return }
        // Private from the start: written to a 0600 file, then moved over.
        let temp = dir.appendingPathComponent(".autocomplete-history-\(UUID().uuidString)")
        guard FileManager.default.createFile(atPath: temp.path, contents: data, attributes: [.posixPermissions: 0o600]) else { return }
        if rename(temp.path, file.path) != 0 { try? FileManager.default.removeItem(at: temp) }
    }
}

/// Forgetting what autocomplete remembered, asked first (Settings, the palette).
enum CommandHistoryClear {
    static func ask() {
        let alert = NSAlert()
        alert.messageText = L10n.t("Forget the commands remembered for autocomplete?")
        alert.informativeText = L10n.t("Suggestions start again from what your shells run from now on.")
        alert.addButton(withTitle: L10n.t("Forget"))
        alert.addButton(withTitle: L10n.t("Cancel"))
        if alert.runModal() == .alertFirstButtonReturn { CommandHistory.shared.clear() }
    }
}

/// What a command line mustn't be remembered for (Otty's Skip Secrets):
/// a token, a key or a password on it, a variable set to one, credentials
/// in a URL. Erring on the side of not keeping: a line it takes for a
/// secret only isn't suggested later.
enum SecretFilter {
    private static let patterns: [NSRegularExpression] = [
        // Well-known token shapes.
        #"\b(gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,})"#,
        #"\bsk-(ant-|proj-|live-|test-)?[A-Za-z0-9_\-]{16,}"#,
        #"\bxox[abprs]-[A-Za-z0-9-]{10,}"#,
        #"\b(AKIA|ASIA)[0-9A-Z]{16}\b"#,
        #"\bAIza[0-9A-Za-z_\-]{30,}"#,
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,  // a JWT
        #"\bglpat-[A-Za-z0-9_\-]{16,}"#,
        #"\bnpm_[A-Za-z0-9]{30,}"#,
        #"-----BEGIN [A-Z ]*PRIVATE KEY"#,
        // user:password@ in a URL.
        #"[a-zA-Z][a-zA-Z0-9+.\-]*://[^/\s:@]+:[^/\s@]+@"#,
        // A header carrying credentials.
        #"(?i)\b(authorization|x-api-key|api-key|cookie)\s*:"#,
        #"(?i)\bbearer\s+[A-Za-z0-9._\-~+/]{12,}"#,
        // NAME=value where the name says what it is: export, env, a prefix.
        // (Not AUTH: --author=… is no secret; AUTH_TOKEN is a TOKEN.)
        #"(?i)\b[A-Z0-9_]*(PASS(WORD|WD)?|SECRET|TOKEN|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY|CREDENTIALS?)[A-Z0-9_]*\s*=\s*\S"#,
        // An option given one: --password x, --token=x, -p'x' after mysql.
        #"(?i)--?(password|passwd|pass|token|secret|api-?key|access-?key|auth|client-secret)(=|\s+)\S"#,
        #"(?i)\b(mysql|mysqldump|mariadb)\b.*\s-p\S"#,
        // user:password for a request: curl -u, wget --password and the like.
        #"(?i)\b(curl|wget|http|https|xh)\b.*\s(-u|--user)(=|\s+)?[^\s:]+:\S"#,
        #"(?i)\bdocker\s+login\b.*\s(-p|--password)\b"#,
        #"(?i)\bsshpass\b"#,
        // Reading a secret into the shell's view.
        #"(?i)\b(security\s+find-generic-password\b.*-w|op\s+read\b|pass\s+show\b)"#,
    ].compactMap { try? NSRegularExpression(pattern: $0) }

    static func looksSecret(_ line: String) -> Bool {
        let range = NSRange(location: 0, length: (line as NSString).length)
        if patterns.contains(where: { $0.firstMatch(in: line, range: range) != nil }) { return true }
        // A long run of high-entropy characters: a key pasted in.
        for word in line.split(whereSeparator: { $0 == " " || $0 == "=" || $0 == "'" || $0 == "\"" || $0 == ":" }) {
            if word.count >= 32, looksRandom(word) { return true }
        }
        return false
    }

    /// Letters and digits mixed as a key's are, not a path or a word: few
    /// separators, both cases or digits, and many different characters.
    private static func looksRandom(_ word: Substring) -> Bool {
        if word.contains("/") { return false }
        let alnum = word.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) }
        guard Double(alnum.count) >= Double(word.unicodeScalars.count) * 0.9 else { return false }
        let hasUpper = word.contains { $0.isUppercase }, hasLower = word.contains { $0.isLowercase }
        let hasDigit = word.contains { $0.isNumber }
        guard (hasUpper && hasLower) || (hasDigit && (hasUpper || hasLower)) else { return false }
        // A commit's hash is 40 hex digits (64 for SHA-256): commands take those.
        if word.count <= 64, word.allSatisfy({ $0.isHexDigit }) { return false }
        return Set(word).count >= 16
    }
}
