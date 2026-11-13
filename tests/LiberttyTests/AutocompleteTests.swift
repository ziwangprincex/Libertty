import Foundation
import Testing
@testable import LiberttyApp

/// Autocomplete: the line read off the screen, history and its ranking,
/// what's never kept, the specs, and the completion list's candidates.
struct AutocompleteTests {
    // MARK: Reading the line

    /// A row: prompt cells, then input, then blanks to `cols`.
    private func row(_ prompt: String, _ input: String, cols: Int = 20, after: String = "", afterAt: Int? = nil,
                     wraps: Bool = false, mark: PromptLine.Row.Mark = .prompt) -> PromptLine.Row {
        var cells = prompt.map { PromptLine.Cell(text: String($0), kind: .prompt) }
        for ch in input {
            cells.append(PromptLine.Cell(text: String(ch), kind: .input))
            if String(ch).unicodeScalars.first!.value >= 0x4E00 { cells.append(PromptLine.Cell(text: "", kind: .input, spacer: true)) }
        }
        while cells.count < cols { cells.append(.blank()) }
        if let at = afterAt {
            for (i, ch) in after.enumerated() { cells[at + i] = PromptLine.Cell(text: String(ch), kind: .input) }
        }
        return PromptLine.Row(cells: Array(cells.prefix(cols)), wraps: wraps, mark: mark)
    }

    @Test func readsWhatsTyped() throws {
        let line = try #require(PromptLine.read([row("$ ", "git st")], cursor: (0, 8)))
        #expect(line == PromptLine(typed: "git st", room: 12, atEnd: true))
        // Right after the prompt: nothing typed, but a prompt.
        #expect(PromptLine.read([row("$ ", "")], cursor: (0, 2)) == PromptLine(typed: "", room: 18, atEnd: true))
    }

    @Test func notAtTheEnd() throws {
        // The cursor moved back into what's typed.
        let line = try #require(PromptLine.read([row("$ ", "git status")], cursor: (0, 5)))
        #expect(!line.atEnd && line.typed == "git")
        // Spaces after the cursor are blank: zsh erases a line with them.
        let erased = try #require(PromptLine.read([row("$ ", "ls", after: "     ", afterAt: 4)], cursor: (0, 4)))
        #expect(erased.atEnd && erased.room == 16)
    }

    @Test func rightPrompt() throws {
        // zsh's RPROMPT at the row's end, after a gap: still at the end, room before it.
        let line = try #require(PromptLine.read([row("$ ", "ls", after: "12:00", afterAt: 15)], cursor: (0, 4)))
        #expect(line.atEnd && line.room == 10)
    }

    @Test func wideCharactersAndWraps() throws {
        let line = try #require(PromptLine.read([row("$ ", "echo 中文")], cursor: (0, 11)))
        #expect(line.typed == "echo 中文")
        // A line wrapped onto the next row: typed from the first.
        let rows = [row("$ ", "echo aaaaaaa", cols: 14, wraps: true), row("", "bbb", cols: 14, mark: .none)]
        let wrapped = try #require(PromptLine.read(rows, cursor: (1, 3)))
        #expect(wrapped.typed == "echo aaaaaaabbb")
    }

    @Test func notAPrompt() {
        // Output before the cursor: a program's screen, not a prompt.
        let output = PromptLine.Row(cells: "hello".map { PromptLine.Cell(text: String($0), kind: .output) } + [.blank(), .blank()])
        #expect(PromptLine.read([output], cursor: (0, 5)) == nil)
    }

    @Test func commandsOfSeveralLines() throws {
        // PS2: the line above holds input since the prompt: none.
        let rows = [row("$ ", "for x in a b"), row("> ", "do", mark: .continuation)]
        #expect(PromptLine.read(rows, cursor: (1, 4)) == nil)
        // A two-line prompt: its first line has none.
        let twoLine = [row("~/src main", ""), row("❯ ", "ls", mark: .continuation)]
        #expect(try #require(PromptLine.read(twoLine, cursor: (1, 4))).typed == "ls")
    }

    // MARK: History

    private func history() -> CommandHistory {
        CommandHistory(file: FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json"))
    }

    @Test func historyRanksThisFolderFirst() {
        let h = history()
        h.loadInBackground()
        let now = Date().timeIntervalSince1970
        for _ in 0..<3 { h.record("git status", folder: "/a", now: now - 10) }
        h.record("git stash pop", folder: "/b", now: now - 10)
        #expect(h.suggestion(for: "git st", folder: "/a", now: now) == "git status")
        // Once in /b beats three times elsewhere, four to one… so tie it the other way.
        h.record("git stash pop", folder: "/b", now: now - 10)
        #expect(h.suggestion(for: "git st", folder: "/b", now: now) == "git stash pop")
        // Not the line itself, and nothing for nothing.
        #expect(h.matches(prefix: "git status", folder: "/a").isEmpty)
        #expect(h.matches(prefix: "", folder: "/a").isEmpty)
    }

    @Test func recentBeatsOld() {
        let h = history()
        let now = Date().timeIntervalSince1970
        for _ in 0..<3 { h.record("make build", folder: "", now: now - 60 * 86400) }
        h.record("make bench", folder: "", now: now - 60)
        #expect(h.suggestion(for: "make b", folder: "", now: now) == "make bench")
    }

    @Test func whatIsNeverKept() {
        let h = history()
        for line in [" secret command", "echo one\necho two", "export GITHUB_TOKEN=abc", "curl -H 'Authorization: Bearer abcdefghijklmnop' x"] {
            h.record(line, folder: "")
        }
        #expect(h.matches(prefix: " ", folder: "").isEmpty)
        #expect(h.matches(prefix: "e", folder: "").isEmpty)
        #expect(h.matches(prefix: "c", folder: "").isEmpty)
    }

    @Test func savedPrivately() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("history-\(UUID().uuidString).json")
        defer { try? FileManager.default.removeItem(at: file) }
        let h = CommandHistory(file: file)
        h.record("swift build", folder: "/p")
        h.flush()
        let mode = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int
        #expect(mode == 0o600)
        let again = CommandHistory(file: file)
        let done = DispatchSemaphore(value: 0)
        again.loadInBackground { done.signal() }
        while done.wait(timeout: .now()) == .timedOut { RunLoop.main.run(until: Date().addingTimeInterval(0.01)) }
        #expect(again.suggestion(for: "swift b", folder: "/p") == "swift build")
        again.clear()
        #expect(again.suggestion(for: "swift b", folder: "/p") == nil)
    }

    @Test func secrets() {
        let secret = [
            "export OPENAI_API_KEY=sk-proj-abcdefghijklmnopqrstuv",
            "git clone https://me:hunter2@example.com/repo.git",
            "mysql -u root -phunter2 db",
            "curl --token abc123 https://x",
            "gh auth login --with-token ghp_abcdefghijklmnopqrstuvwxyz0123",
            "AWS_SECRET_ACCESS_KEY=abc aws s3 ls",
            "aws configure set aws_access_key_id AKIAABCDEFGHIJKLMNOP",
            "echo eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0NTY3ODkwIn0.dozjgNryP4J3jVmNHl0w5N_XgL0n3I9PlFUP0THsR8U",
            "deploy --password=hunter2",
            "echo 8f3Kq9ZpL2mXv7RtB4nWc6YhJ1dGsA0eUo5",
            "curl -u admin:hunter2 https://example.com/api",
            "docker login -u me -p hunter2 registry.example.com",
        ]
        for line in secret { #expect(SecretFilter.looksSecret(line), "\(line)") }
        let plain = [
            "git log --author=bob", "git show 3f1c2a9b8e7d6c5b4a39281706f5e4d3c2b1a098", "ls -la ~/Library/Application Support",
            "npm run build", "ssh -p 2222 me@example.com", "grep -r password src/", "cd /Users/me/src/very-long-project-name-here",
            "kubectl get pods -n kube-system -o wide", "make passthrough-test",
            "curl -u admin https://example.com", "curl https://example.com:8443/path",
        ]
        for line in plain { #expect(!SecretFilter.looksSecret(line), "\(line)") }
    }

    // MARK: Specs and candidates

    @Test func specsParse() throws {
        let specs = CommandSpec.parse("""
        # comment
        tool|t  A tool
          sub|s  A subcommand
            -f|--file=  A file
            -v  Verbose
            @path
          other  Another
        """)
        let tool = try #require(specs["t"])
        #expect(tool.names == ["tool", "t"] && tool.description == "A tool")
        let sub = try #require(tool.subcommand("s"))
        #expect(sub.options.map(\.names) == [["-f", "--file"], ["-v"]])
        #expect(sub.option("--file=x")?.takesValue == true && sub.argument == .path)
        #expect(tool.subcommand("other") != nil)
        #expect(!CommandSpec.bundled.isEmpty && CommandSpec.bundled["git"]?.subcommand("checkout") != nil)
    }

    @Test func words() {
        #expect(Completer.words("git commit -m 'a b").words == ["git", "commit", "-m"])
        #expect(Completer.words("git commit -m 'a b").current == "a b")
        #expect(Completer.words("git commit -m 'a b").quote == "'")
        #expect(Completer.words("ls | grep fo").words == ["grep"])
        #expect(Completer.words("cd my\\ dir/").current == "my dir/")
        #expect(Completer.words("echo ").current == "")
    }

    private func completions(_ line: String, folder: String? = nil, history: CommandHistory? = nil) -> [Completion] {
        Completer.completions(for: line, folder: folder, local: folder != nil, history: history ?? self.history())
    }

    @Test func subcommandsAndOptions() {
        let subs = completions("git ch").map(\.title)
        #expect(subs.contains("checkout") && subs.contains("cherry-pick"))
        #expect(completions("git ch").first { $0.title == "checkout" }?.insert == "eckout ")
        #expect(completions("git commit --am").map(\.title) == ["--amend"])
        // A subcommand once, by its first name that fits: commit, not ci too.
        #expect(completions("git c").map(\.title) == ["commit", "checkout", "clone", "cherry-pick", "config"])
        #expect(completions("git co").map(\.title) == ["commit", "config"])
        #expect(completions("git commit -").map(\.title).prefix(3) == ["-m", "-a", "--amend"])
        // An option's value: nothing to offer.
        #expect(completions("git commit -m ").isEmpty)
        // Through sudo.
        #expect(completions("sudo brew inst").map(\.title).contains("install"))
    }

    @Test func historyComesFirst() {
        let h = history()
        h.record("git checkout -b feature", folder: "")
        let list = completions("git ch", history: h)
        #expect(list.first?.kind == .history && list.first?.insert == "eckout -b feature")
    }

    @Test func paths() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("complete-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir.appendingPathComponent("src dir"), withIntermediateDirectories: true)
        try "x".write(to: dir.appendingPathComponent("setup.sh"), atomically: true, encoding: .utf8)
        try "x".write(to: dir.appendingPathComponent(".hidden"), atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: dir) }
        let list = completions("cat s", folder: dir.path)
        // A folder with a slash (its space escaped), a file with a space after.
        #expect(list.first { $0.title == "src dir/" }?.insert == "rc\\ dir/")
        #expect(list.first { $0.title == "setup.sh" }?.insert == "etup.sh ")
        #expect(!list.contains { $0.title == ".hidden" })
        #expect(completions("cat .h", folder: dir.path).contains { $0.title == ".hidden" })
        // cd: folders only.
        #expect(completions("cd s", folder: dir.path).map(\.title) == ["src dir/"])
        // Inside quotes, nothing escaped.
        #expect(completions("cat 's", folder: dir.path).first { $0.title == "src dir/" }?.insert == "rc dir/")
    }

    @Test func nextWord() {
        #expect(TerminalView.nextWord(of: "t status --short") == "t")
        #expect(TerminalView.nextWord(of: " status --short") == " status")
        #expect(TerminalView.nextWord(of: "end") == "end")
    }
}
