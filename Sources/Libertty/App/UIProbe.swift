import AppKit
import WebKit
import CoreGraphics
import LiberttyCore

/// `Libertty --ui-probe SCRIPT OUTDIR [--persist]`: run the real app off screen and
/// replay a script of real AppKit events at it, taking PNGs as it goes
/// (ELN's shot, GoRex's ui.Tester). The app never activates, so keystrokes
/// meant for other apps stay there.
///
/// Steps, one per line (`#` comments):
///   key:SPEC        a key press: `a`, `enter`, `shift+2`, `cmd+d`, `ctrl+c`, `up`
///   type:TEXT       text as key events (US layout for shifted symbols)
///   click:x,y       left click at content coordinates from the top-left (it
///                   prints what it hit). A click that opens something modal —
///                   an alert, a menu — waits on it, and so does the script.
///   click:LABEL     the same on the button so titled (or tooltipped), or
///                   the text field with that placeholder, wherever it is
///   tab:new         open a tab (⌘T goes through the app delegate, which a
///                   probe doesn't have); tab:N selects tab N
///   wait:SECONDS
///   shot:NAME.png   capture the window into OUTDIR
///   expect:TEXT     every pane's text must contain TEXT (else FAIL)
///   expect-not:TEXT none may
///   expect-palette:TEXT  the open palette's first row contains TEXT
///   expect-scope:TEXT    the open palette's chips, e.g. `[All] Panes`, contain TEXT
///   expect-tab:TEXT      a sidebar row (name, detail, pane count) contains TEXT
///   workspace:new[:NAME]  a workspace of its own; workspace:N shows workspace N; workspace:close ends the one in front
///   expect-workspace:TEXT the workspaces' names, the one showing in [brackets], contain TEXT
///                         (`=TEXT`: are exactly TEXT)
///   expect-tab-count:N    the window (its workspace in front) has N tabs
///   expect-shown:N[:TEXT] the sidebar's filters leave N rows showing (each containing TEXT)
///   action-now:A          an action, not waiting for what it starts (shots of an animation)
///   expect-unmoved:here   the focused pane is where it was on the screen at the last one, same size
///   expect-regrids:N      the focused pane changed its grid N times since the last expect-regrids
///   metrics:LABEL         print the focused pane's text size, cells, scale, grid, grid changes
///   motion:on|off         animations as the app runs them (a probe starts with them off)
///   update:install|later  Libertty ▸ Check for Updates…, its dialog answered (run from an app bundle)
///   expect-app-version:V  the app bundle on disk is version V
///   reload:config         Libertty ▸ Reload Configuration
///   appearance:light|dark the app's appearance, as the system's switch sets it
///   expect-font:SIZE      the focused pane's text size, in points
///   expect-background:#RRGGBB  the focused pane's background (its theme's)
///   undo:go               Edit ▸ Undo (a probe has no menu for ⌘Z to reach)
///   redo:go               Edit ▸ Redo
///   expect-panes:N        the tab in front has N panes in its split
///   focus-event:in|out    the focused pane gains or loses the keyboard, as its program hears it
///   expect-searching:N    N panes of the tab in front (parked ones too) have a search open
///                         (a probe's window is never key, so focus never comes on its own)
///   open:PATH[:LINE]      show a file in a tab (as `+open` does); edit:PATH in the editor
///   editor-wait:go        until the document in front's editor is up (it loads in its own process)
///   editor-insert:TEXT    put TEXT at the editor's cursor (`type:` sends real keys)
///   editor-save:go        File ▸ Save
///   expect-editor:TEXT    the editor holds TEXT; expect-dirty:yes|no its unsaved state
///   expect-file:PATH=TEXT the file on disk contains TEXT (`\n` for a newline)
///   shell:COMMAND         run COMMAND (sh -c), as another program changing files would
///   sheet:BUTTON          press BUTTON on the sheet over the window (Save, Don't Save, Cancel)
///   expect-sheet:yes|no   whether a sheet is up
///   wait-edit:TOKEN:PATH  open PATH in the editor as `+open --wait` does, waited on as TOKEN
///   expect-closed:TOKEN   the editor waited on as TOKEN has said it closed
///   page-wait:go          until the block (or page) in front has drawn
///   expect-page:TEXT      its text shows TEXT; expect-page-not:TEXT doesn't
///   page-js:CODE [==> TEXT] run CODE (an expression; awaited) in the page; its value contains TEXT
///   page-click:TEXT       click its first button, chip or row whose text (or tooltip) is TEXT
///                         (`css:SELECTOR`: the first element matching it)
///                         (else the first that contains it)
///   page-type:SELECTOR=TEXT  type TEXT into the field SELECTOR finds (`textarea`, `.dialog .field`)
///   expect-shell:COMMAND ==> TEXT  COMMAND's output (sh -c) contains TEXT
///   browser:OP ARG ==> TEXT   what `libertty +browser OP ARG` would do here; its answer contains
///                         TEXT (`!TEXT`: it failed with TEXT). Without ` ==> `, just do it.
///   bar:TEXT              type TEXT in the browser's address bar and press Return
///   roundtrip:            save this window's layout and build a window from it: same workspaces, same parked panes
///   expect-float:yes|no  whether the tab in front shows a floating pane card (Float Pane)
///   expect-strip:TEXT    a tab along the top (`tab-bar = top`) is named TEXT
///   action:ACTION        perform a keybind action (`libertty +list-actions`), e.g. move_surface_to_new_tab;
///                        ACTION,ACTION… performs them one right after the other (a key pressed twice)
///   expect-windows:N     the probe has N windows (Move … to New Window opens them, off screen)
///   expect-other:TEXT    a sidebar row of the newest other window contains TEXT, or its panes' text does
///   take-tab:N           tab N of the newest other window moves back here, at the end (as dropped on the sidebar)
///   expect-subtitle:TEXT the window's subtitle (the most urgent program state) contains TEXT
///   hover:N              the pointer comes onto pane N of the tab in front (reading order)
///   expect-focus:N       pane N of the tab in front has the keyboard
///   expect-status:TEXT   program states (OSC 7501) as they show include each word of TEXT: e.g.
///                        `tab=blocked dock=1 inbox=0 sounds=Ping` (the tab in front's
///                        mark, the Dock badge, notifications so far, sounds so far)
enum UIProbe {
    /// Show `window` far off every screen. Being shown, a titled window is
    /// moved onto a screen if it's off them all (to the built-in display's
    /// corner, say: there for the user to see), so it moves off once shown,
    /// unseen meanwhile.
    private static func hideOffScreen(_ window: NSWindow, at origin: NSPoint) {
        window.alphaValue = 0
        window.orderFrontRegardless()
        window.setFrameOrigin(origin)
        window.alphaValue = 1
        if NSScreen.screens.contains(where: { $0.frame.intersects(window.frame) }) {
            print("ui-probe: the window is on a screen at \(window.frame.origin); stopping rather than showing it")
            exit(1)
        }
    }

    /// The focused pane's frame on the screen at the last `expect-unmoved`.
    private static var paneFrameMark: NSRect?

    /// Each pane's grid changes at its last `expect-regrids`.
    private static var regridMarks: [ObjectIdentifier: Int] = [:]

    static func run(script: String, output: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // no Dock icon, nothing in front
        Motion.forceReduced = true
        Probe.running = true

        // `@FILE`: the script is in that file (one too long for an argument,
        // or one a debugger passes on).
        let text = script.hasPrefix("@") ? (try? String(contentsOfFile: String(script.dropFirst()), encoding: .utf8)) ?? "" : script
        let steps = parse(text)
        guard !steps.isEmpty else { print("ui-probe: empty script"); exit(2) }

        // `--persist`: its shells live in (the probe's private) liberttyd, as
        // they do in the app — what needs a session ID ($LIBERTTY_SESSION).
        Persistence.setUp(wanted: CommandLine.arguments.contains("--persist"))
        // A window of its own, off screen, with a shell in a scratch folder.
        let scratch = NSTemporaryDirectory() + "libertty-ui-probe-\(getpid())"
        try? FileManager.default.createDirectory(atPath: scratch, withIntermediateDirectories: true)
        let controller: TerminalWindowController
        do {
            controller = try TerminalWindowController(config: Config(), cols: 80, rows: 24)
            try controller.start(command: nil, workingDirectory: scratch)
        } catch {
            print("ui-probe: couldn't open a window: \(error)")
            exit(1)
        }
        let window = controller.window!
        PluginHost.shared.frontController = { [weak controller] in controller }
        hideOffScreen(window, at: NSPoint(x: -20000, y: -20000))
        window.makeKey()
        // Wait for the shell's first prompt (whatever it looks like):
        // keystrokes sent before it is interactive can be lost.
        let deadline = Date().addingTimeInterval(6)
        let pane = controller.focusedTerminal
        while Date() < deadline {
            pump(0.1)
            if !pane.session.scrollbackText().trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { break }
        }
        pump(0.4)

        var failures = 0
        // Windows Move … to New Window opens: off screen too, never in front.
        var others: [TerminalWindowController] = []
        TerminalWindowController.openWindowForTab = { tab, source, _ in
            tab.restoredWorkspace = nil
            let other = TerminalWindowController(restoring: [tab], selected: 0, frame: nil, showSidebar: true,
                                                 showInspector: false, config: Config())
            other.markRestored(unstarted: [])
            if let w = other.window { hideOffScreen(w, at: NSPoint(x: -20000, y: -21000)) }
            try? other.start()
            others.append(other)
            return other
        }
        // `libertty +split` and `+move-pane` from its panes' shells, to this
        // probe (requests name its private liberttyd's socket).
        let paneRequests = DistributedNotificationCenter.default().addObserver(
            forName: RemoteControl.notification, object: nil, queue: .main) { note in
            guard let info = note.userInfo as? [String: String], RemoteControl.isForUs(info) else { return }
            _ = PaneRequests.handle(info, in: [controller] + others)
        }
        defer { DistributedNotificationCenter.default().removeObserver(paneRequests) }
        // `+open --wait`'s side of it: the editors that said they closed.
        var closedEditors: Set<String> = []
        let closedObserver = DistributedNotificationCenter.default().addObserver(forName: EditorWait.closed, object: nil, queue: .main) { note in
            if let token = note.userInfo?["token"] as? String { closedEditors.insert(token) }
        }
        defer { DistributedNotificationCenter.default().removeObserver(closedObserver) }
        for step in steps {
            switch step {
            case .key(let spec):
                // To whatever has the keyboard: the palette while it's open.
                if !press(spec, in: CommandPalette.openPanel ?? window) {
                    print("FAIL  ui-probe key: unknown key \(spec)")
                    failures += 1
                }
                pump(0.15)
            case .type(let text):
                for spec in text.map(String.init) { _ = press(spec, in: CommandPalette.openPanel ?? window) }
                pump(0.35)
            case .click(let x, let y):
                click(x: x, y: y, in: window)
                pump(0.2)
            case .clickLabeled(let label):
                // Where it is now, so the script doesn't depend on layout —
                // once it's really there: a column still sliding in has its
                // controls placed under whatever it will uncover.
                guard let center = reachable(label, in: window) else {
                    let blocker = find(label, in: window.contentView).flatMap { control -> String? in
                        guard let content = window.contentView else { return nil }
                        let frame = control.convert(control.bounds, to: content)
                        let center = NSPoint(x: frame.midX, y: frame.midY)
                        let hit = content.hitTest(center).map { String(describing: type(of: $0)) } ?? "nothing"
                        return "\(hit) (it's at \(frame.integral) in \(content.bounds.size); "
                            + "inspector \(controller.isInspectorShown ? "shown" : "hidden"))"
                    }
                    print("FAIL  ui-probe click: \(label) " + (blocker.map { "is covered by \($0)" } ?? "isn't on screen"))
                    failures += 1
                    continue
                }
                click(x: center.x, y: center.y, in: window)
                pump(0.2)
            case .wait(let seconds):
                pump(seconds)
            case .tab(let which):
                if which == "new" || which == "here" {
                    // "here": as ⌘T does, in the focused pane's folder.
                    if controller.newTab(workingDirectory: which == "new" ? scratch : nil) == nil {
                        print("FAIL  ui-probe tab: couldn't open one")
                        failures += 1
                    }
                } else if let n = Int(which), n >= 1, n <= controller.tabs.count {
                    controller.select(controller.tabs[n - 1])
                } else {
                    print("FAIL  ui-probe tab: no tab \(which)")
                    failures += 1
                }
                pump(0.5)
            case .shot(let name):
                capture(window, to: output + "/" + name)
            case .size(let width, let height):
                var frame = window.frame
                frame.size = NSSize(width: width, height: height)
                window.setFrame(frame, display: true)
                pump(0.4)
            case .expect(let text):
                // Newline-joined: a match may not span two panes' text.
                let all = screenText(controller)
                if all.contains(text) {
                    print("ok    ui-probe expect \(text)")
                } else {
                    print("FAIL  ui-probe expect: no \(text) on screen; screen ends: …\(all.suffix(80))")
                    failures += 1
                }
            case .expectPalette(let text):
                // The palette's first row, while it's open.
                let first = CommandPalette.shownRows.map { $0.first ?? "(an empty palette)" } ?? "(no palette open)"
                if first.contains(text) {
                    print("ok    ui-probe palette shows \(text)")
                } else {
                    print("FAIL  ui-probe palette: first row is \(first.debugDescription), not \(text)")
                    failures += 1
                }
            case .expectStatus(let text):
                // Word for word: `dock=1` isn't `dock=10`, `sounds=` is none.
                let summary = controller.statusSummary
                let shown = Set(summary.split(separator: " "))
                if text.split(separator: " ").allSatisfy(shown.contains) {
                    print("ok    ui-probe status shows \(text)")
                } else {
                    print("FAIL  ui-probe status: no \(text) in \(summary)")
                    failures += 1
                }
            case .expectTab(let text):
                // The sidebar rows: name, detail and pane count, as shown.
                let rows = controller.sidebarRows
                if rows.contains(where: { $0.contains(text) }) {
                    print("ok    ui-probe tab shows \(text)")
                } else {
                    print("FAIL  ui-probe tab: no row shows \(text); rows: \(rows)")
                    failures += 1
                }
            case .workspace(let which):
                if which == "new" || which.hasPrefix("new:") {
                    let name = which.hasPrefix("new:") ? String(which.dropFirst(4)) : ""
                    if !controller.newWorkspace(named: name) { print("FAIL  ui-probe workspace: couldn't make one"); failures += 1 }
                } else if which == "close" {
                    controller.closeWorkspace(at: controller.activeWorkspace)
                } else if let n = Int(which), n >= 1, n <= controller.workspaceNames.count {
                    controller.switchWorkspace(to: n - 1)
                } else {
                    print("FAIL  ui-probe workspace: no \(which)")
                    failures += 1
                }
                pump(0.5)
            case .roundtrip:
                guard let saved = controller.savedState() else { print("FAIL  ui-probe roundtrip: nothing to save"); failures += 1; continue }
                let live = Set(controller.persistentSessionIDs)
                guard let copy = TerminalWindowController.restore(saved, live: live, config: Config()) else {
                    print("FAIL  ui-probe roundtrip: the saved window didn't come back")
                    failures += 1
                    continue
                }
                let parked = { (c: TerminalWindowController) in c.everyTab.map { $0.parked.count } }
                let same = copy.workspaceNames == controller.workspaceNames && copy.activeWorkspace == controller.activeWorkspace
                    && copy.workspaceTabs.map(\.count) == controller.workspaceTabs.map(\.count)
                    && parked(copy) == parked(controller)
                    && copy.everyTab.map { $0.parked.map(\.showsCard) } == controller.everyTab.map { $0.parked.map(\.showsCard) }
                if same {
                    print("ok    ui-probe roundtrip \(copy.workspaceNames), parked \(parked(copy))")
                } else {
                    print("FAIL  ui-probe roundtrip: \(copy.workspaceNames)/\(copy.activeWorkspace)/\(copy.workspaceTabs.map(\.count))/\(parked(copy)) "
                          + "vs \(controller.workspaceNames)/\(controller.activeWorkspace)/\(controller.workspaceTabs.map(\.count))/\(parked(controller))")
                    failures += 1
                }
            case .open(let path, let line, let edit):
                // A block's address opens as itself (`open:libertty-block://screen?own=1`).
                let url = path.hasPrefix(Blocks.scheme + "://") ? URL(string: path)! : URL(fileURLWithPath: path)
                controller.openDocument(url, line: line, edit: edit ? true : nil)
                pump(0.4)
            case .editorWait:
                let deadline = Date().addingTimeInterval(10)
                while controller.selectedDocument?.isEditorReady != true, Date() < deadline { pump(0.1) }
                if controller.selectedDocument?.isEditorReady == true {
                    pump(0.2)
                    print("ok    ui-probe editor ready")
                } else {
                    print("FAIL  ui-probe editor: never came up (is vendor/codemirror built?)")
                    failures += 1
                }
            case .editorJS(let script):
                // Diagnostics: what the page says (not a check).
                var answer: Any?
                var answered = false
                controller.selectedDocument?.editorEvaluate(script) { answer = $0; answered = true }
                let deadline = Date().addingTimeInterval(3)
                while !answered, Date() < deadline { pump(0.05) }
                print("js    \(script.prefix(60)) => \(answer.map { "\($0)" } ?? "nil")")
            case .editorInsert(let text):
                controller.selectedDocument?.editorInsert(text)
                pump(0.3)
            case .editorSave:
                var done: Bool?
                controller.selectedDocument?.save { done = $0 }
                let deadline = Date().addingTimeInterval(5)
                while done == nil, Date() < deadline { pump(0.05) }
                if done == true { print("ok    ui-probe saved") } else { print("FAIL  ui-probe save: \(done.map(String.init) ?? "no answer")"); failures += 1 }
                pump(0.3)
            case .expectEditor(let text):
                var shown: String?
                var answered = false
                controller.selectedDocument?.editorText { shown = $0; answered = true }
                let deadline = Date().addingTimeInterval(3)
                while !answered, Date() < deadline { pump(0.05) }
                if shown?.contains(text) == true {
                    print("ok    ui-probe editor shows \(text)")
                } else {
                    print("FAIL  ui-probe editor: no \(text.debugDescription) in \(String((shown ?? "(nothing)").prefix(120)).debugDescription)")
                    failures += 1
                }
            case .expectDirty(let want):
                let dirty = controller.selectedDocument?.hasUnsavedChanges == true
                if dirty == want {
                    print("ok    ui-probe \(want ? "unsaved changes" : "saved")")
                } else {
                    print("FAIL  ui-probe dirty: \(dirty), wanted \(want)")
                    failures += 1
                }
            case .expectFile(let path, let text):
                let contents = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
                if contents.contains(text) {
                    print("ok    ui-probe file has \(text.debugDescription)")
                } else {
                    print("FAIL  ui-probe file: \(path) has \(String(contents.prefix(120)).debugDescription), not \(text.debugDescription)")
                    failures += 1
                }
            case .sheet(let title):
                func button(in view: NSView?) -> NSButton? {
                    guard let view else { return nil }
                    if let b = view as? NSButton, b.title == title { return b }
                    return view.subviews.lazy.compactMap(button(in:)).first
                }
                if let sheet = window.attachedSheet, let b = button(in: sheet.contentView) {
                    b.performClick(nil)
                    pump(0.5)
                } else {
                    print("FAIL  ui-probe sheet: \(window.attachedSheet == nil ? "none up" : "no \(title) button")")
                    failures += 1
                }
            case .expectSheet(let want):
                let up = window.attachedSheet != nil
                if up == want { print("ok    ui-probe sheet \(up ? "up" : "gone")") } else {
                    print("FAIL  ui-probe sheet: \(up ? "up" : "none"), wanted \(want ? "one" : "none")")
                    failures += 1
                }
            case .waitEdit(let token, let path):
                controller.openDocument(URL(fileURLWithPath: path), edit: true, waitToken: token)
                pump(0.4)
            case .expectClosed(let token):
                let deadline = Date().addingTimeInterval(3)
                while !closedEditors.contains(token), Date() < deadline { pump(0.05) }
                if closedEditors.contains(token) { print("ok    ui-probe editor \(token) closed") } else {
                    print("FAIL  ui-probe editor \(token): no word that it closed")
                    failures += 1
                }
            case .bar(let text):
                guard let bar = controller.selectedDocument?.browserBar else {
                    print("FAIL  ui-probe bar: no browser in front")
                    failures += 1
                    continue
                }
                bar.field.stringValue = text
                bar.onNavigate?(text)
                pump(0.8)
            case .browser(let op, let arg, let want):
                let token = UUID().uuidString
                let out = FileManager.default.temporaryDirectory.appendingPathComponent("libertty-browser-\(token)")
                var answer: Bool?
                let center = DistributedNotificationCenter.default()
                let observer = center.addObserver(forName: BrowserAutomation.replied, object: nil, queue: .main) { note in
                    if note.userInfo?["token"] as? String == token { answer = note.userInfo?["ok"] as? String == "1" }
                }
                var info = ["op": op, "token": token, "out": out.path]
                if op == "type" { info["arg"] = arg.replacingOccurrences(of: " | ", with: "\u{1f}") }
                else if op == "screenshot" { info["file"] = arg } else { info["arg"] = arg }
                BrowserAutomation.handle(info, in: controller)
                let deadline = Date().addingTimeInterval(8)
                while answer == nil, Date() < deadline { pump(0.05) }
                center.removeObserver(observer)
                let said = (try? String(contentsOf: out, encoding: .utf8)) ?? ""
                try? FileManager.default.removeItem(at: out)
                pump(0.4)
                guard let want else { continue }
                let failed = want.hasPrefix("!")
                let text = failed ? String(want.dropFirst()) : want
                if answer == !failed, text.isEmpty || said.contains(text) {
                    print("ok    ui-probe browser \(op) \(failed ? "refused" : "says") \(text)")
                } else {
                    print("FAIL  ui-probe browser \(op): \(answer.map { $0 ? "ok" : "failed" } ?? "no answer"), said \(String(said.prefix(200)).debugDescription)")
                    failures += 1
                }
            case .pageWait:
                let deadline = Date().addingTimeInterval(10)
                var ready = false
                while !ready, Date() < deadline {
                    pump(0.2)
                    ready = (pageEvaluate(controller, "document.readyState === 'complete' && document.body.innerText.trim().length > 0 && !document.body.innerText.includes('Reading…')") as? Bool) == true
                }
                if ready { print("ok    ui-probe page up"); pump(0.3) } else { print("FAIL  ui-probe page: never drew"); failures += 1 }
            case .expectPage(let text, let want):
                let deadline = Date().addingTimeInterval(want ? 3 : 0.5)
                var has = false
                repeat {
                    has = (pageEvaluate(controller, "document.body.innerText.includes(\(jsLiteral(text)))") as? Bool) == true
                    if has == want { break }
                    pump(0.15)
                } while Date() < deadline
                if has == want {
                    print("ok    ui-probe page \(want ? "shows" : "hasn't") \(text)")
                } else {
                    let shown = (pageEvaluate(controller, "document.body.innerText") as? String) ?? "(nothing)"
                    print("FAIL  ui-probe page: \(want ? "no" : "still") \(text.debugDescription); it shows \(String(shown.prefix(240)).debugDescription)")
                    failures += 1
                }
            case .pageClick(let text):
                let script = """
                    (function(t){if(t.startsWith('css:')){const e=document.querySelector(t.slice(4));if(!e)return false;e.click();return true;}
                    const all=[...document.querySelectorAll('button, .row, .chip, label')].filter(e=>e.offsetParent!==null);
                    const exact=all.find(e=>e.title===t||e.textContent.trim()===t)||all.find(e=>e.textContent.includes(t));
                    if(!exact)return false;exact.click();return true;})(\(jsLiteral(text)))
                    """
                if (pageEvaluate(controller, script) as? Bool) == true { pump(0.5) } else {
                    print("FAIL  ui-probe page-click: nothing says \(text.debugDescription)")
                    failures += 1
                }
            case .pageType(let selector, let text):
                let script = """
                    (function(s,t){const e=document.querySelector(s);if(!e)return false;e.focus();e.value=t;
                    e.dispatchEvent(new Event('input',{bubbles:true}));return true;})(\(jsLiteral(selector)), \(jsLiteral(text)))
                    """
                if (pageEvaluate(controller, script) as? Bool) == true { pump(0.2) } else {
                    print("FAIL  ui-probe page-type: no \(selector)")
                    failures += 1
                }
            case .pageJS(let script, let want):
                // Its value as text (a promise's once it settles): JSON for objects.
                let wrapped = "const v = await (\(script)); return typeof v === 'string' ? v : JSON.stringify(v);"
                var answer: Any?
                var answered = false
                controller.selectedDocument?.pageCall(wrapped) { answer = $0; answered = true }
                // A promise may wait for a kernel or a server to start.
                let deadline = Date().addingTimeInterval(60)
                while !answered, Date() < deadline { pump(0.03) }
                let said = answer as? String ?? "(no answer)"
                if let want {
                    if said.contains(want) { print("ok    ui-probe page-js says \(want)") } else {
                        print("FAIL  ui-probe page-js: \(script) said \(String(said.prefix(200)).debugDescription), not \(want.debugDescription)")
                        failures += 1
                    }
                }
                pump(0.2)
            case .expectShell(let command, let text):
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", command]
                let out = Pipe()
                p.standardOutput = out
                p.standardError = out
                try? p.run()
                let data = out.fileHandleForReading.readDataToEndOfFile()
                p.waitUntilExit()
                let said = String(decoding: data, as: UTF8.self)
                if said.contains(text) { print("ok    ui-probe shell says \(text)") } else {
                    print("FAIL  ui-probe shell: \(command) said \(String(said.prefix(200)).debugDescription), not \(text.debugDescription)")
                    failures += 1
                }
            case .shell(let command):
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/bin/sh")
                p.arguments = ["-c", command]
                try? p.run()
                p.waitUntilExit()
                pump(0.6)
            case .undo:
                let undone = MainActor.assumeIsolated { () -> Bool in
                    let manager = CloseUndo.shared.manager
                    guard manager.canUndo else { return false }
                    manager.undo()
                    return true
                }
                if !undone {
                    print("FAIL  ui-probe undo: nothing to undo")
                    failures += 1
                }
                pump(0.5)
            case .focusEvent(let focused):
                controller.focusedTerminal.session.reportFocus(focused)
                pump(0.3)
            case .expectSearching(let n):
                let count = controller.selectedTab.everyPane.filter { $0.session.searchResult.active }.count
                if count == n { print("ok    ui-probe \(n) panes searching") } else {
                    print("FAIL  ui-probe searching: \(count) panes, not \(n)")
                    failures += 1
                }
            case .expectPanes(let n):
                let count = controller.selectedPaneCount
                if count == n { print("ok    ui-probe \(n) panes") } else {
                    print("FAIL  ui-probe panes: \(count), not \(n)")
                    failures += 1
                }
            case .redo:
                let redone = MainActor.assumeIsolated { () -> Bool in
                    let manager = CloseUndo.shared.manager
                    guard manager.canRedo else { return false }
                    manager.redo()
                    return true
                }
                if !redone {
                    print("FAIL  ui-probe redo: nothing to redo")
                    failures += 1
                }
                pump(0.5)
            case .hover(let n):
                let panes = controller.selectedTab.container?.views.compactMap { $0 as? TerminalView } ?? []
                guard panes.indices.contains(n - 1),
                      let event = NSEvent.enterExitEvent(with: .mouseEntered, location: .zero, modifierFlags: [],
                                                         timestamp: 0, windowNumber: window.windowNumber, context: nil,
                                                         eventNumber: 0, trackingNumber: 0, userData: nil) else {
                    print("FAIL  ui-probe hover: no pane \(n)")
                    failures += 1
                    break
                }
                panes[n - 1].mouseEntered(with: event)
                pump(0.2)
            case .expectFocus(let n):
                let panes = controller.selectedTab.container?.views.compactMap { $0 as? TerminalView } ?? []
                // 0: none of them (the keyboard is in a field: the find bar, a filter).
                let focused = panes.firstIndex { $0 === window.firstResponder }.map { $0 + 1 } ?? 0
                if focused == n {
                    print("ok    ui-probe " + (n == 0 ? "no pane has the keyboard" : "pane \(n) has the keyboard"))
                } else {
                    print("FAIL  ui-probe focus: pane \(focused == 0 ? "none" : String(focused)), not \(n)")
                    failures += 1
                }
            case .expectSubtitle(let text):
                let subtitle = window.subtitle
                if subtitle.contains(text) {
                    print("ok    ui-probe subtitle says \(text)")
                } else {
                    print("FAIL  ui-probe subtitle: no \(text) in \"\(subtitle)\"")
                    failures += 1
                }
            case .update(let install):
                // Libertty ▸ Check for Updates…, its dialog answered (Install
                // and Restart, or Later); up to a minute for the download.
                MainActor.assumeIsolated {
                    let updates = UpdateController.shared
                    updates.probeAnswer = install ? .alertFirstButtonReturn : .alertSecondButtonReturn
                    updates.checkForUpdates(nil)
                    let deadline = Date().addingTimeInterval(60)
                    repeat { pump(0.1) } while updates.isBusy && Date() < deadline
                    for line in updates.probeLog { print("update: \(line.replacingOccurrences(of: "\n", with: " "))") }
                    if updates.isBusy {
                        print("FAIL  ui-probe update: still under way after 60 s")
                        failures += 1
                    }
                }
            case .expectAppVersion(let version):
                // The bundle on disk now (an install replaced it).
                let info = NSDictionary(contentsOf: Bundle.main.bundleURL.appendingPathComponent("Contents/Info.plist"))
                let found = info?["CFBundleShortVersionString"] as? String ?? "none"
                if found == version {
                    print("ok    ui-probe app is \(version)")
                } else {
                    print("FAIL  ui-probe app: \(found), not \(version)")
                    failures += 1
                }
            case .metrics(let label):
                // The focused pane as drawn: its text size, cells, layer and drawable;
                // what has the keyboard; the window's title and content area.
                let responder = window.firstResponder.map { String(describing: type(of: $0)) } ?? "none"
                print("metrics \(label): \(controller.focusedTerminal.metricsSummary) responder \(responder) "
                      + "title \(window.titleVisibility == .visible ? "shown" : "hidden") subtitle '\(window.subtitle)' "
                      + "layout \(Int(window.contentLayoutRect.width))x\(Int(window.contentLayoutRect.height))")
            case .motion(let on):
                // Animations as the user's app runs them (a probe has them off).
                Motion.forceReduced = !on
            case .expectUnmoved:
                // The focused pane where it was on the screen at the last of
                // these, to the point (the first one notes it).
                let pane = controller.focusedTerminal
                let frame = window.convertToScreen(pane.convert(pane.bounds, to: nil))
                let size = "\(Int(frame.width))x\(Int(frame.height)) at \(Int(frame.minX)),\(Int(frame.minY))"
                if let last = paneFrameMark, last != frame {
                    let was = "\(Int(last.width))x\(Int(last.height)) at \(Int(last.minX)),\(Int(last.minY))"
                    print("FAIL  ui-probe pane moved: \(size), was \(was) (window \(Int(window.frame.width)) wide)")
                    failures += 1
                } else {
                    print("ok    ui-probe pane \(size) (window \(Int(window.frame.width)) wide)")
                }
                paneFrameMark = frame
            case .reload:
                ConfigStore.shared.reloadByRequest()
                pump(0.3)
            case .appearance(let dark):
                // As the system's switching would (`theme = light:A,dark:B` follows it).
                NSApp.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                pump(0.4)
            case .expectBackground(let hex):
                // What the pane draws behind its text (its dimming layer takes the same).
                let bg = controller.focusedTerminal.backgroundHex
                if bg == hex {
                    print("ok    ui-probe background \(hex)")
                } else {
                    print("FAIL  ui-probe background: \(bg), not \(hex)")
                    failures += 1
                }
            case .expectFont(let size):
                let shown = Double(controller.focusedTerminal.fontSize)
                if shown == size {
                    print("ok    ui-probe font \(size)")
                } else {
                    print("FAIL  ui-probe font: \(shown), not \(size)")
                    failures += 1
                }
            case .expectRegrids(let n):
                // Grid changes of the focused pane since the last of these (for it).
                let pane = controller.focusedTerminal
                let since = pane.regridCount - (regridMarks[ObjectIdentifier(pane)] ?? 0)
                regridMarks[ObjectIdentifier(pane)] = pane.regridCount
                if since == n {
                    print("ok    ui-probe \(n) grid changes")
                } else {
                    print("FAIL  ui-probe grid changes: \(since), not \(n)")
                    failures += 1
                }
            case .actionNow(let text):
                // Without waiting for it to settle: shots of a slide in progress.
                guard let action = Action(text) else {
                    print("FAIL  ui-probe action-now: unknown \(text)")
                    failures += 1
                    break
                }
                ActionDispatcher.perform(action, in: controller.focusedTerminal, controller: controller)
            case .action(let text):
                let actions = text.split(separator: ",").map { Action(String($0)) }
                guard !actions.isEmpty, actions.allSatisfy({ $0 != nil }) else {
                    print("FAIL  ui-probe action: unknown \(text)")
                    failures += 1
                    break
                }
                for action in actions.compactMap({ $0 }) {
                    ActionDispatcher.perform(action, in: controller.focusedTerminal, controller: controller)
                }
                pump(0.6)  // a pane slides out of its split
            case .expectWindows(let n):
                let count = 1 + others.filter { $0.window?.isVisible == true }.count
                if count == n {
                    print("ok    ui-probe \(n) windows")
                } else {
                    print("FAIL  ui-probe windows: \(count), not \(n)")
                    failures += 1
                }
            case .expectOther(let text):
                guard let other = others.last(where: { $0.window?.isVisible == true }) else {
                    print("FAIL  ui-probe other window: there's none")
                    failures += 1
                    break
                }
                let rows = other.sidebarRows
                if rows.contains(where: { $0.contains(text) }) || screenText(other).contains(text) {
                    print("ok    ui-probe other window shows \(text)")
                } else {
                    print("FAIL  ui-probe other window: no \(text); rows: \(rows)")
                    failures += 1
                }
            case .takeTab(let n):
                guard let other = others.last(where: { $0.window?.isVisible == true }), let tab = other.tab(at: n - 1),
                      controller.canTake(tab, from: other) else {
                    print("FAIL  ui-probe take-tab: no tab \(n) to take")
                    failures += 1
                    break
                }
                controller.take(tab, from: other, at: controller.tabs.count)
                pump(0.4)
            case .expectShown(let n, let text):
                let shown = controller.shownSidebarRows
                if shown.count == n, text.isEmpty || shown.allSatisfy({ $0.contains(text) }) {
                    print("ok    ui-probe sidebar shows \(n) tabs" + (text.isEmpty ? "" : " with \(text)"))
                } else {
                    print("FAIL  ui-probe sidebar shows \(shown), not \(n)" + (text.isEmpty ? "" : " with \(text)"))
                    failures += 1
                }
            case .expectTabCount(let n):
                if controller.tabs.count == n {
                    print("ok    ui-probe \(n) tabs")
                } else {
                    print("FAIL  ui-probe tabs: \(controller.tabs.count), not \(n)")
                    failures += 1
                }
            case .expectWorkspace(let text):
                let names = controller.workspaceNames.enumerated().map {
                    $0.offset == controller.activeWorkspace ? "[\($0.element)]" : $0.element
                }.joined(separator: " ")
                if text.hasPrefix("=") ? names == String(text.dropFirst()) : names.contains(text) {
                    print("ok    ui-probe workspaces \(text)")
                } else {
                    print("FAIL  ui-probe workspaces: \(names), not \(text)")
                    failures += 1
                }
            case .expectFloat(let want):
                let has = controller.showsFloatingCard
                if has == want {
                    print("ok    ui-probe floating card \(want ? "shown" : "absent")")
                } else {
                    print("FAIL  ui-probe floating card: \(has ? "shown" : "absent"), wanted \(want ? "shown" : "absent")")
                    failures += 1
                }
            case .expectScope(let text):
                let chips = CommandPalette.shownScopes?.joined(separator: " ") ?? "(no palette open)"
                if chips.contains(text) {
                    print("ok    ui-probe palette chips \(text)")
                } else {
                    print("FAIL  ui-probe palette chips: \(chips), not \(text)")
                    failures += 1
                }
            case .expectStrip(let text):
                // The top tabs' names as drawn, and that they're in the bar.
                let names = controller.tabStripTitles
                if names?.contains(text) == true {
                    print("ok    ui-probe top tab \(text)")
                } else {
                    print("FAIL  ui-probe top tabs: none is \(text.debugDescription); they are \(names.map { "\($0)" } ?? "not in the bar")")
                    failures += 1
                }
            case .expectNot(let text):
                let all = screenText(controller)
                if all.contains(text) {
                    print("FAIL  ui-probe expect-not: \(text) is on screen")
                    failures += 1
                } else {
                    print("ok    ui-probe expect-not \(text)")
                }
            }
        }
        controller.close()
        print(failures == 0 ? "ui-probe: all passed" : "ui-probe: \(failures) failed")
        exit(failures == 0 ? 0 : 1)
    }

    /// What a script says in the page in front (a block, a document), waited for.
    private static func pageEvaluate(_ controller: TerminalWindowController, _ script: String) -> Any? {
        var answer: Any?
        var answered = false
        controller.selectedDocument?.editorEvaluate(script) { answer = $0; answered = true }
        let deadline = Date().addingTimeInterval(3)
        while !answered, Date() < deadline { pump(0.03) }
        return answer
    }

    /// A string as a JavaScript literal.
    private static func jsLiteral(_ s: String) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: [s]), let json = String(data: data, encoding: .utf8) else { return "\"\"" }
        return String(json.dropFirst().dropLast())
    }

    /// Every pane's text. Newline-joined, so an expectation can't match
    /// across the seam between two panes.
    private static func screenText(_ controller: TerminalWindowController) -> String {
        controller.everyTab.flatMap { $0.everyPane }.map { $0.session.scrollbackText() }.joined(separator: "\n")
    }

    private enum Step {
        case key(String), type(String), click(x: CGFloat, y: CGFloat), clickLabeled(String), wait(Double), tab(String)
        case shot(String), expect(String), expectNot(String), expectPalette(String), expectTab(String)
        case action(String), expectWindows(Int), expectOther(String), takeTab(Int), expectSubtitle(String)
        case hover(Int), expectFocus(Int)
        case expectStrip(String), expectStatus(String), expectScope(String), expectFloat(Bool), workspace(String), expectWorkspace(String), roundtrip, expectTabCount(Int), expectShown(Int, String), reload, expectFont(Double), expectBackground(String), appearance(Bool), metrics(String), motion(Bool), actionNow(String), expectRegrids(Int), update(install: Bool), expectAppVersion(String), expectUnmoved, undo, redo, expectPanes(Int), focusEvent(Bool), expectSearching(Int)
        case open(String, line: Int?, edit: Bool), editorWait, editorJS(String), editorInsert(String), editorSave
        case expectEditor(String), expectDirty(Bool), expectFile(String, String), shell(String)
        case sheet(String), expectSheet(Bool), waitEdit(token: String, path: String), expectClosed(String)
        case pageWait, expectPage(String, Bool), pageClick(String), pageType(String, String), expectShell(String, String)
        case pageJS(String, String?)
        case browser(op: String, arg: String, want: String?), bar(String)
        /// The window's frame, in points (to compare shots with another app's).
        case size(CGFloat, CGFloat)
    }

    /// Where to click the control `label` names (content coordinates from
    /// the top-left), once a click there would reach it; waits up to 3 s
    /// for layout and animations to settle.
    private static func reachable(_ label: String, in window: NSWindow) -> NSPoint? {
        let deadline = Date().addingTimeInterval(3)
        repeat {
            if let control = find(label, in: window.contentView), let content = window.contentView {
                let center = control.convert(NSPoint(x: control.bounds.midX, y: control.bounds.midY), to: content)
                if let hit = content.hitTest(center), hit === control || hit.isDescendant(of: control) {
                    return NSPoint(x: center.x, y: content.bounds.height - center.y)
                }
            }
            pump(0.1)
        } while Date() < deadline
        return nil
    }

    /// The control on screen that `label` names: a button by its title or
    /// tooltip, a text field by its placeholder. Hidden ones don't count.
    private static func find(_ label: String, in view: NSView?) -> NSView? {
        guard let view, !view.isHiddenOrHasHiddenAncestor else { return nil }
        if let button = view as? NSButton, button.title == label || button.toolTip == label { return button }
        // (A styled placeholder leaves the plain one empty.)
        if let field = view as? NSTextField, field.isEditable,
           (field.placeholderString ?? field.placeholderAttributedString?.string) == label { return field }
        for child in view.subviews {
            if let found = find(label, in: child) { return found }
        }
        return nil
    }

    private static func parse(_ script: String) -> [Step] {
        var steps: [Step] = []
        for raw in script.split(separator: "\n") {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            let parts = line.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2 else { continue }
            let (verb, arg) = (parts[0], parts[1])
            switch verb {
            case "key": steps.append(.key(arg))
            case "type": steps.append(.type(arg))
            case "click":
                let xy = arg.split(separator: ",").compactMap { Double($0) }
                steps.append(xy.count == 2 ? .click(x: xy[0], y: xy[1]) : .clickLabeled(arg))
            case "wait": steps.append(.wait(Double(arg) ?? 0))
            case "tab": steps.append(.tab(arg))
            case "shot": steps.append(.shot(arg))
            case "size":
                let parts = arg.split(separator: "x").compactMap { Double($0) }
                if parts.count == 2 { steps.append(.size(CGFloat(parts[0]), CGFloat(parts[1]))) }
            case "expect": steps.append(.expect(arg))
            case "expect-not": steps.append(.expectNot(arg))
            case "expect-palette": steps.append(.expectPalette(arg))
            case "expect-scope": steps.append(.expectScope(arg))
            case "expect-tab": steps.append(.expectTab(arg))
            case "expect-strip": steps.append(.expectStrip(arg))
            case "expect-status": steps.append(.expectStatus(arg))
            case "expect-float": steps.append(.expectFloat(arg == "yes"))
            case "workspace": steps.append(.workspace(arg))
            case "roundtrip": steps.append(.roundtrip)
            case "expect-workspace": steps.append(.expectWorkspace(arg))
            case "expect-tab-count": steps.append(.expectTabCount(Int(arg) ?? -1))
            case "expect-shown":
                let p = arg.split(separator: ":", maxSplits: 1).map(String.init)
                steps.append(.expectShown(Int(p.first ?? "") ?? -1, p.count > 1 ? p[1] : ""))
            case "action": steps.append(.action(arg))
            case "action-now": steps.append(.actionNow(arg))
            case "expect-regrids": steps.append(.expectRegrids(Int(arg) ?? -1))
            case "reload": steps.append(.reload)
            case "expect-unmoved": steps.append(.expectUnmoved)
            case "update":
                guard arg == "install" || arg == "later" else { print("ui-probe: update:install or update:later"); exit(2) }
                steps.append(.update(install: arg == "install"))
            case "expect-app-version": steps.append(.expectAppVersion(arg))
            case "metrics": steps.append(.metrics(arg))
            case "motion":
                guard arg == "on" || arg == "off" else { print("ui-probe: motion:on or motion:off"); exit(2) }
                steps.append(.motion(arg == "on"))
            case "appearance":
                guard arg == "light" || arg == "dark" else { print("ui-probe: appearance:light or appearance:dark"); exit(2) }
                steps.append(.appearance(arg == "dark"))
            case "expect-background": steps.append(.expectBackground(arg.lowercased()))
            case "expect-font": steps.append(.expectFont(Double(arg) ?? -1))
            case "expect-subtitle": steps.append(.expectSubtitle(arg))
            case "hover": steps.append(.hover(Int(arg) ?? 0))
            case "expect-focus": steps.append(.expectFocus(Int(arg) ?? 0))
            case "expect-windows": steps.append(.expectWindows(Int(arg) ?? -1))
            case "expect-other": steps.append(.expectOther(arg))
            case "take-tab": steps.append(.takeTab(Int(arg) ?? -1))
            case "undo": steps.append(.undo)
            case "redo": steps.append(.redo)
            case "expect-panes": steps.append(.expectPanes(Int(arg) ?? -1))
            case "focus-event": steps.append(.focusEvent(arg == "in"))
            case "expect-searching": steps.append(.expectSearching(Int(arg) ?? -1))
            case "open", "edit":
                var path = arg, line: Int?
                if let colon = arg.lastIndex(of: ":"), let n = Int(arg[arg.index(after: colon)...]) {
                    line = n
                    path = String(arg[..<colon])
                }
                steps.append(.open(path, line: line, edit: verb == "edit"))
            case "editor-wait": steps.append(.editorWait)
            case "editor-js": steps.append(.editorJS(arg))
            case "editor-insert": steps.append(.editorInsert(arg))
            case "editor-save": steps.append(.editorSave)
            case "expect-editor": steps.append(.expectEditor(arg))
            case "expect-dirty": steps.append(.expectDirty(arg == "yes"))
            case "expect-file":
                let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { steps.append(.expectFile(parts[0], parts[1].replacingOccurrences(of: "\\n", with: "\n").replacingOccurrences(of: "\\r", with: "\r"))) }
            case "shell": steps.append(.shell(arg))
            case "sheet": steps.append(.sheet(arg))
            case "expect-sheet": steps.append(.expectSheet(arg == "yes"))
            case "wait-edit":
                let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2 { steps.append(.waitEdit(token: parts[0], path: parts[1])) }
            case "expect-closed": steps.append(.expectClosed(arg))
            case "page-wait": steps.append(.pageWait)
            case "bar": steps.append(.bar(arg))
            case "browser":
                // ` ==> TEXT`, or a bare ` ==>` at the end (the line's trailing space is trimmed): "it worked".
                let (call, want): (String, String?) = arg.hasSuffix(" ==>") ? (String(arg.dropLast(4)), "")
                    : arg.range(of: " ==> ").map { (String(arg[..<$0.lowerBound]), String(arg[$0.upperBound...])) } ?? (arg, nil)
                let words = call.split(separator: " ", maxSplits: 1).map(String.init)
                steps.append(.browser(op: words.first ?? "", arg: words.count > 1 ? words[1] : "", want: want))
            case "expect-page": steps.append(.expectPage(arg, true))
            case "expect-page-not": steps.append(.expectPage(arg, false))
            case "page-click": steps.append(.pageClick(arg))
            case "page-type":
                let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { steps.append(.pageType(parts[0], parts[1])) }
            case "page-js":
                if let r = arg.range(of: " ==> ") { steps.append(.pageJS(String(arg[..<r.lowerBound]), String(arg[r.upperBound...]))) }
                else { steps.append(.pageJS(arg, nil)) }
            case "expect-shell":
                // ` ==> `: a command has `=` of its own (`--format=%s`).
                if let r = arg.range(of: " ==> ") { steps.append(.expectShell(String(arg[..<r.lowerBound]), String(arg[r.upperBound...]))) }
            default: break
            }
        }
        return steps
    }

    /// Keep the run loop alive so the app draws and sessions produce.
    private static func pump(_ seconds: Double) {
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    // MARK: Keys (a real NSEvent, US layout)

    /// The ANSI key codes (`kVK_ANSI_…`) of the keys that type text; the
    /// rest are in `named`.
    private static let codes: [String: UInt16] = {
        var c: [String: UInt16] = [
            "a": 0, "s": 1, "d": 2, "f": 3, "h": 4, "g": 5, "z": 6, "x": 7, "c": 8, "v": 9,
            "b": 11, "q": 12, "w": 13, "e": 14, "r": 15, "y": 16, "t": 17,
            "o": 31, "u": 32, "i": 34, "p": 35, "l": 37, "j": 38, "k": 40, "n": 45, "m": 46,
            "-": 27, "=": 24, "[": 33, "]": 30, "\\": 42, ";": 41, "'": 39,
            ",": 43, ".": 47, "/": 44, "`": 50, " ": 49,
        ]
        let digits: [UInt16] = [18, 19, 20, 21, 23, 22, 26, 28, 25, 29]
        for (i, d) in "1234567890".enumerated() { c[String(d)] = digits[i] }
        return c
    }()

    /// What Shift makes each key type (US layout; @ # % and friends), and
    /// back: what each of those symbols is typed with.
    private static let shifted: [Character: String] = [
        "1": "!", "2": "@", "3": "#", "4": "$", "5": "%", "6": "^", "7": "&", "8": "*", "9": "(", "0": ")",
        "-": "_", "=": "+", "[": "{", "]": "}", "\\": "|", ";": ":", "'": "\"", ",": "<", ".": ">", "/": "?",
        "`": "~",
    ]
    private static let unshifted: [Character: String] = {
        var table: [Character: String] = [:]
        for (key, symbol) in shifted {
            table[symbol.first ?? " "] = String(key)  // "@" → "2", "<" → ","
        }
        return table
    }()

    private static func press(_ spec: String, in window: NSWindow) -> Bool {
        var flags: NSEvent.ModifierFlags = []
        var key = spec
        // The modifier prefixes are lower case; the key after them keeps
        // its own case (an upper-case letter is Shift and that letter).
        var stripped = true
        while stripped {
            stripped = false
            for (prefix, flag) in [("cmd+", NSEvent.ModifierFlags.command), ("ctrl+", .control),
                                   ("alt+", .option), ("shift+", .shift)]
                where key.lowercased().hasPrefix(prefix) {
                key = String(key.dropFirst(prefix.count))
                flags.insert(flag)
                stripped = true
            }
        }
        guard !key.isEmpty else { return false }
        // An upper-case letter, or a symbol Shift makes ("@", "\"", "<"…),
        // is its unshifted key with Shift held — what a keyboard sends.
        if key.count == 1, !flags.contains(.shift), let c = key.first {
            if c.isUppercase { return press("shift+\(c.lowercased())", in: window) }
            if let unshifted = Self.unshifted[c] { return press("shift+\(unshifted)", in: window) }
        }
        let lower = key.lowercased()
        // What a keyboard sends: the key's code, what it types, and what it
        // types with no modifier but Shift. A named key types its control
        // character or its function-key character, and the arrows and
        // friends also carry the function (and keypad) flags — a text field
        // finds insertNewline: by "\r", not by the key code.
        let keyCode: UInt16, base: String
        if let named = Self.named[lower] {
            keyCode = named.code
            base = named.text
            flags.formUnion(named.flags)
        } else if key.count == 1, let code = codes[lower] {
            keyCode = code
            base = lower
        } else {
            // A key this table doesn't have would go out as key code 0 —
            // the "a" key — and the step would report success. Fail instead.
            return false
        }
        var characters = base
        if flags.contains(.shift), base.count == 1, let c = base.first, c.isLetter || shifted[c] != nil {
            characters = shifted[c] ?? base.uppercased()
        }
        // ⌃ and a letter types its control character (⌃C is 0x03).
        if flags.contains(.control), let ascii = base.unicodeScalars.first?.value, (0x61...0x7a).contains(ascii) {
            characters = String(UnicodeScalar(UInt8(ascii & 0x1f)))
        }

        for type in [NSEvent.EventType.keyDown, .keyUp] {
            guard let event = NSEvent.keyEvent(
                with: type, location: .zero, modifierFlags: flags,
                timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                context: nil, characters: characters,
                charactersIgnoringModifiers: base, isARepeat: false, keyCode: keyCode) else { return false }
            // ⌘ keys go through the menus and key equivalents, as a real
            // press does; the rest straight to the window (an app that's
            // never active has no key window for NSApp to route them to).
            if type == .keyDown, flags.contains(.command) {
                if NSApp.mainMenu?.performKeyEquivalent(with: event) == true { continue }
                // A page (a document, the editor) takes every ⌘ key and hands the
                // ones it doesn't use to the menu bar — which a probe hasn't got:
                // what the menu would do, the keybinds say.
                if window.firstResponder is WKWebView, let action = ConfigStore.shared.keybinds.action(for: event),
                   !action.sendsInput,
                   ActionDispatcher.perform(action, controller: window.windowController as? TerminalWindowController) { continue }
                if window.contentView?.performKeyEquivalent(with: event) == true { continue }
            }
            window.sendEvent(event)
        }
        return true
    }

    /// The keys that aren't text: their code, what they type (as AppKit
    /// reports it) and the flags that come with them.
    private static let named: [String: (code: UInt16, text: String, flags: NSEvent.ModifierFlags)] = {
        let function = NSEvent.ModifierFlags.function, arrow: NSEvent.ModifierFlags = [.function, .numericPad]
        func f(_ key: Int) -> String { String(UnicodeScalar(UInt16(key)).map(Character.init) ?? " ") }
        return [
            "enter": (36, "\r", []), "return": (36, "\r", []), "tab": (48, "\t", []), "escape": (53, "\u{1b}", []),
            "space": (49, " ", []), "backspace": (51, "\u{7f}", []),
            "delete": (117, f(NSDeleteFunctionKey), function), "home": (115, f(NSHomeFunctionKey), function),
            "end": (119, f(NSEndFunctionKey), function), "pageup": (116, f(NSPageUpFunctionKey), function),
            "pagedown": (121, f(NSPageDownFunctionKey), function),
            "up": (126, f(NSUpArrowFunctionKey), arrow), "down": (125, f(NSDownArrowFunctionKey), arrow),
            "left": (123, f(NSLeftArrowFunctionKey), arrow), "right": (124, f(NSRightArrowFunctionKey), arrow),
        ]
    }()

    // MARK: Mouse and shots

    private static func click(x: CGFloat, y: CGFloat, in window: NSWindow) {
        // The script speaks from the content's top-left; AppKit from the
        // window's bottom-left.
        let height = window.contentView?.bounds.height ?? 0
        let point = NSPoint(x: x, y: height - y)
        func event(_ type: NSEvent.EventType) -> NSEvent? {
            NSEvent.mouseEvent(with: type, location: point, modifierFlags: [],
                               timestamp: ProcessInfo.processInfo.systemUptime,
                               windowNumber: window.windowNumber, context: nil, eventNumber: 0, clickCount: 1,
                               pressure: 1)
        }
        // What's there, so a script that clicks the wrong spot says so.
        guard let target = window.contentView?.hitTest(point), let down = event(.leftMouseDown),
              let up = event(.leftMouseUp) else {
            print("click \(Int(x)),\(Int(y)) → nothing")
            return
        }
        let what = (target as? NSButton).map { button in
            // An image button's title is AppKit's placeholder; its tooltip says what it is.
            "button \"\(button.image != nil && button.toolTip != nil ? button.toolTip! : button.title)\""
        } ?? String(describing: type(of: target))
        print("click \(Int(x)),\(Int(y)) → \(what)")
        // The window is never key — the app never activates, so keystrokes
        // meant for other apps stay there — and AppKit spends the first
        // click on a window that isn't key on making it key. So the click
        // goes to the view under it: its own mouseDown, tracking and
        // action, as a real click runs them. A button tracks inside its
        // mouseDown, taking events off the queue until the button comes up:
        // the up must be waiting there already.
        NSApp.postEvent(up, atStart: false)
        target.mouseDown(with: down)
        // A view that doesn't track leaves the up queued: it's still due.
        if NSApp.nextEvent(matching: .leftMouseUp, until: Date(), inMode: .default, dequeue: true) != nil {
            target.mouseUp(with: up)
        }
    }

    private static func terminals(in view: NSView) -> [TerminalView] {
        (view as? TerminalView).map { [$0] } ?? view.subviews.flatMap(terminals(in:))
    }

    /// The window's pixels, as winshot takes them (one window, no others).
    /// Off every screen (a probe's) or while the display sleeps, the window
    /// server has no image of it; then the window's views draw themselves
    /// into a bitmap instead, each terminal's own frame over it (above its
    /// overlays: a find bar, a dimmed pane show as if absent). Says which it was.
    private static func capture(_ window: NSWindow, to path: String) {
        try? FileManager.default.createDirectory(atPath: (path as NSString).deletingLastPathComponent,
                                                 withIntermediateDirectories: true)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-o", "-l\(window.windowNumber)", path]
        p.standardError = FileHandle.nullDevice
        try? p.run()
        p.waitUntilExit()
        if p.terminationStatus == 0, FileManager.default.fileExists(atPath: path) {
            print("shot \(path)")
            return
        }
        guard let view = window.contentView?.superview ?? window.contentView,
              let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else {
            print("ui-probe: couldn't capture \(path)")
            return
        }
        view.cacheDisplay(in: view.bounds, to: rep)
        // Terminals draw with Metal, which drawing the views leaves out: each
        // pane's own frame over its place.
        if let context = NSGraphicsContext(bitmapImageRep: rep) {
            // (The context is in points, bottom-left; the images in pixels.)
            let scale = CGFloat(rep.pixelsWide) / view.bounds.width
            for pane in terminals(in: view) where !pane.isHiddenOrHasHiddenAncestor {
                guard let image = pane.thumbnail() else { continue }
                let rect = pane.convert(pane.bounds, to: view)
                let flipped = view.isFlipped ? NSRect(x: rect.minX, y: view.bounds.height - rect.maxY,
                                                       width: rect.width, height: rect.height) : rect
                context.cgContext.draw(image, in: CGRect(x: flipped.minX, y: flipped.maxY - CGFloat(image.height) / scale,
                                                         width: CGFloat(image.width) / scale, height: CGFloat(image.height) / scale))
            }
        }
        if let data = rep.representation(using: .png, properties: [:]), (try? data.write(to: URL(fileURLWithPath: path))) != nil {
            print("shot \(path) (drawn: off every screen, or the display asleep)")
        } else {
            print("ui-probe: couldn't capture \(path)")
        }
    }
}
