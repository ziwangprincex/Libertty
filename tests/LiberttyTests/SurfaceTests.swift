import Foundation
import Testing
@testable import LiberttyApp

/// The surface protocol's sequences, specs and events (SurfaceProtocol).
struct SurfaceProtocolTests {
    private func json(_ o: Any) -> String { String(decoding: try! JSONSerialization.data(withJSONObject: o), as: UTF8.self) }

    @Test func commands() throws {
        #expect(try SurfaceProtocol.command("7502;q") == .query)
        #expect(try SurfaceProtocol.command("7502;c") == .clear)
        #expect(try SurfaceProtocol.command("7502;d;build") == .delete("build"))
        #expect(try SurfaceProtocol.command("7502;s;{\"id\":\"a\"}") == .set("{\"id\":\"a\"}"))
        let b64 = Data("{\"id\":\"é\"}".utf8).base64EncodedString()
        #expect(try SurfaceProtocol.command("7502;s;b64:\(b64)") == .set("{\"id\":\"é\"}"))
        // Not ours: another number, one that only starts like it.
        #expect(try SurfaceProtocol.command("7501;state=working") == nil)
        #expect(try SurfaceProtocol.command("75020;q") == nil)
        #expect(throws: SurfaceProtocol.ParseError.self) { try SurfaceProtocol.command("7502;x") }
        #expect(throws: SurfaceProtocol.ParseError.self) { try SurfaceProtocol.command("7502;d;../x") }
        #expect(throws: SurfaceProtocol.ParseError.self) { try SurfaceProtocol.command("7502;s;not json") }
        #expect(throws: SurfaceProtocol.ParseError.self) { try SurfaceProtocol.command("7502;s;b64:@@@") }
    }

    @Test func specs() throws {
        let inline = try SurfaceSpec.parse(json(["id": "build", "rows": 5, "title": "Build", "elements": [
            ["type": "text", "text": "hi", "style": "title"],
            ["type": "buttons", "items": [["id": "go", "label": "Go", "style": "primary"], ["label": "Later"]]],
            ["type": "progress", "value": 0.25],
            ["type": "list", "id": "files", "select": "multi", "items": [["id": "a", "label": "a.txt", "detail": "new"]]],
            ["type": "table", "id": "t", "columns": ["Name", "Size"], "rows": [["x", "1"], ["id": "y", "cells": ["y"]]]],
            ["type": "keyvalue", "items": [["Branch", "main"]]],
            ["type": "input", "id": "note", "placeholder": "why"],
            ["type": "diff", "text": "+a\n-b"], ["type": "divider"],
        ]]), remote: false)
        #expect(inline.placement == .inline(rows: 5, fromCursor: false))
        #expect(inline.elements.count == 9)
        #expect(inline.elements[1].items.map(\.id) == ["go", "1"])
        #expect(inline.elements[2].value == 0.25)
        #expect(inline.elements[3].selection == .multi)
        #expect(inline.elements[4].rows.map(\.id) == ["0", "y"])
        #expect(inline.elements[4].rows[1].cells == ["y", ""])
        let overlay = try SurfaceSpec.parse(json(["id": "o", "placement": "overlay", "position": "top-right", "cols": 9999,
                                                  "elements": []]), remote: false)
        #expect(overlay.placement == .overlay(position: .topRight, cols: 400, rows: 10))
    }

    @Test func refusals() {
        func bad(_ o: [String: Any], remote: Bool = false) -> Bool {
            (try? SurfaceSpec.parse(json(o), remote: remote)) == nil
        }
        #expect(bad(["elements": []]))  // no id
        #expect(bad(["id": "has space", "elements": []]))
        #expect(bad(["id": "a", "rows": 0, "elements": []]))
        #expect(bad(["id": "a", "rows": 41, "elements": []]))
        #expect(bad(["id": "a", "placement": "sideways", "elements": []]))
        #expect(bad(["id": "a", "elements": Array(repeating: ["type": "divider"], count: 201)]))
        #expect(bad(["id": "a", "elements": [["type": "text", "id": "x"], ["type": "text", "id": "x"]]]))
        #expect(bad(["id": "a", "elements": [["type": "input"]]]))  // an input needs an id
        #expect(bad(["id": "a", "elements": [["type": "script"]]]))
        #expect(bad(["id": "a", "elements": [["type": "buttons", "items": Array(repeating: ["label": "x"], count: 13)]]]))
        // A path on another machine names nothing here; a relative one, nothing at all.
        #expect(bad(["id": "a", "elements": [["type": "image", "path": "/tmp/x.png"]]], remote: true))
        #expect(bad(["id": "a", "elements": [["type": "image", "path": "x.png"]]]))
        let huge = Data(count: SurfaceProtocol.maxImageBytes + 1).base64EncodedString()
        #expect(bad(["id": "a", "elements": [["type": "image", "data": huge]]]))
    }

    /// Untrusted text: no controls, no bidirectional overrides, not too long.
    @Test func cleaning() throws {
        let spec = try SurfaceSpec.parse(json(["id": "a", "title": "Pay\u{202E}lacol\u{1b}[31m", "elements": [
            ["type": "text", "text": String(repeating: "x", count: 30_000)],
        ]]), remote: false)
        #expect(spec.title == "Paylacol[31m")
        #expect(spec.elements[0].text.count == SurfaceProtocol.maxText)
    }

    @Test func events() throws {
        let data = SurfaceProtocol.event(["surface": "a", "type": "submit", "values": ["note": "\u{1b}]52;c;evil\u{7}"]])
        let text = String(decoding: data, as: UTF8.self)
        #expect(text.hasPrefix("\u{1b}]7502;e;b64:") && text.hasSuffix("\u{7}"))
        // What the user typed can't end the sequence or start another.
        let body = text.dropFirst("\u{1b}]7502;e;b64:".count).dropLast()
        #expect(!body.contains("\u{1b}") && !body.contains("\u{7}"))
        let decoded = try #require(Data(base64Encoded: String(body)))
        let object = try #require(try JSONSerialization.jsonObject(with: decoded) as? [String: Any])
        #expect((object["values"] as? [String: String])?["note"] == "\u{1b}]52;c;evil\u{7}")
        #expect(String(decoding: SurfaceProtocol.queryReply, as: UTF8.self).hasPrefix("\u{1b}]7502;q;v=1;elements=text,"))
    }

    @Test func peekID() {
        #expect(SurfaceStore.peekID(#"{"elements":[],"id":"build-1"}"#) == "build-1")
        #expect(SurfaceStore.peekID(#"{"id" : "a.b"}"#) == "a.b")
        #expect(SurfaceStore.peekID(#"{"title":"x"}"#) == nil)
    }
}

/// Command lenses' readings (CommandLenses).
struct CommandLensTests {
    @Test func whichLens() {
        #expect(CommandLenses.kind(for: "git status") == .gitStatus)
        #expect(CommandLenses.kind(for: "git -C repo status -s") == .gitStatus)
        #expect(CommandLenses.kind(for: "cd repo && git status") == .gitStatus)
        #expect(CommandLenses.kind(for: "git log") == nil)
        #expect(CommandLenses.kind(for: "RUST_LOG=1 cargo build") == .diagnostics)
        #expect(CommandLenses.kind(for: "/usr/bin/time swift build") == .diagnostics)
        #expect(CommandLenses.kind(for: "rg -n foo") == .search)
        #expect(CommandLenses.kind(for: "git grep -n foo") == .search)
        #expect(CommandLenses.kind(for: "make 2>&1 | tee log") == nil)  // a pipe's last command printed it
        #expect(CommandLenses.kind(for: "ls") == nil)
        #expect(CommandLenses.parseSetting("git-status,search") == [.gitStatus, .search])
        #expect(CommandLenses.parseSetting("true") == Set(CommandLenses.Kind.allCases))
        #expect(CommandLenses.parseSetting("false") == [])
        #expect(CommandLenses.parseSetting("bogus") == nil)
        #expect(CommandLenses.settingValue([.diagnostics]) == "diagnostics")
    }

    @Test func gitStatusLong() {
        let out = """
        On branch main
        Changes to be committed:
          (use "git restore --staged <file>..." to unstage)
                new file:   src/new.swift
                renamed:    old.txt -> moved.txt

        Changes not staged for commit:
          (use "git add <file>..." to update what will be committed)
                modified:   README.md
                deleted:    gone.c
                modified:   vendor/lib (new commits)

        Untracked files:
          (use "git add <file>..." to include in what will be committed)
                "sp ace.txt"
                notes/

        no changes added to commit (use "git add" and/or "git commit -a")
        """
        let items = CommandLenses.gitStatus(out, short: false)
        #expect(items.map(\.path) == ["src/new.swift", "moved.txt", "README.md", "gone.c", "vendor/lib", "sp ace.txt", "notes/"])
        #expect(items.map(\.tag) == ["new file", "renamed", "modified", "deleted", "modified", "untracked", "untracked"])
        #expect(CommandLenses.lens(command: "git status", output: out, enabled: [.gitStatus])?.summary == "7 files")
    }

    @Test func gitStatusShort() {
        let items = CommandLenses.gitStatus(" M a.txt\nMM b.txt\n?? c.txt\nR  d -> e\nUU f.txt\n!! ignored\n", short: true)
        #expect(items.map(\.path) == ["a.txt", "b.txt", "b.txt", "c.txt", "e", "f.txt"])
        #expect(items.map(\.group) == ["Not Staged", "Staged", "Not Staged", "Untracked", "Staged", "Conflicts"])
        #expect(CommandLenses.unquote(#""caf\303\251 \"x\".txt""#) == "café \"x\".txt")
    }

    @Test func diagnostics() {
        let out = """
        Sources/A.swift:12:7: error: cannot find 'x' in scope
        Sources/A.swift:3:1: warning: unused variable
        main.c:4:10: fatal error: 'nope.h' file not found
        src/app.ts(3,5): error TS2322: Type 'string' is not assignable to type 'number'.
        warning: unused import
          --> src/lib.rs:1:5
        error[E0425]: cannot find value `y` in this scope
         --> src/main.rs:2:13
          |
        error: could not compile `demo` due to previous error
        Sources/A.swift:12:7: error: cannot find 'x' in scope
        """
        let items = CommandLenses.diagnostics(out, go: false)
        #expect(items.map(\.tag) == ["error", "error", "error", "error", "warning", "warning"])
        #expect(items.map(\.path) == ["Sources/A.swift", "main.c", "src/app.ts", "src/main.rs", "Sources/A.swift", "src/lib.rs"])
        #expect(items[0].line == 12 && items[0].column == 7)
        #expect(items[3].label == "E0425: cannot find value `y` in this scope")
        let summary = CommandLenses.lens(command: "swift build", output: out, enabled: [.diagnostics])?.summary
        #expect(summary == "4 errors, 2 warnings")
        let go = CommandLenses.diagnostics("./main.go:7:2: undefined: foo\n", go: true)
        #expect(go.first?.path == "./main.go" && go.first?.tag == "error")
        #expect(CommandLenses.lens(command: "swift build", output: "Build complete!\n", enabled: [.diagnostics]) == nil)
    }

    @Test func search() {
        let flat = CommandLenses.search("src/a.c:12:  int needle = 1;\nsrc/b.c:3:5:needle()\n")
        #expect(flat.map(\.path) == ["src/a.c", "src/b.c"])
        #expect(flat.map(\.line) == [12, 3] && flat[1].column == 5 && flat[0].label == "int needle = 1;")
        // rg on a terminal: a heading, then its matches; context lines aren't matches.
        let headed = CommandLenses.search("src/a.c\n12:needle\n13-context\n\nsrc/b.c\n4:needle too\n")
        #expect(headed.map(\.path) == ["src/a.c", "src/b.c"])
        #expect(headed.map(\.line) == [12, 4])
        #expect(CommandLenses.lens(command: "rg needle", output: "src/a.c\n12:needle\n", enabled: [.search])?.summary == "1 match · 1 file")
        #expect(CommandLenses.lens(command: "rg needle", output: "src/a.c\n12:needle\n", enabled: [.diagnostics]) == nil)
    }
}
