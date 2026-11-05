import Foundation

/// A unified diff (`git diff`, a .patch file) as HTML: a header per file
/// with what it adds and removes, then its hunks with old and new line
/// numbers, added and removed lines tinted, code highlighted for its
/// language. Unknown lines (a commit message before the diff) show as text.
enum DiffRenderer {
    /// A file with more changed lines than this starts folded.
    static let foldLines = 400

    /// One row of a file's diff, kept to be laid out two ways.
    private struct Row {
        var cls: String, old: String, new: String, sign: String, code: String
    }

    /// The page shows each file unified or side by side (`layout`: auto is
    /// side by side once the page is wide), each foldable on its own — all
    /// of it HTML and CSS: a document page runs no script.
    static func html(_ text: String, layout: String = "auto") -> String {
        var out = ""
        var files = 0
        var file: (name: String, language: String, rows: [Row], added: Int, removed: Int)?
        var preamble = ""
        var oldLine = 0, newLine = 0
        /// The current file has hunks already (so a `---` starts the next one).
        var inHunks = false
        /// Lines the hunk under way still has, old and new (its `@@` says how
        /// many): while it has any, a line is the hunk's by its first
        /// character — a removed `-- comment` is `--- comment`, not a file.
        var oldLeft = 0, newLeft = 0
        /// Past the last hunk of a counted one, `git format-patch`'s `-- `
        /// signature and its version: no change, up to the next header.
        var counted = false, trailer = false
        func esc(_ s: some StringProtocol) -> String { MarkdownRenderer.escape(String(s)) }
        /// Text before a file (a commit's message and stats): where it came, before that file.
        func emitPreamble() {
            if !preamble.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                out += "<pre class=\"preamble\">\(preamble)</pre>"
            }
            preamble = ""
        }
        func flush() {
            guard let f = file else { return }
            files += 1
            let open = f.added + f.removed > foldLines ? "" : " open"
            out += "<details class=\"file\"\(open)><summary><span class=\"name\">\(esc(f.name))</span>"
                + "<span class=\"stat\"><span class=\"add\">+\(f.added)</span> <span class=\"del\">−\(f.removed)</span></span></summary>"
                + "<table class=\"u\">\(unified(f.rows))</table>"
                + "<table class=\"sp\"><colgroup><col class=\"n\"><col><col class=\"n\"><col></colgroup>\(split(f.rows))</table></details>"
            file = nil
        }
        func row(_ cls: String, _ old: String, _ new: String, _ sign: String, _ code: String) {
            file?.rows.append(Row(cls: cls, old: old, new: new, sign: sign, code: code))
        }
        var lines = text.components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }  // the final newline isn't a line
        for raw in lines {
            let line = raw.hasSuffix("\r") ? String(raw.dropLast()) : raw
            if file != nil, oldLeft > 0 || newLeft > 0 {
                if line.hasPrefix("+") {
                    row("add", "", String(newLine), "+", Highlighter.html(String(line.dropFirst()), language: file!.language))
                    newLine += 1
                    newLeft -= 1
                    file?.added += 1
                    continue
                }
                if line.hasPrefix("-") {
                    row("del", String(oldLine), "", "−", Highlighter.html(String(line.dropFirst()), language: file!.language))
                    oldLine += 1
                    oldLeft -= 1
                    file?.removed += 1
                    continue
                }
                if line.hasPrefix(" ") || line.isEmpty {
                    row("ctx", String(oldLine), String(newLine), "", Highlighter.html(String(line.dropFirst()), language: file!.language))
                    oldLine += 1
                    newLine += 1
                    oldLeft -= 1
                    newLeft -= 1
                    continue
                }
                if line.hasPrefix("\\") {
                    row("meta", "", "", "", esc(line))  // \ No newline at end of file
                    continue
                }
                // Anything else: the hunk was shorter than it said; read on as before.
                oldLeft = 0
                newLeft = 0
            }
            if trailer {
                guard line.hasPrefix("diff ") || line.hasPrefix("--- ") || line.hasPrefix("From ") || line.hasPrefix("@@") else { continue }
                trailer = false
                // The next patch of a series: its header is no line of this file.
                if line.hasPrefix("From ") { flush() }
            }
            if line.hasPrefix("diff --git ") {
                counted = false
                flush()
                emitPreamble()
                // diff --git a/path b/path: the new name.
                let parts = line.dropFirst("diff --git ".count).components(separatedBy: " b/")
                let name = parts.count > 1 ? parts.last! : String(line.dropFirst("diff --git ".count))
                file = (name, Highlighter.language(forFile: (name as NSString).lastPathComponent), [], 0, 0)
                inHunks = false
                continue
            }
            if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                let path = String(line.dropFirst(4)).components(separatedBy: "\t")[0]
                let name = path.hasPrefix("a/") || path.hasPrefix("b/") ? String(path.dropFirst(2)) : path
                if line.hasPrefix("--- "), file == nil || inHunks {
                    // A plain unified diff (no git header): a file starts here.
                    counted = false
                    flush()
                    emitPreamble()
                    file = (name, "", [], 0, 0)
                    inHunks = false
                }
                let current = file?.name
                if path != "/dev/null", line.hasPrefix("+++ ") || current == "/dev/null" { file?.name = name }
                let named = file?.name ?? ""
                file?.language = Highlighter.language(forFile: (named as NSString).lastPathComponent)
                continue
            }
            guard file != nil else {
                preamble += esc(line) + "\n"
                continue
            }
            if line.hasPrefix("@@") {
                // @@ -12,7 +12,8 @@ context
                let scanner = line.split(separator: " ")
                if scanner.count > 2 {
                    oldLine = Int(scanner[1].dropFirst().split(separator: ",").first ?? "") ?? 0
                    newLine = Int(scanner[2].dropFirst().split(separator: ",").first ?? "") ?? 0
                }
                // A plain hunk's lines are counted (-start[,count] +start[,count],
                // a count left out is 1). Not a merge's `@@@` (its lines have
                // a column per parent): read by their first character, as before.
                if line.hasPrefix("@@ "), scanner.count > 2 {
                    let old = scanner[1].split(separator: ","), new = scanner[2].split(separator: ",")
                    oldLeft = old.count > 1 ? Int(old[1]) ?? 0 : 1
                    newLeft = new.count > 1 ? Int(new[1]) ?? 0 : 1
                    counted = true
                } else {
                    oldLeft = 0
                    newLeft = 0
                    counted = false
                }
                row("hunk", "", "", "", esc(line))
                inHunks = true
            } else if line.hasPrefix("index ") && !inHunks {
                continue  // blob hashes: noise here
            } else if line == "-- ", counted || !inHunks {
                // format-patch's signature, after the last hunk (or a file with
                // none: binary, renamed). Not in a merge's uncounted `@@@` hunk.
                trailer = true
            } else if line.hasPrefix("+") {
                row("add", "", String(newLine), "+", Highlighter.html(String(line.dropFirst()), language: file!.language))
                newLine += 1
                file?.added += 1
            } else if line.hasPrefix("-") {
                row("del", String(oldLine), "", "−", Highlighter.html(String(line.dropFirst()), language: file!.language))
                oldLine += 1
                file?.removed += 1
            } else if line.hasPrefix(" ") || (line.isEmpty && oldLine > 0) {
                row("ctx", String(oldLine), String(newLine), "", Highlighter.html(String(line.dropFirst()), language: file!.language))
                oldLine += 1
                newLine += 1
            } else if line.hasPrefix("\\") {
                row("meta", "", "", "", esc(line))  // \ No newline at end of file
            } else if !line.isEmpty {
                // index …, new file mode …, rename from …
                row("meta", "", "", "", esc(line))
            }
        }
        flush()
        emitPreamble()
        if out.isEmpty { out = "<p class=\"empty\">No changes.</p>" }
        // Fold or unfold every file at once: a checkbox the files follow (no script).
        let bar = files > 1
            ? "<input type=\"checkbox\" id=\"fold-all\" class=\"fold-all\"><div class=\"bar\"><span>\(files) files</span>"
                + "<label for=\"fold-all\" class=\"fold-label\"><span class=\"unfolded\">Collapse All</span>"
                + "<span class=\"folded\">Expand All</span></label></div>"
            : ""
        let mode = ["split", "unified"].contains(layout) ? layout : "auto"
        return "<div class=\"diff layout-\(mode)\">" + bar + out + "</div>"
    }

    /// The rows as one column, old and new line numbers side by side.
    private static func unified(_ rows: [Row]) -> String {
        rows.map { r in
            "<tr class=\"\(r.cls)\"><td class=\"n\">\(r.old)</td><td class=\"n\">\(r.new)</td>"
                + "<td class=\"s\">\(r.sign)</td><td class=\"c\">\(r.code)</td></tr>"
        }.joined()
    }

    /// The rows as two columns: context on both sides, a run of removals
    /// beside the additions that replaced them; hunk and other lines across.
    private static func split(_ rows: [Row]) -> String {
        var out = "", dels: [Row] = [], adds: [Row] = []
        func cell(_ r: Row?) -> String {
            guard let r else { return "<td class=\"n\"></td><td class=\"c none\"></td>" }
            let n = r.cls == "add" ? r.new : r.old
            return "<td class=\"n\">\(n)</td><td class=\"c \(r.cls)\">\(r.code)</td>"
        }
        func pairs() {
            for i in 0..<max(dels.count, adds.count) {
                out += "<tr>" + cell(i < dels.count ? dels[i] : nil) + cell(i < adds.count ? adds[i] : nil) + "</tr>"
            }
            dels = []
            adds = []
        }
        for r in rows {
            switch r.cls {
            case "del":
                if !adds.isEmpty { pairs() }  // a removal after additions starts a new run
                dels.append(r)
            case "add": adds.append(r)
            case "ctx":
                pairs()
                out += "<tr><td class=\"n\">\(r.old)</td><td class=\"c ctx\">\(r.code)</td><td class=\"n\">\(r.new)</td><td class=\"c ctx\">\(r.code)</td></tr>"
            default:
                pairs()
                out += "<tr class=\"\(r.cls)\"><td colspan=\"4\">\(r.code)</td></tr>"
            }
        }
        pairs()
        return out
    }

    static func css(dark: Bool) -> String {
        let add = dark ? "rgba(70,190,110,0.16)" : "rgba(40,170,80,0.12)"
        let del = dark ? "rgba(240,90,90,0.16)" : "rgba(220,60,60,0.10)"
        let addFg = dark ? "#7ee2a0" : "#1a7f37", delFg = dark ? "#ff9b9b" : "#cf222e"
        return """
        .diff { font: 12px/1.55 var(--mono); padding: 4px 0; margin: 0 -28px; }
        .diff .preamble { margin: 0 16px 16px; white-space: pre-wrap; opacity: .8; }
        .diff .file { margin: 0 12px 18px; border: 1px solid var(--l2); border-radius: 8px; overflow: hidden; }
        .diff summary { display: flex; gap: 12px; justify-content: space-between; padding: 7px 12px; background: var(--l2);
          font-weight: 600; position: sticky; top: 0; z-index: 1; cursor: default; list-style: none; }
        .diff summary::-webkit-details-marker { display: none; }
        .diff summary .name::before { content: '▾'; display: inline-block; width: 14px; opacity: .5; transition: transform .12s; }
        .diff details:not([open]) summary .name::before { transform: rotate(-90deg); }
        .diff .bar { display: flex; justify-content: space-between; align-items: center; margin: 0 12px 10px; font: 12px var(--sans); opacity: .75; }
        .diff .fold-all { display: none; }
        .diff .fold-label { cursor: default; padding: 2px 8px; border-radius: 6px; box-shadow: inset 0 0 0 1px var(--l3); }
        .diff .fold-label .folded, .diff .fold-all:checked ~ .bar .fold-label .unfolded { display: none; }
        .diff .fold-all:checked ~ .bar .fold-label .folded { display: inline; }
        .diff .fold-all:checked ~ .file > table { display: none; }
        .diff .fold-all:checked ~ .file summary .name::before { transform: rotate(-90deg); }
        .diff table.sp { display: none; table-layout: fixed; }
        .diff table.sp col.n { width: 52px; }
        .diff table.sp td.c { border-left: 0; }
        .diff table.sp td.c.add { background: \(add); } .diff table.sp td.c.del { background: \(del); }
        .diff table.sp td.c.none { background: var(--l1); }
        .diff table.sp tr.hunk td, .diff table.sp tr.meta td { opacity: .6; }
        .diff.layout-split table.u { display: none; } .diff.layout-split table.sp { display: table; }
        @media (min-width: 1000px) {
          .diff.layout-auto table.u { display: none; } .diff.layout-auto table.sp { display: table; }
        }
        .diff .stat { font-weight: 500; } .diff .stat .add { color: \(addFg); } .diff .stat .del { color: \(delFg); }
        .diff table { border-collapse: collapse; width: 100%; }
        .diff td { padding: 0 8px; vertical-align: top; white-space: pre-wrap; word-break: break-all; }
        .diff td.n { width: 1%; text-align: right; opacity: .45; user-select: none; white-space: nowrap; }
        .diff td.s { width: 1%; user-select: none; }
        .diff tr.add { background: \(add); } .diff tr.add td.s { color: \(addFg); }
        .diff tr.del { background: \(del); } .diff tr.del td.s { color: \(delFg); }
        .diff tr.hunk td { opacity: .6; padding-top: 6px; padding-bottom: 3px; }
        .diff tr.meta td { opacity: .5; }
        .diff .empty { text-align: center; opacity: .6; margin-top: 40px; }
        """
    }
}

/// `git diff` into a file Libertty shows (`libertty +diff`, Inspector ▸ Show
/// Changes): one file per repository, so showing it again refreshes the
/// pane already open (it watches its file).
enum GitDiff {
    struct Failure: LocalizedError {
        var message: String
        var errorDescription: String? { message }
    }

    /// The diff's file, or why there is none. `name` keys a diff of its own
    /// (the panel's one-file diffs: "staged/Sources/a.swift"); its last
    /// component names the file. `literal`: the paths are file names, not
    /// patterns (the panel's; `libertty +diff '*.swift'` means a pattern).
    static func write(directory: String, arguments: [String] = [], name: String? = nil, literal: Bool = false) -> Result<URL, Failure> {
        guard let git = GitCLI.executable else { return .failure(Failure(message: GitCLI.missing)) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = ["--no-optional-locks", "-c", "core.quotePath=false"] + (literal ? ["--literal-pathspecs"] : [])
            + ["-C", directory, "diff", "--no-color", "--no-ext-diff"] + arguments
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        do { try p.run() } catch { return .failure(Failure(message: error.localizedDescription)) }
        // Both at once: git fills a pipe of warnings (a line ending each, for
        // hundreds of files) and waits on it while stdout is still being read.
        let errorsDrain = Drain(err.fileHandleForReading)
        let data = out.fileHandleForReading.readDataToEndOfFile()
        let errors = String(decoding: errorsDrain.wait(), as: UTF8.self)
        p.waitUntilExit()
        // `--no-index` (a new file against /dev/null) exits 1 for "they differ".
        let differs = arguments.contains("--no-index") && p.terminationStatus == 1
        guard p.terminationStatus == 0 || differs else {
            let why = errors.trimmingCharacters(in: .whitespacesAndNewlines)
            return .failure(Failure(message: why.isEmpty ? "git diff failed" : why))
        }
        let top = run(["-C", directory, "rev-parse", "--show-toplevel"]) ?? directory
        let repo = (top as NSString).lastPathComponent
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("libertty-diffs", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Stable per repository and name (String.hashValue changes every
        // run), so showing a diff again refreshes the pane already open on
        // it — and two files called index.ts get a pane each.
        let key = top + "\u{0}" + (name ?? "")
        let digest = key.utf8.reduce(UInt32(2166136261)) { ($0 ^ UInt32($1)) &* 16777619 } % 100_000
        let stem = name.map { ($0 as NSString).lastPathComponent } ?? repo
        let file = dir.appendingPathComponent("\(stem)-\(digest).diff")
        do { try data.write(to: file, options: .atomic) } catch { return .failure(Failure(message: error.localizedDescription)) }
        return .success(file)
    }

    private static func run(_ args: [String]) -> String? {
        guard let git = GitCLI.executable else { return nil }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: git)
        p.arguments = args
        let out = Pipe()
        p.standardOutput = out
        p.standardError = FileHandle.nullDevice
        guard (try? p.run()) != nil else { return nil }
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return p.terminationStatus == 0 ? text.trimmingCharacters(in: .whitespacesAndNewlines) : nil
    }
}
