#if LIBERTTY_PROBES
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
///   expect-tab-not:TEXT  no sidebar row contains TEXT (a row's second line reads "2: …")
///   sidebar-width:N      drag the sidebar's edge to N points (it stops at its least width);
///                        its top row's buttons mustn't overlap
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
///   expect-no-open-animation:go  the window appears as it is (no zoom: its text would seem to change size)
///   expect-resize-frames:N the focused pane drew N frames inside a resize since the last of these
///   expect-pinned:go      every pane's drawable is its view's size and pinned top-left, also once AppKit sets its gravity again
///   expect-runs:PATH=yes|no  whether ⌘-clicking a link to PATH asks first (opening it would run it)
///   expect-layout:TREE    the tab's split as h50(a,v50(b,c)): h side by side, v stacked, the first's share
///                         in percent; panes named a, b, c… in the order the probe first saw them
///   expect-looks:compact=yes|no,accent=#rrggbb|system,holes=N  the panes' style, the accent, and how many
///                         terminals glass panes let the desktop through (each part optional)
///   drop:N:SIDE           drop the focused pane on the tab's Nth pane (reading order) as a drag would:
///                         left, right, up, down (beside it) or swap
///   theme-editor:open|cancel|save|revert|name:NAME|set:SLOT=#rrggbb|oklch:SLOT=L,C,H|pick:SLOT|preview:on|off|extended:on|off
///                         drive Libertty ▸ Theme Editor (the Theme Customizer). SLOT: background, foreground,
///                         cursor, cursor-text, selection, selection-foreground or 0–255; oklch sets it as the
///                         picker's disc and sliders do, pick opens the picker on it (a shot then has it too)
///   settings:open|close|page:NAME|press:LABEL|search:TEXT|mark|dump  drive Libertty ▸ Settings…: a page; press
///                         the control VoiceOver calls LABEL (a segment, a switch, a theme card: `Nord theme`);
///                         type TEXT in Search Settings and press Return; mark the config file; print every element
///   expect-settings:page=NAME|LABEL=VALUE|LABEL  the page in front; a control's value as VoiceOver reads it
///                         (a segment's 1 or 0, a card's Selected); that something is labeled LABEL
///   expect-config-change:LINE  since settings:mark (or the last of these), the config file changed by one
///                         line, which now reads LINE: rewritten in place, or added
///   (shot: takes the Settings window as NAME-settings.png while it's open)
///                         (a probe's window is never key, so focus never comes on its own)
///   open:PATH[:LINE]      show a file in a tab (as `+open` does); edit:PATH in the editor
///   editor-wait:go        until the document in front's editor is up (it loads in its own process)
///   editor-insert:TEXT    put TEXT at the editor's cursor (`type:` sends real keys)
///   editor-save:go        File ▸ Save
///   expect-editor:TEXT    the editor holds TEXT; expect-dirty:yes|no its unsaved state
///   expect-file:PATH=TEXT the file on disk contains TEXT (`\n` for a newline)
///   shell:COMMAND         run COMMAND (sh -c), as another program changing files would
///   sheet:BUTTON          press BUTTON on the sheet over the window (Save, Don't Save, Cancel)
///   sheet-type:TEXT       put TEXT in the sheet's text field (a name it asks for)
///   expect-header:TEXT    the focused pane's header says TEXT (its name, folder or branch)
///   header-pointer:on|off  the pointer comes onto (or leaves) the focused pane's header
///   expect-header-buttons:A,B  the buttons it shows now, by tooltip (`-`: none)
///   expect-pending-keys:TEXT  the focused pane's tag for a key sequence under way (`-`: none), readable on its ground
///   expect-link-preview:URL  its tag for where the link under ⌘ goes (`-`: none), readable on its ground
///   expect-name-tag:TEXT  its name tag (hover:N shows it, without headers) has TEXT in it (`-`: none), readable on its ground
///   cmd-hover:TEXT        ⌘ held with the pointer over TEXT's last showing in the focused pane
///   expect-peek:NAME      the image peek shows the file NAME (none: nothing shows)
///   expect-sheet:yes|no   whether a sheet is up
///   expect-sheet-text:TEXT the sheet up says TEXT (its message or informative text)
///   update-background:go  the daily update check now (auto-update = download), then restart if idle
///   pinch:N              a two-finger pinch of N (spread +, pinch -) over the focused pane
///   swipe:DX             a two-finger swipe of DX points sideways (fingers right +) over it
///   expect-zoomed:yes|no, expect-sidebar-shown:yes|no
///   trackpad-swipe:DX[:option]  a two-finger swipe as the trackpad sends it (scroll events, began to ended) over the focused pane
///   expect-active-border:yes|no  a border round the focused pane's card (and no other), or none
///   expect-activity:LINES  Activity By State lists LINES (`|` between them: `Working (1)|  Claude Code`)
///   welcome:N             the welcome guide (Help ▸ Get Started) open at page N (0 first), drawn to welcome-N.png
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
///   browser:ARGS ==> TEXT  what `libertty +browser ARGS` does here (ARGS split as a shell does); what
///                         it prints contains TEXT (`!TEXT`: it failed, saying TEXT). Without ` ==> `, just do it.
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

    /// The panes' names in `expect-layout`, by when it first saw them.
    private static var paneNames: [ObjectIdentifier: String] = [:]

    /// Each pane's grid changes at its last `expect-regrids`.
    private static var regridMarks: [ObjectIdentifier: Int] = [:]
    private static var resizeFrameMarks: [ObjectIdentifier: Int] = [:]

    static func run(script: String, output: String) -> Never {
        let app = NSApplication.shared
        app.setActivationPolicy(.accessory)  // no Dock icon, nothing in front
        Motion.forceReduced = true
        Probe.running = true
        // English unless its config names a language (`language = zh-Hans`).
        L10n.start(ConfigStore.shared.config.language)

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
        // `other-window:`: a second connection showing the focused session.
        var otherWindow: RemotePTY?
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
        // `libertty +split`, `+move-pane` and `+browser` from its panes' shells,
        // to this probe (requests name its private liberttyd's socket).
        let paneRequests = DistributedNotificationCenter.default().addObserver(
            forName: RemoteControl.notification, object: nil, queue: .main) { note in
            guard let info = note.userInfo as? [String: String], RemoteControl.isForUs(info) else { return }
            if info["kind"] == "browser" {
                return BrowserAutomation.handle(info, in: [controller] + others, front: controller, newWindow: { nil }, activate: {})
            }
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
            // An expectation that doesn't hold yet is asked again for a while
            // (`LIBERTTY_PROBE_PATIENCE` seconds, 3 by default): a loaded machine
            // is slow, not wrong. Only its last answer is printed.
            let retries = Self.asksAgain(step)
            let deadline = Date().addingTimeInterval(retries ? Self.patience : 0)
            let before = failures
            while true {
                held = retries ? [] : nil
                autoreleasepool { repeat {  // (a step's `continue` ends its attempt; what it autoreleased goes with it)
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
                        // The palette's own panel beside it, while one is open.
                        if let panel = CommandPalette.openPanel {
                            capture(panel, to: output + "/" + (name as NSString).deletingPathExtension + "-palette.png")
                        }
                        if let editor = MainActor.assumeIsolated({ ThemeEditor.shared.openWindow }) {
                            capture(editor, to: output + "/" + (name as NSString).deletingPathExtension + "-theme-editor.png")
                        }
                        if let picker = MainActor.assumeIsolated({ ThemeEditor.shared.pickerWindow }) {
                            capture(picker, to: output + "/" + (name as NSString).deletingPathExtension + "-color-picker.png")
                        }
                        if let settings = MainActor.assumeIsolated({ SettingsWindowController.shared.openWindow }) {
                            capture(settings, to: output + "/" + (name as NSString).deletingPathExtension + "-settings.png")
                        }
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
                    case .expectTabNot(let text):
                        let rows = controller.sidebarRows
                        if let row = rows.first(where: { $0.contains(text) }) {
                            print("FAIL  ui-probe tab: a row shows \(text): \(row)")
                            failures += 1
                        } else {
                            print("ok    ui-probe no tab shows \(text)")
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
                    case .commandHover(let text):
                        let rows = controller.focusedTerminal.session.screenRows().split(separator: "\n", omittingEmptySubsequences: false)
                        guard let row = rows.lastIndex(where: { $0.contains(text) }),
                              let at = rows[row].range(of: text, options: .backwards) else {
                            print("FAIL  ui-probe cmd-hover: no \(text) on screen")
                            failures += 1
                            break
                        }
                        let col = rows[row].distance(from: rows[row].startIndex, to: at.lowerBound) + 1
                        controller.focusedTerminal.commandHover(col: col, row: row)
                        pump(0.3)
                    case .expectPeek(let name):
                        let shown = controller.focusedTerminal.peekedImage ?? "none"
                        if shown == name {
                            print("ok    ui-probe peek shows \(name)")
                        } else {
                            print("FAIL  ui-probe peek: \(shown), not \(name)")
                            failures += 1
                        }
                    case .expectHeader(let text):
                        let leaf = controller.selectedTab.focusedPane as NSView?
                        let info = leaf.map { leaf in MainActor.assumeIsolated { controller.headerInfo(for: leaf) } }
                        let said = info.map { [$0.name, $0.detail, $0.branch].joined(separator: " · ") } ?? "(no pane)"
                        if said.contains(text) {
                            print("ok    ui-probe header says \(text)")
                        } else {
                            print("FAIL  ui-probe header: \"\(said)\", not \(text)")
                            failures += 1
                        }
                    case .sheetType(let text):
                        func field(in view: NSView?) -> NSTextField? {
                            guard let view else { return nil }
                            if let f = view as? NSTextField, f.isEditable { return f }
                            return view.subviews.lazy.compactMap(field(in:)).first
                        }
                        if let sheet = window.attachedSheet, let f = field(in: sheet.contentView) {
                            f.stringValue = text
                        } else {
                            print("FAIL  ui-probe sheet-type: \(window.attachedSheet == nil ? "no sheet up" : "no field on it")")
                            failures += 1
                        }
                    case .expectSheetText(let text):
                        let alert = window.attachedSheet.flatMap { sheet in
                            sheet.contentView.map { root -> String in
                                var words: [String] = []
                                func walk(_ v: NSView) { if let f = v as? NSTextField { words.append(f.stringValue) }; v.subviews.forEach(walk) }
                                walk(root)
                                return words.joined(separator: " | ")
                            }
                        } ?? ""
                        if alert.contains(text) { print("ok    ui-probe sheet says \(text)") } else {
                            print("FAIL  ui-probe sheet: no \(text) in \(alert.isEmpty ? "(no sheet)" : alert)")
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
                    case .browser(let call, let want):
                        // As `libertty +browser CALL` does, handed to this probe's windows.
                        let result: (out: String, err: String, status: Int32)
                        switch BrowserAutomation.parse(Self.words(call), caller: nil) {
                        case .failure(let why): result = ("", why.text, 2)
                        case .success(let request):
                            result = BrowserAutomation.perform(request, deliver: { info in
                                BrowserAutomation.handle(info, in: [controller] + others, front: controller, newWindow: { nil }, activate: {})
                            }, pump: Self.pump)
                        }
                        pump(0.4)
                        guard let want else { continue }
                        let failed = want.hasPrefix("!")
                        let text = failed ? String(want.dropFirst()) : want
                        let said = result.status == 0 ? result.out : result.err
                        if (result.status == 0) == !failed, text.isEmpty || said.contains(text) {
                            print("ok    ui-probe browser \(call.prefix(40)) \(failed ? "refused" : "says") \(text.prefix(60))")
                        } else {
                            print("FAIL  ui-probe browser \(call): status \(result.status), said \(String(said.prefix(300)).debugDescription), not \(want.debugDescription)")
                            failures += 1
                        }
                    case .pageWait:
                        // A first page also starts WebKit's processes: slow on a busy machine.
                        let started = Date(), deadline = started.addingTimeInterval(max(10, Self.patience * 3))
                        var ready = false, said: Any?
                        while !ready, Date() < deadline {
                            pump(0.2)
                            said = pageEvaluate(controller, "document.readyState === 'complete' && document.body.innerText.trim().length > 0 && !document.body.innerText.includes('Reading…')")
                            ready = (said as? Bool) == true || controller.selectedDocument?.pageLoaded == true
                        }
                        let took = String(format: "%.1f s", Date().timeIntervalSince(started))
                        if ready { print("ok    ui-probe page up (\(took))"); pump(0.3) } else {
                            // What it was waiting on, for a failure that's seen only elsewhere (CI).
                            let doc = controller.selectedDocument
                            print("FAIL  ui-probe page: never drew in \(took): the page said \(said.map { "\($0)" } ?? "nothing"); "
                                  + (doc.map { "\($0.url.absoluteString): \($0.pageState)" } ?? "no document in front"))
                            failures += 1
                        }
                    case .expectPage(let text, let want):
                        let deadline = Date().addingTimeInterval(want ? max(3, Self.patience) : 0.5)
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
                    case .expectPinned:
                        // As AppKit does at times of its own: its placement onto the layer's gravity.
                        let panes = controller.everyTab.flatMap(\.panes)
                        var wrong: [String] = []
                        for pane in panes {
                            pane.layerContentsPlacement = pane.layerContentsPlacement
                            let summary = pane.contentsPlacementSummary
                            if !summary.hasSuffix("gravity bottomLeft") { wrong.append(summary) }
                            // The window server maps it onto the bounds whatever the gravity (a window brought back).
                            if !pane.drawableFitsView { wrong.append("drawable \(pane.drawableSize) for a view of \(pane.bounds.size)") }
                        }
                        if wrong.isEmpty { print("ok    ui-probe \(panes.count) panes pinned top-left") } else {
                            print("FAIL  ui-probe pinned: \(wrong.joined(separator: "; ")) (its drawable would be stretched to the view)")
                            failures += 1
                        }
                    case .expectLayout(let want):
                        pump(0.5)  // a balance under way settles
                        let shown = controller.selectedTab.container?.layoutDescription { view in
                            let id = ObjectIdentifier(view)
                            if let name = paneNames[id] { return name }
                            let name = String(UnicodeScalar(UInt8(97 + paneNames.count)))
                            paneNames[id] = name
                            return name
                        } ?? "(no split)"
                        if shown == want { print("ok    ui-probe layout \(want)") } else {
                            print("FAIL  ui-probe layout: \(shown), not \(want)")
                            failures += 1
                        }
                    case .expectLooks(let want):
                        pump(0.3)
                        var wrong: [String] = []
                        for part in want.split(separator: ",") {
                            let kv = part.split(separator: "=", maxSplits: 1).map(String.init)
                            guard kv.count == 2 else { continue }
                            switch kv[0] {
                            case "compact":
                                let first = controller.selectedTab.container?.views.first
                                let inset = first?.frame.minX ?? -1
                                let radius = first?.layer?.cornerRadius ?? -1
                                let compact = inset < 1 && radius == 0
                                if compact != (kv[1] == "yes") { wrong.append("pane at x \(inset), radius \(radius)") }
                            case "accent":
                                let shown = MainActor.assumeIsolated { Accent.custom?.hexString ?? "system" }
                                if shown != kv[1] { wrong.append("accent \(shown)") }
                            case "holes":
                                let n = controller.areaHoleCount
                                if String(n) != kv[1] { wrong.append("\(n) holes") }
                            default: wrong.append("no \(kv[0])")
                            }
                        }
                        if wrong.isEmpty { print("ok    ui-probe looks \(want)") } else {
                            print("FAIL  ui-probe looks: \(wrong.joined(separator: ", ")), not \(want)")
                            failures += 1
                        }
                    case .drop(let n, let side):
                        let views = controller.selectedTab.container?.views ?? []
                        guard views.indices.contains(n - 1), let pane = controller.selectedTab.focusedLeaf,
                              controller.probeDrop(pane, on: views[n - 1], side) else {
                            print("FAIL  ui-probe drop: no pane \(n) or no \(side)")
                            failures += 1
                            break
                        }
                        pump(0.6)
                    case .themeEditor(let command):
                        let done = MainActor.assumeIsolated { () -> Bool in
                            let editor = ThemeEditor.shared
                            if command == "open" { editor.show(nil) }
                            else if command == "cancel" { editor.probeCancel() }
                            else if command == "save" { editor.probeSave() }
                            else if command == "revert" { editor.probeRevert() }
                            else if command == "preview:on" || command == "preview:off" { editor.probePreview(command.hasSuffix("on")) }
                            else if command == "extended:on" || command == "extended:off" { editor.probeExtended(command.hasSuffix("on")) }
                            else if command.hasPrefix("name:") { editor.probeName(String(command.dropFirst(5))) }
                            else if command.hasPrefix("pick:"), editor.probePick(String(command.dropFirst(5))) {}
                            else if command.hasPrefix("set:"), case let parts = command.dropFirst(4).split(separator: "=", maxSplits: 1),
                                    parts.count == 2, editor.probeSet(String(parts[0]), String(parts[1])) {}
                            else if command.hasPrefix("oklch:"), case let parts = command.dropFirst(6).split(separator: "=", maxSplits: 1),
                                    parts.count == 2, case let v = parts[1].split(separator: ",").compactMap({ Double($0) }), v.count == 3,
                                    editor.probeOKLCH(String(parts[0]), OKLCH(l: v[0], c: v[1], h: v[2])) {}
                            else { return false }
                            return true
                        }
                        if !done {
                            print("FAIL  ui-probe theme-editor: can't \(command)")
                            failures += 1
                        }
                        pump(0.4)
                    case .settings(let command):
                        if let why = Self.settings(command) {
                            print("FAIL  ui-probe settings \(command): \(why)")
                            failures += 1
                        }
                    case .expectSettings(let want):
                        if let why = Self.expectSettings(want) {
                            print("FAIL  ui-probe settings: \(why), not \(want)")
                            failures += 1
                        } else {
                            print("ok    ui-probe settings show \(want)")
                        }
                    case .expectConfigChange(let line):
                        if let why = Self.expectConfigChange(line) {
                            print("FAIL  ui-probe config: \(why)")
                            failures += 1
                        } else {
                            print("ok    ui-probe config changed one line: \(line)")
                        }
                    case .expectRuns(let path, let runs):
                        let found = TerminalView.wouldRun(URL(fileURLWithPath: path))
                        if found == runs { print("ok    ui-probe \(path) \(runs ? "asks first" : "opens")") } else {
                            print("FAIL  ui-probe \(path): \(found ? "asks first" : "opens"), not \(runs ? "asks first" : "opens")")
                            failures += 1
                        }
                    case .expectResizeFrames(let n):
                        // Frames drawn inside a resize's transaction since the last of these (for the pane).
                        let pane = controller.focusedTerminal
                        let since = pane.resizeFrames - (resizeFrameMarks[ObjectIdentifier(pane)] ?? 0)
                        resizeFrameMarks[ObjectIdentifier(pane)] = pane.resizeFrames
                        if since == n { print("ok    ui-probe \(n) frames drawn resizing") } else {
                            print("FAIL  ui-probe frames drawn resizing: \(since), not \(n)")
                            failures += 1
                        }
                    case .expectNoOpenAnimation:
                        if window.animationBehavior == .none { print("ok    ui-probe window opens without animation") } else {
                            print("FAIL  ui-probe window: it animates as it opens (\(window.animationBehavior.rawValue))")
                            failures += 1
                        }
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
                    case .headerPointer(let over):
                        let leaf = controller.selectedTab.focusedPane as NSView?
                        guard let leaf, let header = controller.selectedTab.container?.shownHeader(for: leaf) else {
                            print("FAIL  ui-probe header-pointer: the focused pane has no header")
                            failures += 1
                            break
                        }
                        header.setPointerOver(over)
                        pump(0.3)
                    case .expectHeaderButtons(let want):
                        let leaf = controller.selectedTab.focusedPane as NSView?
                        let header = leaf.flatMap { controller.selectedTab.container?.shownHeader(for: $0) }
                        let shown = header.map { $0.shownButtons.joined(separator: ",") } ?? "(no header)"
                        if shown == (want == "-" ? "" : want) {
                            print("ok    ui-probe header buttons: \(want)")
                        } else {
                            print("FAIL  ui-probe header buttons: \(shown), not \(want)")
                            failures += 1
                        }
                    case .caretAsk:
                        // As the system does when a view takes the keyboard — and not again by itself.
                        _ = controller.focusedTerminal.firstRect(forCharacterRange: NSRange(location: 0, length: 0), actualRange: nil)
                        print("ok    ui-probe caret asked")
                    case .move(let dx, let dy):
                        // The window, as dragged: where it is, not its size.
                        window.setFrameOrigin(NSPoint(x: window.frame.minX + dx, y: window.frame.minY + dy))
                        pump(0.4)
                    case .expectPendingKeys(let want):
                        // The tag of a sequence under way, in the focused pane: "-" for none.
                        // Shown, its text reads on its ground in the appearance the pane
                        // has now (4.5: WCAG's contrast for text).
                        let pane = controller.focusedTerminal
                        if !tagHolds("pending keys", shown: pane.pendingKeysShown, contrast: pane.pendingKeysContrast, want: want) { failures += 1 }
                    case .expectLinkPreview(let want):
                        let pane = controller.focusedTerminal
                        if !tagHolds("link preview", shown: pane.linkPreviewShown, contrast: pane.linkPreviewContrast, want: want) { failures += 1 }
                    case .expectNameTag(let want):
                        // (Its text is the dimmer secondary one: 3, WCAG's contrast for large text.)
                        let pane = controller.focusedTerminal
                        if !tagHolds("name tag", shown: pane.nameTagShown, contrast: pane.nameTagContrast, want: want, whole: false,
                                     minimum: 3) { failures += 1 }
                    case .expectCaretTold:
                        // Where the system would put its input-source indicator is where the cursor is.
                        let pane = controller.focusedTerminal
                        let told = pane.announcedCaretRect, now = pane.caretScreenRect
                        if told == now {
                            print("ok    ui-probe caret: the system has it at \(Int(now.minX)),\(Int(now.minY))")
                        } else {
                            print("FAIL  ui-probe caret: the system has it at \(Int(told.minX)),\(Int(told.minY)), it's at \(Int(now.minX)),\(Int(now.minY))")
                            failures += 1
                        }
                    case .expectSelected(let text):
                        // The tab in front, by its name (the window's title).
                        if window.title.contains(text) {
                            print("ok    ui-probe the tab in front is \(text)")
                        } else {
                            print("FAIL  ui-probe the tab in front: \"\(window.title)\", not \(text)")
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
                    case .expectSecureInput(let on):
                        let wants = SecureInput.wantsForPassword(controller.focusedTerminal)
                        if wants == on {
                            print("ok    ui-probe secure input \(on ? "on" : "off") for a password")
                        } else {
                            print("FAIL  ui-probe secure input: \(wants ? "on" : "off"), not \(on ? "on" : "off")")
                            failures += 1
                        }
                    case .otherWindow(let spec):
                        if spec == "close" {
                            otherWindow?.detach()
                            otherWindow = nil
                            print("ok    ui-probe the other window went")
                        } else if let id = controller.focusedTerminal.session.persistentID {
                            let dims = spec.split(separator: "x").compactMap { UInt16($0) }
                            if otherWindow == nil {
                                otherWindow = try? RemotePTY.attach(id: id, queue: DispatchQueue(label: "probe.other")).0
                                otherWindow?.onOutput = { _ in }
                                otherWindow?.startReading()
                            }
                            if let other = otherWindow, dims.count == 2 {
                                other.resize(GridSize(cols: dims[0], rows: dims[1], widthPx: dims[0] * 8, heightPx: dims[1] * 16))
                                print("ok    ui-probe another window at \(spec)")
                            } else {
                                print("FAIL  ui-probe another window: couldn't attach (--persist?) or no size in \(spec)")
                                failures += 1
                            }
                        } else {
                            print("FAIL  ui-probe another window: the pane has no session in liberttyd (--persist)")
                            failures += 1
                        }
                    case .expectSized(let yes):
                        let shown = controller.focusedTerminal.sizedTagShown
                        if (shown != nil) == yes {
                            print("ok    ui-probe \(yes ? "sized by another window" : "sized by this pane")")
                        } else {
                            print("FAIL  ui-probe sized tag: \(shown ?? "none"), program \(String(describing: controller.focusedTerminal.session.programSize))")
                            failures += 1
                        }
                    case .fitHere:
                        let fitted = controller.focusedTerminal.session
                        fitted.fitProgramToPane()
                        controller.focusedTerminal.programSizeChanged()
                        print("ok    ui-probe fit to this pane (\(fitted.size.cols)x\(fitted.size.rows))")
                    case .updateInBackground:
                        // auto-update = download's daily check, now; then, with
                        // auto-update-restart = idle, the restart when nobody's looking.
                        MainActor.assumeIsolated {
                            let updates = UpdateController.shared
                            updates.checkInBackground()
                            let deadline = Date().addingTimeInterval(60)
                            repeat { pump(0.1) } while updates.isBusy && Date() < deadline
                            print(updates.isReady ? "ok    ui-probe update downloaded" : "FAIL  ui-probe update: none downloaded")
                            if !updates.isReady { failures += 1 }
                            updates.restartIfIdle()
                            repeat { pump(0.1) } while updates.isBusy && Date() < deadline
                            for line in updates.probeLog { print("update: \(line.replacingOccurrences(of: "\n", with: " "))") }
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
                    case .pinch(let total):
                        // `pinch:N` then `=zoomed` or `=unzoomed`: what it should leave.
                        controller.focusedTerminal.pinched(CGFloat(total))
                        pump(0.5)
                        print("ok    ui-probe pinch \(total): \(controller.isZoomed ? "zoomed" : "unzoomed")")
                    case .swipe(let dx):
                        controller.focusedTerminal.swiped(dx: CGFloat(dx), dy: 0)
                        pump(0.5)
                        print("ok    ui-probe swipe \(dx): sidebar \(controller.isSidebarShown ? "shown" : "hidden")")
                    case .expectActiveBorder(let want):
                        pump(0.4)
                        let container = controller.selectedTab.container
                        let border = container?.activeBorderFrame
                        let leaf = controller.selectedTab.focusedLeaf
                        // Round the focused pane: its frame inside the border, the border within a few points of it.
                        let round = border.flatMap { b in leaf.map { l in b.insetBy(dx: -1, dy: -1).contains(l.frame) && l.frame.insetBy(dx: -4, dy: -40).contains(b) } } ?? false
                        if want, container?.activeBorderOnTop != true {
                            print("FAIL  ui-probe active border: under a pane or header"); failures += 1
                        }
                        if want ? round : border == nil {
                            print("ok    ui-probe active border \(want ? "round the focused pane" : "none")")
                        } else {
                            print("FAIL  ui-probe active border: \(border.map { "\($0)" } ?? "none"), focused pane at \(leaf.map { "\($0.frame)" } ?? "none")")
                            failures += 1
                        }
                    case .expectZoomed(let want):
                        if controller.isZoomed == want { print("ok    ui-probe \(want ? "zoomed" : "not zoomed")") } else {
                            print("FAIL  ui-probe zoom: \(controller.isZoomed ? "zoomed" : "not zoomed"), wanted the other"); failures += 1
                        }
                    case .trackpadSwipe(let dx, let option):
                        // Ten events, as a trackpad sends a swipe: began, changed, ended.
                        let pane = controller.focusedTerminal
                        let steps = 10
                        for i in 0..<steps {
                            let phase: Int64 = i == 0 ? 1 : i == steps - 1 ? 4 : 2
                            let delta = i == steps - 1 ? 0 : dx / Double(steps - 1)
                            guard let cg = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: 0,
                                                   wheel2: Int32(delta.rounded()), wheel3: 0) else { continue }
                            cg.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
                            cg.setIntegerValueField(.scrollWheelEventScrollPhase, value: phase)
                            cg.setDoubleValueField(.scrollWheelEventPointDeltaAxis2, value: delta)
                            if option { cg.flags = .maskAlternate }
                            guard let event = NSEvent(cgEvent: cg) else { continue }
                            if i == 0 {
                                print("info  ui-probe trackpad event: precise \(event.hasPreciseScrollingDeltas) phase \(event.phase.rawValue) "
                                      + "momentum \(event.momentumPhase.rawValue) dx \(event.scrollingDeltaX) option \(event.modifierFlags.contains(.option)) "
                                      + "inverted \(event.isDirectionInvertedFromDevice)")
                            }
                            pane.scrollWheel(with: event)
                        }
                        pump(0.5)
                        print("ok    ui-probe trackpad swipe \(dx)\(option ? " with Option" : ""): sidebar \(controller.isSidebarShown ? "shown" : "hidden")")
                    case .welcome(let page):
                        let welcome = WelcomeWindowController.shared
                        welcome.show()
                        welcome.state.page = page
                        pump(0.6)
                        if let w = welcome.openWindow {
                            let file = output + "/welcome-\(page).png"
                            capture(w, to: file)
                            print("ok    ui-probe welcome page \(page) (\(w.title)) drawn to \(file)")
                        } else {
                            print("FAIL  ui-probe welcome: no window"); failures += 1
                        }
                    case .expectActivity(let want):
                        let inbox = controller.inboxPopover.contentViewController as! InboxViewController
                        _ = inbox.view
                        inbox.show(byState: true)
                        let got = inbox.shownRows.joined(separator: "|")
                        if got == want { print("ok    ui-probe activity by state: \(got)") } else {
                            print("FAIL  ui-probe activity by state: '\(got)', wanted '\(want)'"); failures += 1
                        }
                    case .expectSidebarShown(let want):
                        if controller.isSidebarShown == want { print("ok    ui-probe sidebar \(want ? "shown" : "hidden")") } else {
                            print("FAIL  ui-probe sidebar: \(controller.isSidebarShown ? "shown" : "hidden"), wanted the other"); failures += 1
                        }
                    case .sidebarWidth(let w):
                        let split = controller.splitController.splitView
                        split.setPosition(CGFloat(w), ofDividerAt: 0)
                        split.layoutSubtreeIfNeeded()
                        controller.window?.layoutIfNeeded()
                        let width = controller.sidebar.view.frame.width
                        let lead = controller.chrome.leading, trail = controller.chrome.trailing
                        let a = lead.convert(lead.bounds, to: nil), b = trail.convert(trail.bounds, to: nil)
                        if lead.window != nil, trail.window != nil, a.intersects(b) {
                            print("FAIL  ui-probe sidebar \(Int(width)) wide: its buttons overlap (\(Int(a.maxX)) past \(Int(b.minX)))")
                            failures += 1
                        } else {
                            print("ok    ui-probe sidebar \(Int(width)) wide (asked \(Int(w))): its buttons apart")
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
                } while false }
                let said = held ?? []
                held = nil
                if failures == before || !retries || Date() >= deadline {
                    said.forEach { Swift.print($0) }
                    break
                }
                failures = before
                pump(0.15)
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

    /// A pane's tag says `want` ("-": it's hidden; `whole` false: it has
    /// `want` in it), and what it says reads on its ground in the appearance
    /// the pane has now (4.5: WCAG's contrast for text). Says which.
    private static func tagHolds(_ what: String, shown: String?, contrast: Double?, want: String, whole: Bool = true,
                                 minimum: Double = 4.5) -> Bool {
        let shown = shown?.trimmingCharacters(in: .whitespaces) ?? "-"
        guard whole || want == "-" || shown == "-" ? shown == want : shown.contains(want) else {
            print("FAIL  ui-probe \(what): \(shown), not \(want)")
            return false
        }
        if let contrast, contrast < minimum {
            print("FAIL  ui-probe \(what): \(shown) is hard to read on its ground (contrast \(String(format: "%.1f", contrast)))")
            return false
        }
        print("ok    ui-probe \(what): \(shown)")
        return true
    }

    private enum Step {
        case key(String), type(String), click(x: CGFloat, y: CGFloat), clickLabeled(String), wait(Double), tab(String)
        case updateInBackground, shot(String), expect(String), expectNot(String), expectPalette(String), expectTab(String), expectTabNot(String), sidebarWidth(Double), expectSheetText(String), pinch(Double), swipe(Double), expectZoomed(Bool), expectSidebarShown(Bool), expectActiveBorder(Bool), expectActivity(String), welcome(Int), trackpadSwipe(Double, Bool)
        case action(String), expectWindows(Int), expectOther(String), takeTab(Int), expectSubtitle(String), expectSelected(String)
        /// Whether the focused pane would have Secure Keyboard Entry on for a
        /// password (the probe's window is never key, so not the system's state).
        case expectSecureInput(Bool)
        /// Another window on the focused pane's session (in liberttyd), at
        /// COLSxROWS ("close": it goes); whether the pane says it's sized by
        /// another; its tag's click.
        case otherWindow(String), expectSized(Bool), fitHere
        case hover(Int), expectFocus(Int), caretAsk, expectCaretTold, move(CGFloat, CGFloat)
        case headerPointer(Bool), expectHeaderButtons(String), expectPendingKeys(String), expectLinkPreview(String), expectNameTag(String)
        case expectStrip(String), expectStatus(String), expectScope(String), expectFloat(Bool), workspace(String), expectWorkspace(String), roundtrip, expectTabCount(Int), expectShown(Int, String), reload, expectFont(Double), expectBackground(String), appearance(Bool), metrics(String), motion(Bool), actionNow(String), expectRegrids(Int), update(install: Bool), expectAppVersion(String), expectUnmoved, undo, redo, expectPanes(Int), focusEvent(Bool), expectSearching(Int), expectNoOpenAnimation, expectResizeFrames(Int), expectPinned, expectRuns(String, Bool), themeEditor(String), expectLayout(String), drop(Int, String), expectLooks(String)
        case open(String, line: Int?, edit: Bool), editorWait, editorJS(String), editorInsert(String), editorSave
        case expectEditor(String), expectDirty(Bool), expectFile(String, String), shell(String)
        case sheet(String), sheetType(String), expectSheet(Bool), expectHeader(String), commandHover(String), expectPeek(String), waitEdit(token: String, path: String), expectClosed(String)
        case pageWait, expectPage(String, Bool), pageClick(String), pageType(String, String), expectShell(String, String)
        case pageJS(String, String?)
        case settings(String), expectSettings(String), expectConfigChange(String)
        case browser(call: String, want: String?), bar(String)
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
            case "expect-tab-not": steps.append(.expectTabNot(arg))
            case "expect-strip": steps.append(.expectStrip(arg))
            case "expect-status": steps.append(.expectStatus(arg))
            case "expect-float": steps.append(.expectFloat(arg == "yes"))
            case "workspace": steps.append(.workspace(arg))
            case "roundtrip": steps.append(.roundtrip)
            case "expect-workspace": steps.append(.expectWorkspace(arg))
            case "expect-tab-count": steps.append(.expectTabCount(Int(arg) ?? -1))
            case "sidebar-width": steps.append(.sidebarWidth(Double(arg) ?? 0))
            case "pinch": steps.append(.pinch(Double(arg) ?? 0))
            case "update-background": steps.append(.updateInBackground)
            case "swipe": steps.append(.swipe(Double(arg) ?? 0))
            case "expect-zoomed": steps.append(.expectZoomed(arg == "yes"))
            case "expect-active-border": steps.append(.expectActiveBorder(arg == "yes"))
            case "expect-sidebar-shown": steps.append(.expectSidebarShown(arg == "yes"))
            case "expect-activity": steps.append(.expectActivity(arg))
            case "welcome": steps.append(.welcome(Int(arg) ?? 0))
            case "trackpad-swipe":
                let p = arg.split(separator: ":").map(String.init)
                steps.append(.trackpadSwipe(Double(p.first ?? "") ?? 0, p.dropFirst().contains("option")))
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
            case "expect-secure-input": steps.append(.expectSecureInput(arg == "yes"))
            case "other-window": steps.append(.otherWindow(arg))
            case "expect-sized": steps.append(.expectSized(arg == "yes"))
            case "fit-here": steps.append(.fitHere)
            case "expect-selected": steps.append(.expectSelected(arg))
            case "hover": steps.append(.hover(Int(arg) ?? 0))
            case "expect-focus": steps.append(.expectFocus(Int(arg) ?? 0))
            case "caret-ask": steps.append(.caretAsk)
            case "header-pointer": steps.append(.headerPointer(arg == "on"))
            case "expect-header-buttons": steps.append(.expectHeaderButtons(arg))
            case "expect-caret-told": steps.append(.expectCaretTold)
            case "expect-pending-keys": steps.append(.expectPendingKeys(arg))
            case "expect-link-preview": steps.append(.expectLinkPreview(arg))
            case "expect-name-tag": steps.append(.expectNameTag(arg))
            case "move":
                let d = arg.split(separator: ",").compactMap { Double($0) }
                guard d.count == 2 else { print("ui-probe: move:DX,DY"); exit(2) }
                steps.append(.move(CGFloat(d[0]), CGFloat(d[1])))
            case "expect-windows": steps.append(.expectWindows(Int(arg) ?? -1))
            case "expect-other": steps.append(.expectOther(arg))
            case "take-tab": steps.append(.takeTab(Int(arg) ?? -1))
            case "undo": steps.append(.undo)
            case "redo": steps.append(.redo)
            case "expect-panes": steps.append(.expectPanes(Int(arg) ?? -1))
            case "focus-event": steps.append(.focusEvent(arg == "in"))
            case "expect-searching": steps.append(.expectSearching(Int(arg) ?? -1))
            case "expect-no-open-animation": steps.append(.expectNoOpenAnimation)
            case "expect-resize-frames": steps.append(.expectResizeFrames(Int(arg) ?? -1))
            case "expect-pinned": steps.append(.expectPinned)
            case "theme-editor": steps.append(.themeEditor(arg))
            case "settings": steps.append(.settings(arg))
            case "expect-settings": steps.append(.expectSettings(arg))
            case "expect-config-change": steps.append(.expectConfigChange(arg))
            case "expect-layout": steps.append(.expectLayout(arg))
            case "expect-looks": steps.append(.expectLooks(arg))
            case "drop":
                let parts = arg.split(separator: ":", maxSplits: 1).map(String.init)
                if parts.count == 2, let n = Int(parts[0]) { steps.append(.drop(n, parts[1])) }
            case "expect-runs":
                let parts = arg.split(separator: "=", maxSplits: 1).map(String.init)
                if parts.count == 2 { steps.append(.expectRuns(parts[0], parts[1] == "yes")) }
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
            case "sheet-type": steps.append(.sheetType(arg))
            case "expect-header": steps.append(.expectHeader(arg))
            case "cmd-hover": steps.append(.commandHover(arg))
            case "expect-peek": steps.append(.expectPeek(arg))
            case "expect-sheet": steps.append(.expectSheet(arg == "yes"))
            case "expect-sheet-text": steps.append(.expectSheetText(arg))
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
                steps.append(.browser(call: call, want: want))
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
    /// What an expectation printed while it may still be asked again.
    private static var held: [String]?

    /// Lines the steps print: held while an expectation may be asked again.
    private static func print(_ text: String) {
        if held != nil { held!.append(text) } else { Swift.print(text) }
    }

    static let patience = Double(ProcessInfo.processInfo.environment["LIBERTTY_PROBE_PATIENCE"] ?? "") ?? 3

    /// Expectations, asked again until they hold — not those that count
    /// since their last asking (asking again would move their mark).
    private static func asksAgain(_ step: Step) -> Bool {
        let name = String(describing: step)
        guard name.hasPrefix("expect") else { return false }
        return !["expectRegrids", "expectResizeFrames", "expectUnmoved"].contains { name.hasPrefix($0) }
    }

    /// A step's command line as a shell would split it: words, '…' and "…"
    /// quoting (a backslash escapes in double quotes and bare).
    static func words(_ line: String) -> [String] {
        var words: [String] = [], word = "", inWord = false
        var quote: Character?, escaped = false
        for c in line {
            if escaped { word.append(c); escaped = false; continue }
            if c == "\\", quote != "'" { escaped = true; inWord = true; continue }
            if let q = quote {
                if c == q { quote = nil } else { word.append(c) }
                continue
            }
            if c == "'" || c == "\"" { quote = c; inWord = true; continue }
            if c == " " || c == "\t" {
                if inWord { words.append(word); word = ""; inWord = false }
                continue
            }
            word.append(c)
            inWord = true
        }
        if inWord { words.append(word) }
        return words
    }

    /// The run loop for `seconds`, its autoreleased objects let go as it
    /// goes, as NSApplication's loop does — else every closed pane would live
    /// on to the probe's end, and the memory it measures would be the probe's.
    static func pump(_ seconds: Double) {
        let end = Date().addingTimeInterval(seconds)
        repeat {
            autoreleasepool { _ = RunLoop.main.run(mode: .default, before: min(end, Date().addingTimeInterval(0.05))) }
        } while Date() < end
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

    static func press(_ spec: String, in window: NSWindow) -> Bool {
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

    static func click(x: CGFloat, y: CGFloat, in window: NSWindow) {
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
#endif
