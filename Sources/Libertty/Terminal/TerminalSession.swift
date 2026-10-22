import AppKit
import CGhosttyVt
import CPty
import Foundation
import LiberttyCore
import QuartzCore
import os

protocol TerminalSessionDelegate: AnyObject {
    /// All delegate calls arrive on the main thread.
    func sessionNeedsRender(_ session: TerminalSession)
    func sessionTitleChanged(_ session: TerminalSession, title: String)
    func sessionBell(_ session: TerminalSession)
    func sessionProgramStatusChanged(_ session: TerminalSession)
    func sessionExited(_ session: TerminalSession, status: Int32)
    func sessionWorkingDirectoryChanged(_ session: TerminalSession)
    func sessionDesktopNotification(_ session: TerminalSession, title: String, body: String)
    func sessionCommandFinished(_ session: TerminalSession, command: String, exitCode: Int32?, duration: TimeInterval)
    func sessionProgressChanged(_ session: TerminalSession)
    func sessionLinkChanged(_ session: TerminalSession)
    func sessionLabelChanged(_ session: TerminalSession)
}

extension TerminalSessionDelegate {
    func sessionWorkingDirectoryChanged(_ session: TerminalSession) {}
    /// OSC 9 / OSC 777: the program asks for a desktop notification.
    func sessionDesktopNotification(_ session: TerminalSession, title: String, body: String) {}
    /// A command ended (OSC 133 D after C), with how long it ran.
    func sessionCommandFinished(_ session: TerminalSession, command: String, exitCode: Int32?, duration: TimeInterval) {}
    /// OSC 9;4 progress changed (`session.progress`).
    func sessionProgressChanged(_ session: TerminalSession) {}
    /// A session on a host: its link went down or came back (`session.linkUp`).
    func sessionLinkChanged(_ session: TerminalSession) {}
    /// It was named, or its name changed (`session.label`).
    func sessionLabelChanged(_ session: TerminalSession) {}
}

/// A program's OSC 9;4 progress report.
struct TerminalProgress: Equatable {
    enum State { case normal, error, indeterminate, paused }
    var state: State
    /// 0...100; nil when indeterminate.
    var percent: Int?
}

/// One terminal: a libghostty-vt terminal fed by a pty, either our own or one
/// liberttyd keeps alive across app restarts (then this terminal is a replica of
/// liberttyd's, restored from its snapshot).
///
/// Threading: pty output is parsed on `io` while holding `lock`. The main
/// thread takes the same lock only briefly — to snapshot render state, encode
/// input, or resize — so parsing and drawing overlap instead of serializing.
final class TerminalSession {
    weak var delegate: TerminalSessionDelegate?

    let programStatus = ProgramStatusStore()
    private(set) var title = ""
    private(set) var size: GridSize
    /// The shell's working directory as it last reported it (OSC 7), for
    /// opening new panes and windows in the same place.
    private(set) var workingDirectory: String?
    /// How the Option key reaches programs (`macos-option-as-alt`).
    private var optionAsAlt = GHOSTTY_OPTION_AS_ALT_FALSE
    /// Where the shell is, from OSC 133 marks. Guarded by `lock` (the
    /// semantic-prompt callback sets it while parsing).
    private var promptState = PromptState.unknown
    private enum PromptState { case unknown, prompt, running }
    /// Output slices parsed so far and when the last one landed (latency
    /// tracing); guarded by `lock`.
    private var outputCount: UInt64 = 0
    private var lastOutputTime: CFTimeInterval = 0
    /// Find in scrollback; created on first use, guarded by `lock`.
    private var search: GhosttySearch?
    /// Search results as of the last refresh (main thread reads them).
    private(set) var searchResult = SearchResult()
    /// Set (under `lock`) while a paste runs through the write callback.
    private var pasting = false
    /// OSC 9;4, as the program last reported it (main thread).
    private(set) var progress: TerminalProgress?
    /// The command running now (from OSC 133 C) and since when; under `lock`.
    private var commandStart: (time: CFTimeInterval, command: String)?
    /// OSC 52 policy (`clipboard-read`, `clipboard-write`); under `lock`.
    private var clipboardRead = false
    private var clipboardWrite = true

    private var terminal: GhosttyTerminal
    private let keyEncoder: GhosttyKeyEncoder
    private let keyEvent: GhosttyKeyEvent
    private var gesture: GhosttySelectionGesture
    private let gesturePress: GhosttySelectionGestureEvent
    private let gestureDrag: GhosttySelectionGestureEvent
    private let gestureRelease: GhosttySelectionGestureEvent
    private let gestureTick: GhosttySelectionGestureEvent
    private let mouseEncoder: GhosttyMouseEncoder
    private let mouseEvent: GhosttyMouseEvent
    private let lock = UnfairLock()
    private let io: DispatchQueue
    private var pty: TerminalBackend?
    private var pendingPtyResize: DispatchWorkItem?
    private var compressor: IdleCompressor?
    /// The liberttyd session this terminal shows (nil for a pty of our own):
    /// what a saved window layout refers to.
    private(set) var persistentID: String?
    /// The machine the program runs on (File ▸ Connect to Host…); nil for this Mac.
    private(set) var host: RemoteHost?
    /// On a host: whether the link to it is up (false while connecting).
    private(set) var linkUp = true
    /// Its name in liberttyd (`libertty +rename-session`), "" for none: its
    /// tab goes by it.
    private(set) var label = ""
    /// The link has been up at least once (so a drop is a reconnect).
    private(set) var hasConnectedOnce = false
    /// Set on `io` when new output landed; cleared by the renderer.
    private let renderPending = AtomicFlag()

    convenience init(size: GridSize, config: Config = ConfigStore.shared.config) throws {
        var t: GhosttyTerminal?
        guard ghostty_terminal_new(nil, &t, size.cols, size.rows) == GHOSTTY_SUCCESS, let t else {
            throw TerminalError.libghostty("ghostty_terminal_new")
        }
        try self.init(terminal: t, size: size, config: config)
    }

    /// Show a session liberttyd keeps: restore its snapshot, then follow it.
    static func attach(_ id: String, config: Config = ConfigStore.shared.config) throws -> TerminalSession {
        let io = DispatchQueue(label: "libertty.terminal.io", qos: .userInteractive)
        let (remote, snapshot) = try RemotePTY.attach(id: id, queue: io)
        let restored: GhosttyTerminal
        if let t = Snapshots.decode(snapshot, trackContinuation: false) {
            restored = t
        } else {
            // Undecodable: the program lives on, its screen starts blank.
            var t: GhosttyTerminal?
            guard ghostty_terminal_new(nil, &t, 80, 24) == GHOSTTY_SUCCESS, let t else {
                remote.detach()
                throw TerminalError.libghostty("ghostty_terminal_new")
            }
            restored = t
        }
        var cols: UInt16 = 80, rows: UInt16 = 24
        _ = ghostty_terminal_get(restored, GHOSTTY_TERMINAL_DATA_COLS, &cols)
        _ = ghostty_terminal_get(restored, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
        let session = try TerminalSession(terminal: restored, size: GridSize(cols: cols, rows: rows, widthPx: 0, heightPx: 0),
                                          config: config, io: io)
        session.persistentID = id
        session.adoptRestoredState()
        session.connect(remote)
        return session
    }

    /// A session on a host, by its liberttyd id: shown blank until the link is
    /// up, then as the host has it. If the host no longer has it (it
    /// rebooted), a new shell starts in `workingDirectory` instead.
    static func reattach(_ id: String, host: RemoteHost, size: GridSize, workingDirectory: String?,
                         config: Config = ConfigStore.shared.config) throws -> TerminalSession {
        let session = try TerminalSession(size: size, config: config)
        session.workingDirectory = workingDirectory
        session.join(host, id: id, command: nil, workingDirectory: workingDirectory, config: config)
        return session
    }

    /// Start the login shell (or `command`) on `host`. Returns at once: the
    /// session appears when the host answers.
    func start(on host: RemoteHost, workingDirectory: String?, command: String?) {
        if self.workingDirectory == nil { self.workingDirectory = workingDirectory }
        join(host, id: Persistence.newSessionID(), command: command, workingDirectory: workingDirectory,
             config: ConfigStore.shared.config)
    }

    private func join(_ host: RemoteHost, id: String, command: String?, workingDirectory: String?, config: Config) {
        self.host = host
        persistentID = id
        linkUp = false
        let size = size
        // Attaching a new id fails, and then this creates it: one path for
        // new sessions and for sessions a restarted host lost.
        let remote = RemotePTY.reattaching(id: id, address: host.address, fallback: {
            host.createRequest(id: id, command: command, workingDirectory: workingDirectory, size: size, config: config)
        }, queue: io)
        connect(remote)
    }

    private init(terminal t: GhosttyTerminal, size: GridSize, config: Config,
                 io: DispatchQueue = DispatchQueue(label: "libertty.terminal.io", qos: .userInteractive)) throws {
        self.size = size
        self.io = io
        terminal = t

        var enc: GhosttyKeyEncoder?
        var ev: GhosttyKeyEvent?
        guard ghostty_key_encoder_new(nil, &enc) == GHOSTTY_SUCCESS, let enc,
              ghostty_key_event_new(nil, &ev) == GHOSTTY_SUCCESS, let ev else {
            ghostty_terminal_free(t)
            throw TerminalError.libghostty("key encoder")
        }
        keyEncoder = enc
        keyEvent = ev

        var g: GhosttySelectionGesture?
        var press: GhosttySelectionGestureEvent?, drag: GhosttySelectionGestureEvent?, release: GhosttySelectionGestureEvent?
        var tick: GhosttySelectionGestureEvent?
        guard ghostty_selection_gesture_new(nil, &g) == GHOSTTY_SUCCESS, let g,
              ghostty_selection_gesture_event_new(nil, &press, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_PRESS) == GHOSTTY_SUCCESS, let press,
              ghostty_selection_gesture_event_new(nil, &drag, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_DRAG) == GHOSTTY_SUCCESS, let drag,
              ghostty_selection_gesture_event_new(nil, &release, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_RELEASE) == GHOSTTY_SUCCESS, let release,
              ghostty_selection_gesture_event_new(nil, &tick, GHOSTTY_SELECTION_GESTURE_EVENT_TYPE_AUTOSCROLL_TICK) == GHOSTTY_SUCCESS, let tick
        else {
            ghostty_key_event_free(ev)
            ghostty_key_encoder_free(enc)
            ghostty_terminal_free(t)
            throw TerminalError.libghostty("selection gesture")
        }
        gesture = g
        gesturePress = press
        gestureDrag = drag
        gestureRelease = release
        gestureTick = tick

        var menc: GhosttyMouseEncoder?, mev: GhosttyMouseEvent?
        guard ghostty_mouse_encoder_new(nil, &menc) == GHOSTTY_SUCCESS, let menc,
              ghostty_mouse_event_new(nil, &mev) == GHOSTTY_SUCCESS, let mev else {
            throw TerminalError.libghostty("mouse encoder")
        }
        mouseEncoder = menc
        mouseEvent = mev

        configureTerminal()
        apply(config)
        compressor = IdleCompressor(queue: io) { [weak self] body in
            guard let self else { return }
            self.lock.withLock { body(self.terminal) }
        }
    }

    deinit {
        compressor?.stop()
        if let search { ghostty_search_free(search) }
        // A liberttyd session outlives its window (quitting keeps it); closing
        // a pane ends it explicitly with terminate().
        pty?.detach()
        ghostty_mouse_event_free(mouseEvent)
        ghostty_mouse_encoder_free(mouseEncoder)
        ghostty_selection_gesture_event_free(gestureRelease)
        ghostty_selection_gesture_event_free(gestureTick)
        ghostty_selection_gesture_event_free(gestureDrag)
        ghostty_selection_gesture_event_free(gesturePress)
        ghostty_selection_gesture_free(gesture, terminal)
        ghostty_key_event_free(keyEvent)
        ghostty_key_encoder_free(keyEncoder)
        ghostty_terminal_free(terminal)
    }

    // MARK: Lifecycle

    /// Start the user's login shell, or `command` through `/bin/sh -c` when
    /// given: in liberttyd when sessions persist, else on a pty of our own.
    func start(workingDirectory: String? = nil, command: String? = nil, shellPath: String? = nil) throws {
        var (executable, arguments, environment) = Self.launchSpec(command: command, shell: shellPath)
        let startDirectory = workingDirectory ?? NSHomeDirectory()
        if Persistence.enabled {
            let id = Persistence.newSessionID()
            environment["LIBERTTY_SESSION"] = id
            let request = CreateRequest(id: id, executable: executable, arguments: arguments,
                                        environment: environment, workingDirectory: startDirectory,
                                        size: size, scrollback: ConfigStore.shared.config.scrollbackLimit)
            do {
                let remote = try RemotePTY.create(request, queue: io)
                persistentID = id
                connect(remote)
            } catch {
                // liberttyd is gone or refused: this one session runs locally.
                NSLog("Libertty: liberttyd: \(error); starting a local shell")
                environment["LIBERTTY_SESSION"] = nil
                connect(try PTY(executable: executable, arguments: arguments, environment: environment,
                                workingDirectory: startDirectory, size: size, queue: io))
            }
        } else {
            connect(try PTY(executable: executable, arguments: arguments, environment: environment,
                            workingDirectory: startDirectory, size: size, queue: io))
        }
        // Until the shell reports one (OSC 7), the directory it started in.
        if self.workingDirectory == nil { self.workingDirectory = startDirectory }
    }

    private func connect(_ backend: TerminalBackend) {
        backend.onOutput = { [weak self] bytes in self?.feed(bytes) }
        backend.onExit = { [weak self] status in
            DispatchQueue.main.async {
                guard let self else { return }
                self.hasExited = true
                self.programStatus.programFinished()
                self.delegate?.sessionExited(self, status: status)
            }
        }
        if let remote = backend as? RemotePTY {
            remote.onReattach = { [weak self] snapshot in self?.replaceTerminal(with: snapshot) }
            // Fell behind and skipped ahead: the session as it is now. The
            // size is liberttyd's already — another window may have set it,
            // and saying ours again would take it back.
            remote.onCatchUp = { [weak self] snapshot in self?.replaceTerminal(with: snapshot, reassertSize: false) }
            remote.onLinkChange = { [weak self] up in
                DispatchQueue.main.async {
                    guard let self else { return }
                    self.linkUp = up
                    if up { self.hasConnectedOnce = true }
                    // The window may have resized while the link was down.
                    if up { self.pty?.resize(self.size) }
                    self.delegate?.sessionLinkChanged(self)
                }
            }
            label = remote.label
            remote.onLabel = { [weak self] label in
                DispatchQueue.main.async {
                    guard let self, self.label != label else { return }
                    self.label = label
                    self.delegate?.sessionLabelChanged(self)
                }
            }
            remote.startReading()
        } else if let local = backend as? PTY {
            local.startReading()
        }
        pty = backend
    }

    /// End the program (its pane is closing).
    func terminate() { pty?.terminate() }

    /// Let go of the session without ending it, as quitting does (probes).
    func detachForProbe() { pty?.detach() }

    /// The program ended (main thread).
    private(set) var hasExited = false

    /// (count, time of the latest) output parsed, for `--latency-trace`.
    var outputMark: (count: UInt64, time: CFTimeInterval) { lock.withLock { (outputCount, lastOutputTime) } }

    /// The shell (or command) process, for the inspector's process list.
    var shellPID: pid_t? { host == nil ? pty?.pid : nil }

    /// On a host only the shell integration's marks can say.
    var hasForegroundProgram: Bool {
        host == nil ? pty?.hasForegroundProgram ?? false : lock.withLock { promptState == .running }
    }

    /// The process group in front of a shell's terminal: its leader's pid
    /// and name. Nil means the shell itself is in front, or that it's gone.
    /// Two kernel calls: fine to ask about every pane once a second.
    ///
    /// A pid rather than a session, so the window can ask off the main
    /// thread. The leader is what a shell's job is: for `git log | less`
    /// that's `git`, and for `( sleep 10 )` the subshell.
    static func foregroundProcess(ofShell shell: pid_t) -> (pgid: pid_t, name: String)? {
        let pgid = libertty_proc_tty_pgid(shell)
        guard pgid > 0, pgid != shell else { return nil }
        let name = processName(pgid)
        return name.isEmpty ? nil : (pgid, name)
    }

    /// What a foreground process runs, when its own name doesn't say: a
    /// language runtime or a shell is in front, and the program is either
    /// one it started — `tclaude` is node starting `claude` — or the script
    /// it was handed (`node …/node_modules/@anthropic-ai/claude-code/cli.js`).
    /// Costlier than foregroundProcess: it walks the leader's children and
    /// reads its arguments (which can fault the process's pages back in).
    static func identify(_ process: (pgid: pid_t, name: String)) -> (name: String, arguments: String) {
        // ssh names its host in its arguments: the tab says where it went.
        if ["ssh", "mosh", "mosh-client"].contains(process.name.lowercased()) {
            var argv = [CChar](repeating: 0, count: 1024)
            _ = libertty_proc_argv(process.pgid, &argv, Int32(argv.count))
            return (process.name, String(cString: argv))
        }
        guard ProgramBadge.runsAnotherProgram(process.name) else { return (process.name, "") }
        // Children before grandchildren, and a wrapper is a level or two.
        var children = [pid_t](repeating: 0, count: 16)
        let count = Int(libertty_proc_descendants(process.pgid, &children, Int32(children.count)))
        for child in children.prefix(count) {
            let name = processName(child)
            if ProgramBadge.isOftenWrapped(name) { return (name, "") }
        }
        var argv = [CChar](repeating: 0, count: 1024)
        _ = libertty_proc_argv(process.pgid, &argv, Int32(argv.count))
        return (process.name, String(cString: argv))
    }

    private static func processName(_ pid: pid_t) -> String {
        var buf = [CChar](repeating: 0, count: 64)
        libertty_proc_name(pid, &buf, Int32(buf.count))
        return String(cString: buf)
    }

    // MARK: Output (io queue)

    private func feed(_ bytes: UnsafeBufferPointer<UInt8>) {
        // The reader may hand over up to a megabyte at once; parse it in
        // slices so the render thread's snapshot never waits long for the lock.
        let slice = 1 << 16
        var offset = 0
        while offset < bytes.count {
            let n = min(slice, bytes.count - offset)
            lock.withLock {
                ghostty_terminal_vt_write(terminal, bytes.baseAddress! + offset, n)
                outputCount &+= 1
                lastOutputTime = CACurrentMediaTime()
            }
            offset += n
            requestRender()
        }
    }

    /// Coalesce: one main-thread hop per frame's worth of output, not per slice.
    private func requestRender() {
        if renderPending.set() {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.sessionNeedsRender(self)
            }
        }
    }

    // MARK: Rendering (main thread)

    /// Snapshot everything needed to draw a frame. Returns false when nothing
    /// changed since the last call.
    @discardableResult
    func updateRenderState(_ state: GhosttyRenderState) -> Bool {
        let pending = renderPending.consume()
        lock.withLock {
            _ = ghostty_render_state_update(state, terminal)
            // Keep an open search in step with new output and scrolling.
            if search != nil, pending { refreshSearchLocked() }
        }
        return pending
    }

    /// Visible kitty-protocol images, and pixels for those `needs` doesn't
    /// have cached (main thread, with the render state).
    func kittyImages(cellWidth: Int, cellHeight: Int,
                     needs: (UInt32, UInt64) -> Bool) -> KittyImages.Collected {
        lock.withLock {
            var graphics: GhosttyKittyGraphics?
            var generation: UInt64 = 0
            // Nothing ever stored: skip the walk.
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_GRAPHICS, &graphics) == GHOSTTY_SUCCESS,
                  let graphics, ghostty_kitty_graphics_get(graphics, GHOSTTY_KITTY_GRAPHICS_DATA_GENERATION, &generation) == GHOSTTY_SUCCESS,
                  generation != 0 else { return KittyImages.Collected() }
            return KittyImages.collect(terminal, cellWidth: cellWidth, cellHeight: cellHeight, needs: needs)
        }
    }

    // MARK: Size

    /// Reflow the grid immediately; tell the pty after the size settles, so a
    /// live resize or split animation sends one SIGWINCH instead of dozens.
    func resize(to newSize: GridSize, cellWidthPx: UInt32, cellHeightPx: UInt32) {
        guard newSize != size else { return }
        size = newSize
        lock.withLock {
            _ = ghostty_terminal_resize(terminal, newSize.cols, newSize.rows, cellWidthPx, cellHeightPx)
        }
        pendingPtyResize?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.pty?.resize(newSize) }
        pendingPtyResize = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Timing.ptyResizeDebounce, execute: work)
    }

    /// Tell the terminal its cell size in pixels without changing the grid
    /// (pixel-based features: kitty images, CSI 14 t). Resizing does it too.
    func setCellSize(widthPx: UInt32, heightPx: UInt32) {
        lock.withLock { _ = ghostty_terminal_resize(terminal, size.cols, size.rows, widthPx, heightPx) }
    }

    // MARK: Input (main thread)

    struct Key {
        var action: GhosttyKeyAction
        var key: GhosttyKey
        var mods: GhosttyMods
        var consumedMods: GhosttyMods
        var text: String?
        var unshiftedCodepoint: UInt32
        var composing: Bool
    }

    /// Encode a key with the terminal's current modes (cursor keys, kitty
    /// keyboard flags, ...) and send it. Returns whether anything was sent.
    @discardableResult
    func send(_ key: Key) -> Bool {
        // A text key whose only modifier is Shift goes out as its text.
        // Legacy encoding sends it that way anyway, and the kitty keyboard
        // protocol keeps shift+key out of CSI u as well: the spec's list of
        // keys reported as escape codes in disambiguate mode is "Esc,
        // alt+key, ctrl+key, ctrl+alt+key, shift+alt+key", and kitty, the
        // reference implementation, sends plain text. libghostty-vt encodes
        // CSI u with the unshifted key instead, which programs that don't
        // map every layout's shifted glyph mis-decode: tclaude turned
        // Shift+2 into "2". A program that asked for report-all (flag bit 3)
        // gets what it asked for.
        var plain: String?
        var flags: UInt8 = 0
        var out = [CChar](repeating: 0, count: 128)
        var len = 0
        let ok: Bool = lock.withLock {
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_KITTY_KEYBOARD_FLAGS, &flags)
            if key.action != GHOSTTY_KEY_ACTION_RELEASE, !key.composing,
               key.mods == GhosttyMods(GHOSTTY_MODS_SHIFT), flags & 0b1000 == 0,
               let text = key.text, !text.isEmpty {
                plain = text
                return true
            }
            ghostty_key_encoder_setopt_from_terminal(keyEncoder, terminal)
            // Reset by the call above: it can't be read from terminal state.
            ghostty_key_encoder_setopt(keyEncoder, GHOSTTY_KEY_ENCODER_OPT_MACOS_OPTION_AS_ALT, &optionAsAlt)
            ghostty_key_event_set_action(keyEvent, key.action)
            ghostty_key_event_set_key(keyEvent, key.key)
            ghostty_key_event_set_mods(keyEvent, key.mods)
            ghostty_key_event_set_consumed_mods(keyEvent, key.consumedMods)
            ghostty_key_event_set_composing(keyEvent, key.composing)
            ghostty_key_event_set_unshifted_codepoint(keyEvent, key.unshiftedCodepoint)
            let encode = { () -> Bool in
                ghostty_key_encoder_encode(self.keyEncoder, self.keyEvent, &out, out.count, &len) == GHOSTTY_SUCCESS
            }
            if let text = key.text, !text.isEmpty {
                return text.withCString { ptr in
                    ghostty_key_event_set_utf8(keyEvent, ptr, strlen(ptr))
                    return encode()
                }
            }
            ghostty_key_event_set_utf8(keyEvent, nil, 0)
            return encode()
        }
        if let text = plain {
            scrollToBottom()
            pty?.write(Data(text.utf8))
            return true
        }
        guard ok, len > 0 else { return false }
        scrollToBottom()
        pty?.write(Data(bytes: out, count: len))
        return true
    }

    /// Text committed by an input method goes to the program as-is.
    func sendText(_ text: String) {
        guard !text.isEmpty else { return }
        scrollToBottom()
        pty?.write(Data(text.utf8))
    }

    enum PasteOutcome { case pasted, nothing, needsConfirmation }

    /// Paste per the terminal's current state: bracketed paste (2004) or the
    /// kitty clipboard protocol (5522). Text that could inject commands is
    /// refused unless `allowUnsafe`, so the UI can confirm first.
    func paste(_ text: String, allowUnsafe: Bool) -> PasteOutcome {
        let source = PasteSource(text: text)
        var written = false
        let result: GhosttyResult = PasteSource.textPlain.withUnsafeBufferPointer { mimeBytes in
            var mime = GhosttyString(ptr: mimeBytes.baseAddress, len: mimeBytes.count)
            return withUnsafePointer(to: &mime) { mimes in
                var paste = GhosttyPaste()
                paste.size = MemoryLayout<GhosttyPaste>.size
                paste.location = GHOSTTY_CLIPBOARD_LOCATION_STANDARD
                paste.source = GHOSTTY_PASTE_SOURCE_CLIPBOARD
                paste.mimes = mimes
                paste.mimes_len = 1
                paste.reader = GhosttyMimeReader(read: pasteRead, userdata: Unmanaged.passUnretained(source).toOpaque())
                paste.allow_unsafe = allowUnsafe
                return lock.withLock {
                    // The pasted text comes back through the write callback: as input, not a reply.
                    pasting = true
                    defer { pasting = false }
                    return ghostty_terminal_paste(terminal, &paste, &written)
                }
            }
        }
        if result == GHOSTTY_REJECTED { return .needsConfirmation }
        if written { scrollToBottom() }
        return written ? .pasted : .nothing
    }

    /// Scroll the viewport by whole rows (negative is up, into scrollback).
    func scroll(rows delta: Int) {
        guard delta != 0 else { return }
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA
        behavior.value.delta = delta
        lock.withLock { ghostty_terminal_scroll_viewport(terminal, behavior) }
        markRenderPending()
    }

    func scrollToBottom() {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_BOTTOM
        lock.withLock { ghostty_terminal_scroll_viewport(terminal, behavior) }
        markRenderPending()
    }

    func scrollToTop() {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_TOP
        lock.withLock { ghostty_terminal_scroll_viewport(terminal, behavior) }
        markRenderPending()
    }

    /// A screenful up (negative) or down.
    func scroll(pages: Int) { scroll(rows: pages * Int(size.rows)) }

    /// Scroll so the `delta`th previous (negative) or next prompt is at the
    /// top; needs the shell's OSC 133 marks.
    func jumpToPrompt(_ delta: Int) {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_DELTA_PROMPT
        behavior.value.delta_prompt = delta
        lock.withLock { ghostty_terminal_scroll_viewport(terminal, behavior) }
        markRenderPending()
    }

    /// ⌘K, as Ghostty does it: at a prompt, clear the screen and scrollback
    /// and send a form feed so the shell redraws its prompt; while a program
    /// runs, clear the scrollback and the lines above the cursor only. Full-
    /// screen programs (alternate screen) are left alone.
    func clearScreen() {
        guard !isAlternateScreen else { return }
        var atPrompt = true
        lock.withLock {
            _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
            // Without shell integration nothing says a program is running:
            // behave like Terminal.app and clear it all.
            atPrompt = promptState != .running
        }
        // In liberttyd, liberttyd clears (its copy is the authority) and every window
        // gets the same clear through the output.
        if pty?.clear(atPrompt: atPrompt) == true { return markRenderPending() }
        lock.withLock {
            var x: UInt16 = 0, y: UInt16 = 0
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
            var sequence = "\u{1b}[3J"  // scrollback
            if atPrompt {
                sequence += "\u{1b}[H\u{1b}[2J"
            } else if y > 0 {
                // Erase from the top through the end of the row above the
                // cursor, then put the cursor back (CUP is one-based). Not
                // DECSC/DECRC: that would clobber the program's saved cursor.
                sequence += "\u{1b}[\(y);\(size.cols)H\u{1b}[1J\u{1b}[\(y + 1);\(x + 1)H"
            }
            let bytes = Array(sequence.utf8)
            ghostty_terminal_vt_write(terminal, bytes, bytes.count)
        }
        if atPrompt { pty?.write(Data([0x0C])) }
        markRenderPending()
    }

    // MARK: Mouse reporting (main thread)

    /// Whether the running program asked for mouse events (modes 1000/1002/1003...).
    var isMouseTracking: Bool {
        var tracking = false
        lock.withLock { _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_MOUSE_TRACKING, &tracking) }
        return tracking
    }

    /// Whether the alternate screen (full-screen programs like less, vim) is active.
    var isAlternateScreen: Bool {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        lock.withLock { _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen) }
        return screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    struct MouseInput {
        var action: GhosttyMouseAction
        /// nil for motion with no button held.
        var button: GhosttyMouseButton?
        var mods: GhosttyMods
        var positionPx: CGPoint
        var anyButtonPressed: Bool
        var surface: GhosttyMouseEncoderSize
    }

    /// Encode a mouse event in the format and tracking mode the program chose
    /// and send it. Returns whether anything was sent (the mode may filter it).
    @discardableResult
    func sendMouse(_ input: MouseInput) -> Bool {
        var out = [CChar](repeating: 0, count: 64)
        var len = 0
        let ok: Bool = lock.withLock {
            ghostty_mouse_encoder_setopt_from_terminal(mouseEncoder, terminal)
            var surface = input.surface
            surface.size = MemoryLayout<GhosttyMouseEncoderSize>.size
            ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_SIZE, &surface)
            var pressed = input.anyButtonPressed
            ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_ANY_BUTTON_PRESSED, &pressed)
            var trackLastCell = true  // motion reports only when the cell changes
            ghostty_mouse_encoder_setopt(mouseEncoder, GHOSTTY_MOUSE_ENCODER_OPT_TRACK_LAST_CELL, &trackLastCell)

            ghostty_mouse_event_set_action(mouseEvent, input.action)
            if let button = input.button {
                ghostty_mouse_event_set_button(mouseEvent, button)
            } else {
                ghostty_mouse_event_clear_button(mouseEvent)
            }
            ghostty_mouse_event_set_mods(mouseEvent, input.mods)
            ghostty_mouse_event_set_position(mouseEvent, GhosttyMousePosition(
                x: Float(input.positionPx.x), y: Float(input.positionPx.y)))
            return ghostty_mouse_encoder_encode(mouseEncoder, mouseEvent, &out, out.count, &len) == GHOSTTY_SUCCESS
        }
        guard ok, len > 0 else { return false }
        pty?.write(Data(bytes: out, count: len))
        return true
    }

    // MARK: Selection (main thread)

    enum PointerPhase { case press, drag, release }

    /// Where the pointer is, in grid cells and surface pixels, plus what the
    /// gesture engine needs to turn drags into cell/word/line selections.
    struct Pointer {
        var col: Int
        var row: Int
        var positionPx: CGPoint
        var cellWidthPx: Int
        var paddingLeftPx: Int
        var surfaceHeightPx: Int
    }

    enum Autoscroll { case none, up, down }

    /// Feed a mouse event to libghostty-vt's selection gesture (single click
    /// selects cells, double words, triple lines; drags extend; `rectangle`
    /// selects a block) and apply the resulting selection to the terminal.
    /// A drag past the top or bottom asks to autoscroll.
    @discardableResult
    func selectionGesture(_ phase: PointerPhase, _ pointer: Pointer, rectangle: Bool = false) -> Autoscroll {
        defer { markRenderPending() }
        return lock.withLock { () -> Autoscroll in
            let event: GhosttySelectionGestureEvent = switch phase {
            case .press: gesturePress
            case .drag: gestureDrag
            case .release: gestureRelease
            }

            guard var ref = viewportRef(pointer) else { return .none }
            _ = ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REF, &ref)

            var position = GhosttySurfacePosition(x: Double(pointer.positionPx.x), y: Double(pointer.positionPx.y))
            if phase != .release {
                _ = ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
            }
            if phase == .press {
                var now = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
                var interval = UInt64(NSEvent.doubleClickInterval * 1e9)
                var distance = Double(pointer.cellWidthPx)
                _ = ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_TIME_NS, &now)
                _ = ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_INTERVAL_NS, &interval)
                _ = ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_REPEAT_DISTANCE, &distance)
            }
            if phase == .drag {
                var geometry = geometry(pointer)
                _ = ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry)
                var block = rectangle
                _ = ghostty_selection_gesture_event_set(event, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &block)
            }

            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            let result = ghostty_selection_gesture_event(gesture, terminal, event, &selection)
            if result == GHOSTTY_SUCCESS {
                _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
            } else if phase == .press {
                // A plain click starts over: drop the old selection.
                _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
            }
            guard phase == .drag else { return .none }
            var direction = GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_NONE
            _ = ghostty_selection_gesture_get(gesture, terminal, GHOSTTY_SELECTION_GESTURE_DATA_AUTOSCROLL, &direction)
            switch direction {
            case GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_UP: return .up
            case GHOSTTY_SELECTION_GESTURE_AUTOSCROLL_DOWN: return .down
            default: return .none
            }
        }
    }

    /// One autoscroll step while a selection drag is held past an edge:
    /// scroll `rows` and extend the selection to the pointer's new cell.
    func selectionAutoscroll(_ direction: Autoscroll, rows: Int, _ pointer: Pointer, rectangle: Bool) {
        guard direction != .none else { return }
        scroll(rows: direction == .up ? -rows : rows)
        lock.withLock {
            var at = GhosttyPointCoordinate(x: UInt16(clamping: max(0, min(pointer.col, Int(size.cols) - 1))),
                                            y: UInt32(direction == .up ? 0 : max(0, Int(size.rows) - 1)))
            _ = ghostty_selection_gesture_event_set(gestureTick, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_VIEWPORT, &at)
            var geometry = geometry(pointer)
            _ = ghostty_selection_gesture_event_set(gestureTick, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_GEOMETRY, &geometry)
            var position = GhosttySurfacePosition(x: Double(pointer.positionPx.x), y: Double(pointer.positionPx.y))
            _ = ghostty_selection_gesture_event_set(gestureTick, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_POSITION, &position)
            var block = rectangle
            _ = ghostty_selection_gesture_event_set(gestureTick, GHOSTTY_SELECTION_GESTURE_EVENT_OPT_RECTANGLE, &block)
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            if ghostty_selection_gesture_event(gesture, terminal, gestureTick, &selection) == GHOSTTY_SUCCESS {
                _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
            }
        }
        markRenderPending()
    }

    /// Shift-click: grow (or shrink) the selection to the clicked cell, from
    /// its far end. Returns false when there's nothing selected to extend.
    func extendSelection(to pointer: Pointer) -> Bool {
        defer { markRenderPending() }
        return lock.withLock {
            var current = GhosttySelection()
            current.size = MemoryLayout<GhosttySelection>.size
            guard ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SELECTION, &current) == GHOSTTY_SUCCESS,
                  let click = viewportRef(pointer) else { return false }
            // Screen order: row, then column, as one number.
            func order(_ ref: GhosttyGridRef) -> UInt64? {
                var r = ref
                var p = GhosttyPointCoordinate()
                guard ghostty_terminal_point_from_grid_ref(terminal, &r, GHOSTTY_POINT_TAG_SCREEN, &p) == GHOSTTY_SUCCESS else { return nil }
                return UInt64(p.y) << 16 | UInt64(p.x)
            }
            guard let a = order(current.start), let b = order(current.end), let c = order(click) else { return false }
            let (first, last) = a <= b ? (current.start, current.end) : (current.end, current.start)
            let firstAt = min(a, b)
            var extended = GhosttySelection()
            extended.size = MemoryLayout<GhosttySelection>.size
            extended.rectangle = current.rectangle
            // Clicked before the selection: keep its end, else keep its start.
            if c < firstAt { (extended.start, extended.end) = (click, last) } else { (extended.start, extended.end) = (first, click) }
            return ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &extended) == GHOSTTY_SUCCESS
        }
    }

    /// With `lock` held: the grid cell under the pointer (clamped to the grid).
    private func viewportRef(_ pointer: Pointer) -> GhosttyGridRef? {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_VIEWPORT
        point.value.coordinate = GhosttyPointCoordinate(
            x: UInt16(clamping: max(0, min(pointer.col, Int(size.cols) - 1))),
            y: UInt32(clamping: max(0, min(pointer.row, Int(size.rows) - 1))))
        var ref = GhosttyGridRef()
        ref.size = MemoryLayout<GhosttyGridRef>.size
        return ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    private func geometry(_ pointer: Pointer) -> GhosttySelectionGestureGeometry {
        GhosttySelectionGestureGeometry(
            columns: UInt32(size.cols), cell_width: UInt32(max(1, pointer.cellWidthPx)),
            padding_left: UInt32(max(0, pointer.paddingLeftPx)),
            screen_height: UInt32(max(1, pointer.surfaceHeightPx)))
    }

    func selectAll() {
        lock.withLock {
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            if ghostty_terminal_select_all(terminal, &selection) == GHOSTTY_SUCCESS {
                _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
            }
        }
        markRenderPending()
    }

    func clearSelection() {
        lock.withLock { _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, nil) }
        markRenderPending()
    }

    /// The selected text as plain text, soft-wrapped lines joined, or nil
    /// when nothing is selected.
    func selectedText() -> String? {
        lock.withLock {
            var options = GhosttyTerminalSelectionFormatOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
            options.emit = GHOSTTY_FORMATTER_FORMAT_PLAIN
            options.unwrap = true
            options.trim = true
            options.selection = nil  // the terminal's active selection
            var ptr: UnsafeMutablePointer<UInt8>?
            var len = 0
            guard ghostty_terminal_selection_format_alloc(terminal, nil, options, &ptr, &len) == GHOSTTY_SUCCESS,
                  let ptr else { return nil }
            defer { ghostty_free(nil, ptr, len) }
            return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
        }
    }

    func setFocused(_ focused: Bool) {
        if focused { programStatus.markSeen() }
    }

    /// Cursor cell in the active screen (for placing the IME candidate window).
    var cursorPosition: (x: UInt16, y: UInt16) {
        var x: UInt16 = 0, y: UInt16 = 0
        lock.withLock {
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
        }
        return (x, y)
    }

    private func markRenderPending() {
        _ = renderPending.set()
    }

    // MARK: Settings (main thread)

    /// Apply the user's settings: colors, scrollback, default cursor and
    /// Option-key behavior. Colors a program set itself (OSC 4/10/11) keep
    /// precedence, as in every terminal.
    func apply(_ config: Config) {
        let theme = config.resolvedTheme
        var palette = theme.palette256
        for (i, c) in config.palette where i >= 16 && i < 256 { palette[i] = c }
        var colors = palette.map { GhosttyColorRgb(r: $0.r, g: $0.g, b: $0.b) }
        var fg = GhosttyColorRgb(theme.foreground), bg = GhosttyColorRgb(theme.background)
        var cursor = GhosttyColorRgb(theme.cursor)
        var style: GhosttyTerminalCursorStyle = switch config.cursorStyle {
        case .block: GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK
        case .bar: GHOSTTY_TERMINAL_CURSOR_STYLE_BAR
        case .underline: GHOSTTY_TERMINAL_CURSOR_STYLE_UNDERLINE
        case .block_hollow: GHOSTTY_TERMINAL_CURSOR_STYLE_BLOCK_HOLLOW
        }
        lock.withLock {
            set(GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &fg)
            set(GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &bg)
            set(GHOSTTY_TERMINAL_OPT_COLOR_CURSOR, &cursor)
            colors.withUnsafeMutableBufferPointer { set(GHOSTTY_TERMINAL_OPT_COLOR_PALETTE, $0.baseAddress) }
            TerminalDefaults.setScrollback(terminal, config.scrollbackLimit)
            set(GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_STYLE, &style)
            // Unset: blink by default (Ghostty's default); set: that default.
            var blink = config.cursorStyleBlink ?? true
            set(GHOSTTY_TERMINAL_OPT_DEFAULT_CURSOR_BLINK, &blink)
        }
        lock.withLock {
            clipboardRead = config.clipboardRead
            clipboardWrite = config.clipboardWrite
        }
        optionAsAlt = switch config.optionAsAlt {
        case .false: GHOSTTY_OPTION_AS_ALT_FALSE
        case .true: GHOSTTY_OPTION_AS_ALT_TRUE
        case .left: GHOSTTY_OPTION_AS_ALT_LEFT
        case .right: GHOSTTY_OPTION_AS_ALT_RIGHT
        }
        markRenderPending()
    }

    // MARK: Setup

    private func configureTerminal() {
        let me = UnsafeRawPointer(Unmanaged.passUnretained(self).toOpaque())
        set(GHOSTTY_TERMINAL_OPT_USERDATA, me)
        set(GHOSTTY_TERMINAL_OPT_WRITE_PTY, unsafeBitCast(onWritePty, to: UnsafeRawPointer.self))
        set(GHOSTTY_TERMINAL_OPT_BELL, unsafeBitCast(onBell, to: UnsafeRawPointer.self))
        set(GHOSTTY_TERMINAL_OPT_TITLE_CHANGED, unsafeBitCast(onTitleChanged, to: UnsafeRawPointer.self))
        set(GHOSTTY_TERMINAL_OPT_PROGRAM_STATUS, unsafeBitCast(onProgramStatus, to: UnsafeRawPointer.self))
        set(GHOSTTY_TERMINAL_OPT_SEMANTIC_PROMPT, unsafeBitCast(onSemanticPrompt, to: UnsafeRawPointer.self))
        set(GHOSTTY_TERMINAL_OPT_RESET, unsafeBitCast(onReset, to: UnsafeRawPointer.self))
        set(GHOSTTY_TERMINAL_OPT_PWD_CHANGED, unsafeBitCast(onPwdChanged, to: UnsafeRawPointer.self))
        set(GHOSTTY_TERMINAL_OPT_DESKTOP_NOTIFICATION, unsafeBitCast(onDesktopNotification, to: UnsafeRawPointer.self))
        set(GHOSTTY_TERMINAL_OPT_PROGRESS_REPORT, unsafeBitCast(onProgressReport, to: UnsafeRawPointer.self))
        set(GHOSTTY_TERMINAL_OPT_CLIPBOARD_WRITE, unsafeBitCast(onClipboardWrite, to: UnsafeRawPointer.self))
        set(GHOSTTY_TERMINAL_OPT_CLIPBOARD_READ, unsafeBitCast(onClipboardRead, to: UnsafeRawPointer.self))

        // Shared with liberttyd's copy, which must parse the same way.
        TerminalDefaults.apply(to: terminal, scrollback: ConfigStore.shared.config.scrollbackLimit)
        KittyImages.installDecoder()
        KittyImages.enable(on: terminal)
    }

    /// After restoring a snapshot: what the callbacks would have told us.
    private func adoptRestoredState() {
        var s = GhosttyString()
        if ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &s) == GHOSTTY_SUCCESS { title = String(s) }
        var p = GhosttyString()
        // A screen that never heard where its shell is keeps the folder known
        // so far (a host pane's, from its layout).
        if ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &p) == GHOSTTY_SUCCESS,
           let path = Self.path(fromPwd: String(p), remote: host != nil) {
            workingDirectory = path
        }
    }

    /// liberttyd was replaced and output may have gone by while we redialed:
    /// switch to its current state (on `io`).
    /// `reassertSize`: after a redial, tell liberttyd our size again (the
    /// window may have resized while it was away).
    private func replaceTerminal(with snapshot: Data, reassertSize: Bool = true) {
        guard let restored = Snapshots.decode(snapshot, trackContinuation: false) else { return }
        // A search in progress goes on in the new copy: the find bar is
        // still open, and a catch-up comes exactly when output floods.
        var needle: String?
        lock.withLock {
            if let search {
                var s = GhosttyString()
                if ghostty_search_get(search, GHOSTTY_SEARCH_DATA_NEEDLE, &s) == GHOSTTY_SUCCESS {
                    needle = String(borrowed: s)
                }
                ghostty_search_free(search)
            }
            search = nil
            searchResult = SearchResult()
            var g: GhosttySelectionGesture?
            ghostty_selection_gesture_free(gesture, terminal)
            if ghostty_selection_gesture_new(nil, &g) == GHOSTTY_SUCCESS, let g { gesture = g }
            ghostty_terminal_free(terminal)
            terminal = restored
            configureTerminal()
            var cols: UInt16 = 0, rows: UInt16 = 0
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols)
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, &rows)
            // Back to our size (the window may have resized meanwhile).
            if cols != size.cols || rows != size.rows {
                let cw = UInt32(size.widthPx) / UInt32(max(1, size.cols)), ch = UInt32(size.heightPx) / UInt32(max(1, size.rows))
                _ = ghostty_terminal_resize(terminal, size.cols, size.rows, cw, ch)
            }
        }
        let config = ConfigStore.shared.config
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.apply(config)
            if reassertSize { self.pty?.resize(self.size) }
            self.adoptRestoredState()
            self.delegate?.sessionTitleChanged(self, title: self.title)
            if let needle, !needle.isEmpty { self.find(needle) }
        }
        requestRender()
    }

    private func set(_ option: GhosttyTerminalOption, _ value: UnsafeRawPointer?) {
        _ = ghostty_terminal_set(terminal, option, value)
    }

    // MARK: Callbacks (io queue, inside vt_write with `lock` held — never re-lock)

    fileprivate func writeToPty(_ data: UnsafePointer<UInt8>, _ len: Int) {
        let bytes = Data(bytes: data, count: len)
        if pasting { pty?.write(bytes) } else { pty?.writeReply(bytes) }
    }

    fileprivate func titleDidChange() {
        var s = GhosttyString()
        let title = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_TITLE, &s) == GHOSTTY_SUCCESS
            ? String(s) : ""
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.title = title
            self.delegate?.sessionTitleChanged(self, title: title)
        }
    }

    fileprivate func bell() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.sessionBell(self)
        }
    }

    fileprivate func receive(_ report: ProgramStatusStore.Report) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.programStatus.apply(report)
            self.delegate?.sessionProgramStatusChanged(self)
        }
    }

    /// Called with `lock` held, from the semantic-prompt callback.
    fileprivate func semanticPrompt(_ event: GhosttyTerminalSemanticPrompt) {
        switch event.kind {
        case GHOSTTY_SEMANTIC_PROMPT_PROMPT_START, GHOSTTY_SEMANTIC_PROMPT_INPUT_START:
            promptState = .prompt
        case GHOSTTY_SEMANTIC_PROMPT_COMMAND_END:
            promptState = .prompt
            guard let start = commandStart else { break }
            commandStart = nil
            let duration = CACurrentMediaTime() - start.time
            let exit: Int32? = event.has_exit_code ? event.exit_code : nil
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.delegate?.sessionCommandFinished(self, command: start.command, exitCode: exit, duration: duration)
            }
        case GHOSTTY_SEMANTIC_PROMPT_OUTPUT_START:
            promptState = .running
            commandStart = (CACurrentMediaTime(), ProgramStatusStore.sanitize(String(event.command)))
        default: break
        }
    }

    fileprivate func desktopNotification(title: String, body: String) {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.delegate?.sessionDesktopNotification(self, title: ProgramStatusStore.sanitize(title),
                                                      body: ProgramStatusStore.sanitize(body))
        }
    }

    fileprivate func progressReport(_ progress: TerminalProgress?) {
        DispatchQueue.main.async { [weak self] in
            guard let self, self.progress != progress else { return }
            self.progress = progress
            self.delegate?.sessionProgressChanged(self)
        }
    }

    /// OSC 52 copy (with `lock` held): text goes to the clipboard on main.
    fileprivate func writeClipboard(_ request: UnsafePointer<GhosttyClipboardWrite>) -> Bool {
        let write = request.pointee
        guard clipboardWrite, write.location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD else { return false }
        var text: String?
        for i in 0..<write.contents_len {
            let content = write.contents[i]
            let mime = String(content.mime)
            if mime.hasPrefix("text/plain") || mime == "text" || mime == "UTF8_STRING" { text = String(content.data); break }
        }
        if write.contents_len == 0 { text = "" }
        guard let text else { return false }
        DispatchQueue.main.async {
            NSPasteboard.general.clearContents()
            if !text.isEmpty { NSPasteboard.general.setString(text, forType: .string) }
        }
        return true
    }

    /// OSC 52 paste request (with `lock` held): only when `clipboard-read = allow`.
    fileprivate var clipboardReadAllowed: Bool { clipboardRead }

    fileprivate func promptStarted() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.programStatus.programFinished()
            self.delegate?.sessionProgramStatusChanged(self)
            // Back at the prompt: a program that forgot to clear its progress is done.
            if self.progress != nil {
                self.progress = nil
                self.delegate?.sessionProgressChanged(self)
            }
        }
    }

    fileprivate func pwdDidChange() {
        var s = GhosttyString()
        let raw = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_PWD, &s) == GHOSTTY_SUCCESS ? String(s) : ""
        // Only copy here: parsing touches the file system, and this runs with `lock` held.
        DispatchQueue.main.async { [weak self] in
            guard let self, let path = Self.path(fromPwd: raw, remote: self.host != nil), path != self.workingDirectory
            else { return }
            self.workingDirectory = path
            self.delegate?.sessionWorkingDirectoryChanged(self)
        }
    }

    /// From gethostname(2), not ProcessInfo.hostName: that one resolves the
    /// name over the network and can block for seconds.
    private static let localHostName: String = {
        var buf = [CChar](repeating: 0, count: Int(MAXHOSTNAMELEN) + 1)
        return gethostname(&buf, buf.count) == 0 ? String(cString: buf).lowercased() : ""
    }()

    /// OSC 7 carries a `file://host/path` URL (percent-encoded); OSC 9 and
    /// OSC 1337 carry a bare path. On this Mac only local, existing
    /// directories count; a host's session (`remote`) reports the host's
    /// own, whose files aren't here to check.
    static func path(fromPwd raw: String, remote: Bool = false) -> String? {
        var path = raw
        if raw.hasPrefix("file://") {
            guard let url = URL(string: raw), url.isFileURL else { return nil }
            if !remote, let host = url.host?.lowercased(), !host.isEmpty, host != "localhost",
               host != Self.localHostName, !Self.localHostName.hasPrefix(host + ".") {
                return nil  // a remote shell (ssh) reported its directory
            }
            path = url.path
        }
        guard path.hasPrefix("/") else { return nil }
        if remote { return path }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else { return nil }
        return path
    }

    fileprivate func didReset() {
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            self.title = ""
            self.delegate?.sessionTitleChanged(self, title: "")
        }
    }

    // MARK: Environment

    /// What a new session runs: the login shell with Libertty's integration, or
    /// `command` through /bin/sh -c; with Libertty's environment.
    static func launchSpec(command: String?, shell: String? = nil) -> (executable: String, arguments: [String], environment: [String: String]) {
        var environment = Self.environment()
        if let command { return ("/bin/sh", ["sh", "-c", command], environment) }
        let shell = shell ?? Self.loginShell()
        // A leading dash in argv[0] makes it a login shell.
        var arguments = ["-" + (shell as NSString).lastPathComponent]
        Self.injectShellIntegration(shell: shell, arguments: &arguments, environment: &environment)
        return (shell, arguments, environment)
    }

    private static func loginShell() -> String {
        if let pw = getpwuid(getuid()), let shell = pw.pointee.pw_shell {
            let path = String(cString: shell)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    private static func environment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Another terminal's identity must not leak into ours.
        for key in env.keys where key.hasPrefix("TERM_PROGRAM") || key.hasPrefix("ITERM_")
            || key.hasPrefix("KITTY_") || key.hasPrefix("GHOSTTY_") || key == "TERMINFO" {
            env[key] = nil
        }
        // libghostty-vt is Ghostty's terminal, so Ghostty's terminfo describes
        // it exactly (undercurl, synchronized output, …); the app ships it.
        let config = ConfigStore.shared.config
        if config.term == "xterm-ghostty", let terminfo = AppResources.url("terminfo") {
            env["TERM"] = "xterm-ghostty"
            env["TERMINFO"] = terminfo.path
            // Remote hosts may not know it: Libertty's shell integration has ssh use this.
            if config.sshEnv { env["LIBERTTY_SSH_TERM"] = "xterm-256color" }
        } else {
            env["TERM"] = config.term == "xterm-ghostty" ? "xterm-256color" : config.term
        }
        env["COLORTERM"] = "truecolor"
        env["TERM_PROGRAM"] = "Libertty"
        env["TERM_PROGRAM_VERSION"] = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        if env["LANG"] == nil { env["LANG"] = "en_US.UTF-8" }
        // The `libertty` command, appended so it never shadows anything.
        if let bin = AppResources.url("bin") {
            env["PATH"] = (env["PATH"] ?? "/usr/bin:/bin:/usr/sbin:/sbin") + ":" + bin.path
        }
        if let exe = Bundle.main.executablePath { env["LIBERTTY_EXECUTABLE"] = exe }
        return env
    }

    /// Load Libertty's shell integration (OSC 133 prompt marks, OSC 7 cwd)
    /// without touching the user's dotfiles. Each shell has a hook for
    /// loading startup code from elsewhere; the integration script then
    /// restores the original setting and loads the user's own files.
    private static func injectShellIntegration(shell: String, arguments: inout [String],
                                               environment env: inout [String: String]) {
        switch (shell as NSString).lastPathComponent {
        case "zsh":
            // zsh reads its startup files from ZDOTDIR.
            guard let dir = AppResources.url("shell-integration/zsh") else { return }
            if let original = env["ZDOTDIR"] { env["LIBERTTY_ZSH_ZDOTDIR"] = original }
            env["ZDOTDIR"] = dir.path
        case "bash":
            // An interactive non-login bash reads --rcfile instead of
            // ~/.bashrc; the script runs the login files bash would have.
            guard let script = AppResources.url("shell-integration/bash/libertty.bash") else { return }
            arguments = ["bash", "--rcfile", script.path, "-i"]
            env["LIBERTTY_BASH_LOGIN"] = "1"
        case "fish":
            // fish sources vendor_conf.d from every XDG data dir.
            guard let dir = AppResources.url("shell-integration/fish") else { return }
            if let original = env["XDG_DATA_DIRS"] { env["LIBERTTY_FISH_XDG_DATA_DIRS"] = original }
            let existing = env["XDG_DATA_DIRS"] ?? "/usr/local/share:/usr/share"
            env["XDG_DATA_DIRS"] = dir.path + ":" + existing
        default:
            break
        }
    }
}

enum TerminalError: Error {
    case libghostty(String)
}

// MARK: - C callbacks

private func session(_ userdata: UnsafeMutableRawPointer?) -> TerminalSession? {
    userdata.map { Unmanaged<TerminalSession>.fromOpaque($0).takeUnretainedValue() }
}

private let onWritePty: GhosttyTerminalWritePtyFn = { _, userdata, data, len in
    guard let data, len > 0 else { return }
    session(userdata)?.writeToPty(data, len)
}

private let onBell: GhosttyTerminalBellFn = { _, userdata in
    session(userdata)?.bell()
}

private let onTitleChanged: GhosttyTerminalTitleChangedFn = { _, userdata in
    session(userdata)?.titleDidChange()
}

private let onProgramStatus: GhosttyTerminalProgramStatusFn = { _, userdata, report in
    guard let report = report?.pointee, let s = session(userdata) else { return }
    let state: ProgramStatusStore.State = switch report.state {
    case GHOSTTY_PROGRAM_STATUS_STATE_WORKING: .working
    case GHOSTTY_PROGRAM_STATUS_STATE_DONE: .done
    case GHOSTTY_PROGRAM_STATUS_STATE_BLOCKED: .blocked
    case GHOSTTY_PROGRAM_STATUS_STATE_ERROR: .error
    default: .idle
    }
    let kind: ProgramStatusStore.Kind = switch report.kind {
    case GHOSTTY_PROGRAM_STATUS_KIND_PERMISSION: .permission
    case GHOSTTY_PROGRAM_STATUS_KIND_QUESTION: .question
    case GHOSTTY_PROGRAM_STATUS_KIND_AUTH: .auth
    default: .none
    }
    // Strings are only valid during this call: copy them now.
    s.receive(.init(
        clear: report.state == GHOSTTY_PROGRAM_STATUS_STATE_CLEAR,
        state: state, kind: kind,
        progress: report.progress >= 0 ? Int(report.progress) : nil,
        id: String(report.id), app: String(report.app),
        title: String(report.title), message: String(report.message)))
}

private let onSemanticPrompt: GhosttyTerminalSemanticPromptFn = { _, userdata, event in
    guard let event = event?.pointee, let s = session(userdata) else { return }
    s.semanticPrompt(event)
    guard event.kind == GHOSTTY_SEMANTIC_PROMPT_PROMPT_START,
          event.prompt_kind == GHOSTTY_SEMANTIC_PROMPT_PROMPT_PRIMARY else { return }
    s.promptStarted()
}

private let onReset: GhosttyTerminalResetFn = { _, userdata in
    session(userdata)?.didReset()
}

private let onPwdChanged: GhosttyTerminalPwdChangedFn = { _, userdata in
    session(userdata)?.pwdDidChange()
}

private let onDesktopNotification: GhosttyTerminalDesktopNotificationFn = { _, userdata, note in
    guard let note = note?.pointee, let s = session(userdata) else { return }
    s.desktopNotification(title: String(note.title), body: String(note.body))
}

private let onProgressReport: GhosttyTerminalProgressReportFn = { _, userdata, report in
    guard let report = report?.pointee, let s = session(userdata) else { return }
    let percent: Int? = report.progress >= 0 ? Int(min(100, report.progress)) : nil
    let progress: TerminalProgress? = switch report.state {
    case GHOSTTY_TERMINAL_PROGRESS_STATE_SET: TerminalProgress(state: .normal, percent: percent ?? 0)
    case GHOSTTY_TERMINAL_PROGRESS_STATE_ERROR: TerminalProgress(state: .error, percent: percent)
    case GHOSTTY_TERMINAL_PROGRESS_STATE_INDETERMINATE: TerminalProgress(state: .indeterminate, percent: nil)
    case GHOSTTY_TERMINAL_PROGRESS_STATE_PAUSE: TerminalProgress(state: .paused, percent: percent)
    default: nil
    }
    s.progressReport(progress)
}

private let onClipboardWrite: GhosttyTerminalClipboardWriteFn = { _, userdata, request in
    guard let request, let s = session(userdata) else { return }
    var reply = GhosttyClipboardWriteReply()
    reply.size = MemoryLayout<GhosttyClipboardWriteReply>.size
    reply.result = s.writeClipboard(request) ? GHOSTTY_CLIPBOARD_WRITE_RESULT_SUCCESS : GHOSTTY_CLIPBOARD_WRITE_RESULT_DENIED
    request.pointee.reply?(request, &reply)
}

private let onClipboardRead: GhosttyTerminalClipboardReadFn = { _, userdata, request in
    guard let request, let s = session(userdata) else { return }
    var reply = GhosttyClipboardReadReply()
    reply.size = MemoryLayout<GhosttyClipboardReadReply>.size
    guard s.clipboardReadAllowed, request.pointee.location == GHOSTTY_CLIPBOARD_LOCATION_STANDARD,
          let text = NSPasteboard.general.string(forType: .string) else {
        reply.result = GHOSTTY_CLIPBOARD_READ_RESULT_DENIED
        request.pointee.reply?(request, &reply)
        return
    }
    let mime = Array("text/plain".utf8), data = Array(text.utf8)
    mime.withUnsafeBufferPointer { m in
        data.withUnsafeBufferPointer { d in
            var content = GhosttyClipboardContent(mime: GhosttyString(ptr: m.baseAddress, len: m.count),
                                                  data: GhosttyString(ptr: d.baseAddress, len: d.count))
            withUnsafePointer(to: &content) { c in
                reply.result = GHOSTTY_CLIPBOARD_READ_RESULT_SUCCESS
                reply.contents = c
                reply.contents_len = 1
                request.pointee.reply?(request, &reply)
            }
        }
    }
}

private let pasteRead: GhosttyMimeReaderFn = { userdata, _, writer in
    guard let userdata, let write = writer.write else { return false }
    let source = Unmanaged<PasteSource>.fromOpaque(userdata).takeUnretainedValue()
    return source.bytes.withUnsafeBufferPointer { buf in
        write(writer.userdata, buf.baseAddress, buf.count)
    }
}

/// Clipboard text handed to libghostty-vt's paste reader.
private final class PasteSource {
    static let textPlain = Array("text/plain".utf8)
    let bytes: [UInt8]
    init(text: String) { bytes = Array(text.utf8) }
}

extension GhosttyColorRgb {
    init(_ c: RGB) { self.init(r: c.r, g: c.g, b: c.b) }
}

extension String {
    /// Copy a borrowed libghostty-vt string.
    init(_ s: GhosttyString) {
        guard let ptr = s.ptr, s.len > 0 else {
            self = ""
            return
        }
        self = String(decoding: UnsafeBufferPointer(start: ptr, count: s.len), as: UTF8.self)
    }
}

// MARK: - Find in scrollback

struct SearchResult: Equatable {
    /// One highlight per match row piece visible in the viewport.
    struct Highlight: Equatable { var row: Int; var columns: ClosedRange<Int>; var selected: Bool }
    var total = 0
    /// 1-based position of the selected match, newest first.
    var selected: Int?
    var highlights: [Highlight] = []
    var active = false
}

extension TerminalSession {
    /// Search for `needle` (ASCII case-insensitive), or with "" stop.
    /// Typing a longer needle restarts; the same needle keeps the results.
    func find(_ needle: String) {
        lock.withLock {
            if search == nil {
                var s: GhosttySearch?
                guard ghostty_search_new(nil, &s, terminal) == GHOSTTY_SUCCESS, let s else { return }
                search = s
            }
            let bytes = Array(needle.utf8)
            bytes.withUnsafeBufferPointer { buf in
                var str = GhosttyString(ptr: buf.baseAddress, len: buf.count)
                if needle.isEmpty {
                    _ = ghostty_search_set(search, GHOSTTY_SEARCH_OPT_NEEDLE, nil)
                } else {
                    _ = ghostty_search_set(search, GHOSTTY_SEARCH_OPT_NEEDLE, &str)
                }
            }
            guard !needle.isEmpty else {
                searchResult = SearchResult()
                return
            }
            _ = ghostty_search_run(search)
            // Start at the newest match, as find bars do from the prompt.
            _ = ghostty_search_set(search, GHOSTTY_SEARCH_OPT_SELECT_NEXT, nil)
            refreshSearchLocked()
        }
        markRenderPending()
    }

    /// Step to the next older (`forward`) or newer match, scrolling to it.
    func findNext(older: Bool) {
        lock.withLock {
            guard let search, searchResult.active else { return }
            _ = ghostty_search_set(search, older ? GHOSTTY_SEARCH_OPT_SELECT_NEXT : GHOSTTY_SEARCH_OPT_SELECT_PREV, nil)
            refreshSearchLocked()
        }
        markRenderPending()
    }

    func endSearch() {
        lock.withLock {
            if let search { ghostty_search_free(search) }
            search = nil
            searchResult = SearchResult()
        }
        markRenderPending()
    }

    /// Called with `lock` held: catch up with the terminal and recompute
    /// the count and the viewport highlights.
    fileprivate func refreshSearchLocked() {
        guard let search else { return }
        var needle = GhosttyString()
        guard ghostty_search_get(search, GHOSTTY_SEARCH_DATA_NEEDLE, &needle) == GHOSTTY_SUCCESS else {
            searchResult = SearchResult()
            return
        }
        // Bounded: a few feed/tick rounds per frame at most.
        for _ in 0..<8 {
            _ = ghostty_search_feed(search)
            var status = GHOSTTY_SEARCH_STATUS_RUNNING
            var ticks = 0
            while ghostty_search_tick(search, &status) == GHOSTTY_SUCCESS, status == GHOSTTY_SEARCH_STATUS_RUNNING, ticks < 64 {
                ticks += 1
            }
            if status == GHOSTTY_SEARCH_STATUS_COMPLETE { break }
        }
        var result = SearchResult(active: true)
        var total = 0
        _ = ghostty_search_get(search, GHOSTTY_SEARCH_DATA_TOTAL_MATCHES, &total)
        result.total = total
        var index = 0
        if ghostty_search_get(search, GHOSTTY_SEARCH_DATA_SELECTED_INDEX, &index) == GHOSTTY_SUCCESS { result.selected = index + 1 }

        var selectedRange: (GhosttyPointCoordinate, GhosttyPointCoordinate)?
        var selected = GhosttySelection()
        selected.size = MemoryLayout<GhosttySelection>.size
        if ghostty_search_get(search, GHOSTTY_SEARCH_DATA_SELECTED_MATCH, &selected) == GHOSTTY_SUCCESS {
            selectedRange = viewportRange(selected)
        }

        var buffer = GhosttySelectionBuffer(ptr: nil, cap: 0, len: 0)
        _ = ghostty_search_get(search, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &buffer)
        if buffer.len > 0 {
            var matches = [GhosttySelection](repeating: GhosttySelection(), count: buffer.len)
            for i in matches.indices { matches[i].size = MemoryLayout<GhosttySelection>.size }
            matches.withUnsafeMutableBufferPointer { ptr in
                buffer = GhosttySelectionBuffer(ptr: ptr.baseAddress, cap: ptr.count, len: 0)
                _ = ghostty_search_get(search, GHOSTTY_SEARCH_DATA_VIEWPORT_MATCHES, &buffer)
            }
            for m in matches.prefix(buffer.len) {
                guard let (a, b) = viewportRange(m) else { continue }
                let isSelected = selectedRange.map { $0.0.x == a.x && $0.0.y == a.y } ?? false
                let cols = Int(size.cols), rows = Int(size.rows)
                for y in Int(a.y)...Int(b.y) where y < rows {
                    let from = y == Int(a.y) ? Int(a.x) : 0
                    let to = y == Int(b.y) ? Int(b.x) : cols - 1
                    if from <= to { result.highlights.append(.init(row: y, columns: from...to, selected: isSelected)) }
                }
            }
        }
        searchResult = result
    }

    /// A match's endpoints in viewport cells, in reading order, or nil if off screen.
    private func viewportRange(_ selection: GhosttySelection) -> (GhosttyPointCoordinate, GhosttyPointCoordinate)? {
        var s = selection
        var a = GhosttyPointCoordinate(), b = GhosttyPointCoordinate()
        guard ghostty_terminal_point_from_grid_ref(terminal, &s.start, GHOSTTY_POINT_TAG_VIEWPORT, &a) == GHOSTTY_SUCCESS,
              ghostty_terminal_point_from_grid_ref(terminal, &s.end, GHOSTTY_POINT_TAG_VIEWPORT, &b) == GHOSTTY_SUCCESS
        else { return nil }
        return (a.y, a.x) <= (b.y, b.x) ? (a, b) : (b, a)
    }
}

// MARK: - Links

/// A link under the pointer: an OSC 8 hyperlink the program declared, or a
/// URL found in the text. `spans` are its cells in the viewport.
struct TerminalLink: Equatable {
    struct Span: Equatable { var row: Int; var columns: ClosedRange<Int> }
    var url: String
    var spans: [Span]
    /// Declared with OSC 8 (the visible text may say something else).
    var explicit: Bool
    /// For a file path written as `path:line[:column]` (compilers, grep, git).
    var line: Int? = nil
    var column: Int? = nil
}

extension TerminalSession {
    /// URLs written out in text: these schemes, up to whitespace or quotes.
    private static let urlPattern = try! NSRegularExpression(
        pattern: #"(?:https?|ftp|file)://[^\s<>"'`]+|mailto:[^\s<>"'`]+"#)

    /// Paths as tools print them: `src/a.swift:12:4`, `./x`, `~/y`, `/z/w.txt`.
    private static let pathPattern = try! NSRegularExpression(pattern: #"[~./]?[\w.@+\-]*(?:/[\w.@+\-]+)+/?(?::\d+){0,2}|[\w@+\-][\w.@+\-]*\.[A-Za-z]\w*(?::\d+){0,2}"#)

    /// The link at a viewport cell, if any: a URL (OSC 8 or written out), or
    /// a path to an existing file or folder (relative to the shell's
    /// directory). Looks along the whole logical line, so text soft-wrapped
    /// over several rows is found from any of them.
    func link(atCol col: Int, row: Int) -> TerminalLink? {
        guard let found = scanLink(atCol: col, row: row) else { return nil }
        if case .link(let link) = found { return link }
        // A host's paths can't be opened from here.
        guard case .path(let text, let spans) = found, host == nil else { return nil }
        return Self.resolvePath(text, spans: spans, in: workingDirectory)
    }

    private enum Scanned { case link(TerminalLink), path(String, [TerminalLink.Span]) }

    /// `path[:line[:column]]` → a file link, if the path exists.
    static func resolvePath(_ text: String, spans: [TerminalLink.Span], in directory: String?) -> TerminalLink? {
        var parts = text.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        var numbers: [Int] = []
        while parts.count > 1, let n = Int(parts.last!) { numbers.insert(n, at: 0); parts.removeLast() }
        var path = parts.joined(separator: ":")
        if path.hasSuffix("/") && path.count > 1 { path.removeLast() }
        guard !path.isEmpty else { return nil }
        var candidates: [String] = []
        if path.hasPrefix("~") { candidates.append((path as NSString).expandingTildeInPath) }
        else if path.hasPrefix("/") { candidates.append(path) }
        else if let directory {
            candidates.append((directory as NSString).appendingPathComponent(path))
            // git diff's a/… b/… prefixes.
            if path.hasPrefix("a/") || path.hasPrefix("b/") {
                candidates.append((directory as NSString).appendingPathComponent(String(path.dropFirst(2))))
            }
        }
        for candidate in candidates {
            let standardized = (candidate as NSString).standardizingPath
            guard FileManager.default.fileExists(atPath: standardized) else { continue }
            return TerminalLink(url: URL(fileURLWithPath: standardized).absoluteString, spans: spans, explicit: false,
                                line: numbers.first, column: numbers.count > 1 ? numbers[1] : nil)
        }
        return nil
    }

    private func scanLink(atCol col: Int, row: Int) -> Scanned? {
        lock.withLock { () -> Scanned? in
            let cols = Int(size.cols), rows = Int(size.rows)
            guard col >= 0, col < cols, row >= 0, row < rows else { return nil }

            func ref(_ x: Int, _ y: Int) -> GhosttyGridRef? {
                var point = GhosttyPoint()
                point.tag = GHOSTTY_POINT_TAG_VIEWPORT
                point.value.coordinate = GhosttyPointCoordinate(x: UInt16(x), y: UInt32(y))
                var r = GhosttyGridRef()
                r.size = MemoryLayout<GhosttyGridRef>.size
                return ghostty_terminal_grid_ref(terminal, point, &r) == GHOSTTY_SUCCESS ? r : nil
            }
            func wraps(_ y: Int) -> Bool {
                guard var r = ref(0, y) else { return false }
                var raw: GhosttyRow = 0
                var wrap = false
                guard ghostty_grid_ref_row(&r, &raw) == GHOSTTY_SUCCESS else { return false }
                _ = ghostty_row_get(raw, GHOSTTY_ROW_DATA_WRAP, &wrap)
                return wrap
            }
            func uri(_ r: inout GhosttyGridRef) -> String? {
                var len = 0
                guard ghostty_grid_ref_hyperlink_uri(&r, nil, 0, &len) == GHOSTTY_OUT_OF_SPACE, len > 0 else { return nil }
                var buf = [UInt8](repeating: 0, count: len)
                guard ghostty_grid_ref_hyperlink_uri(&r, &buf, len, &len) == GHOSTTY_SUCCESS else { return nil }
                return String(decoding: buf.prefix(len), as: UTF8.self)
            }

            // The logical line: rows joined by soft wraps (within the viewport).
            var first = row, last = row
            while first > 0, wraps(first - 1) { first -= 1 }
            while last < rows - 1, wraps(last) { last += 1 }

            // Text of the line, with each character's cell.
            var text = ""
            var cells: [(Int, Int)] = []  // per UTF-16 unit
            var uris: [String?] = []      // per cell in `cells` order
            var clicked: Int?
            var scalars = [UInt32](repeating: 0, count: 16)
            for y in first...last {
                for x in 0..<cols {
                    guard var r = ref(x, y) else { continue }
                    var raw: GhosttyCell = 0
                    var wide = GHOSTTY_CELL_WIDE_NARROW
                    if ghostty_grid_ref_cell(&r, &raw) == GHOSTTY_SUCCESS {
                        _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide)
                    }
                    if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }
                    var n = 0
                    var piece = " "
                    if ghostty_grid_ref_graphemes(&r, &scalars, scalars.count, &n) == GHOSTTY_SUCCESS, n > 0 {
                        piece = String(String.UnicodeScalarView(scalars.prefix(n).compactMap(Unicode.Scalar.init)))
                    }
                    var hasLink = false
                    _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_HAS_HYPERLINK, &hasLink)
                    let link = hasLink ? uri(&r) : nil
                    if x == col && y == row || (y == row && x == col - 1 && wide == GHOSTTY_CELL_WIDE_WIDE) {
                        clicked = cells.count
                    }
                    for _ in 0..<piece.utf16.count {
                        cells.append((y, x))
                        uris.append(link)
                    }
                    text += piece
                }
            }
            guard let at = clicked else { return nil }

            func spans(_ range: Range<Int>) -> [TerminalLink.Span] {
                var out: [TerminalLink.Span] = []
                for i in range {
                    let (y, x) = cells[i]
                    if let lastSpan = out.last, lastSpan.row == y, lastSpan.columns.upperBound >= x - 1 {
                        out[out.count - 1].columns = lastSpan.columns.lowerBound...max(lastSpan.columns.upperBound, x)
                    } else {
                        out.append(.init(row: y, columns: x...x))
                    }
                }
                return out
            }

            // A declared hyperlink wins: its cells, contiguous around the click.
            if let declared = uris[at] {
                var lo = at, hi = at
                while lo > 0, uris[lo - 1] == declared { lo -= 1 }
                while hi < uris.count - 1, uris[hi + 1] == declared { hi += 1 }
                return .link(TerminalLink(url: declared, spans: spans(lo..<(hi + 1)), explicit: true))
            }

            let ns = text as NSString
            for match in Self.urlPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                var range = match.range
                // Sentence punctuation after a URL isn't part of it; a closing
                // bracket is, when the URL opened one (Wikipedia-style links).
                while range.length > 0 {
                    let last = ns.substring(with: NSRange(location: range.location + range.length - 1, length: 1))
                    let body = ns.substring(with: range)
                    let opens = { (o: Character) in body.filter { $0 == o }.count }
                    if ".,;:!?".contains(last) { range.length -= 1; continue }
                    if last == ")", opens("(") < opens(")") { range.length -= 1; continue }
                    if last == "]", opens("[") < opens("]") { range.length -= 1; continue }
                    break
                }
                guard range.location <= at, at < range.location + range.length else { continue }
                return .link(TerminalLink(url: ns.substring(with: range), spans: spans(range.location..<(range.location + range.length)),
                                          explicit: false))
            }
            for match in Self.pathPattern.matches(in: text, range: NSRange(location: 0, length: ns.length)) {
                var range = match.range
                while range.length > 0, ".,;:)]}'\"".contains(ns.substring(with: NSRange(location: range.location + range.length - 1, length: 1))) {
                    range.length -= 1
                }
                guard range.length > 1, range.location <= at, at < range.location + range.length else { continue }
                return .path(ns.substring(with: range), spans(range.location..<(range.location + range.length)))
            }
            return nil
        }
    }
}

// MARK: - Accessibility

extension TerminalSession {
    /// The viewport as text, one string per row (trailing blanks trimmed),
    /// and the cursor's cell: what VoiceOver reads. Computed on demand.
    func viewportText() -> (lines: [String], cursor: (row: Int, col: Int)) {
        lock.withLock {
            let cols = Int(size.cols), rows = Int(size.rows)
            var lines: [String] = []
            lines.reserveCapacity(rows)
            var scalars = [UInt32](repeating: 0, count: 16)
            for y in 0..<rows {
                var line = ""
                for x in 0..<cols {
                    var point = GhosttyPoint()
                    point.tag = GHOSTTY_POINT_TAG_VIEWPORT
                    point.value.coordinate = GhosttyPointCoordinate(x: UInt16(x), y: UInt32(y))
                    var ref = GhosttyGridRef()
                    ref.size = MemoryLayout<GhosttyGridRef>.size
                    guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS else { continue }
                    var raw: GhosttyCell = 0
                    var wide = GHOSTTY_CELL_WIDE_NARROW
                    if ghostty_grid_ref_cell(&ref, &raw) == GHOSTTY_SUCCESS { _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_WIDE, &wide) }
                    if wide == GHOSTTY_CELL_WIDE_SPACER_TAIL || wide == GHOSTTY_CELL_WIDE_SPACER_HEAD { continue }
                    var n = 0
                    if ghostty_grid_ref_graphemes(&ref, &scalars, scalars.count, &n) == GHOSTTY_SUCCESS, n > 0 {
                        line.unicodeScalars.append(contentsOf: scalars.prefix(n).compactMap(Unicode.Scalar.init))
                    } else {
                        line.append(" ")
                    }
                }
                while line.hasSuffix(" ") { line.removeLast() }
                lines.append(line)
            }
            var cx: UInt16 = 0, cy: UInt16 = 0
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cx)
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cy)
            return (lines, (Int(cy), Int(cx)))
        }
    }
}

// MARK: - Scrollbar, command output, export

extension TerminalSession {
    struct Scrollbar: Equatable {
        /// Rows in all (scrollback + screen), where the viewport starts, and its height.
        var total: UInt64
        var offset: UInt64
        var length: UInt64
        var scrollable: Bool { total > length }
        var atBottom: Bool { offset + length >= total }
    }

    var scrollbar: Scrollbar {
        lock.withLock {
            var s = GhosttyTerminalScrollbar()
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &s)
            return Scrollbar(total: s.total, offset: s.offset, length: s.len)
        }
    }

    /// Put `row` (0 is the oldest line) at the top of the viewport.
    func scroll(toRow row: UInt64) {
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_SCROLL_VIEWPORT_ROW
        behavior.value.row = Int(row)
        lock.withLock { ghostty_terminal_scroll_viewport(terminal, behavior) }
        markRenderPending()
    }

    /// Smooth scrolling shows part of the row below the viewport: `body`
    /// reads it (screen row `y`) under the lock, through grid references
    /// only, so no dirty state a render state relies on is used up. Nil at
    /// the bottom, where there's nothing below.
    func withRowBelowViewport<R>(_ body: (GhosttyTerminal, UInt32) -> R) -> R? {
        lock.withLock {
            var s = GhosttyTerminalScrollbar()
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &s)
            guard s.offset + s.len < s.total else { return nil }
            return body(terminal, UInt32(s.offset + s.len))
        }
    }

    /// Select what the last finished command printed (between its command
    /// line and the next prompt, from OSC 133 marks). Returns false without
    /// shell integration or output.
    @discardableResult
    func selectLastCommandOutput() -> Bool {
        defer { markRenderPending() }
        return lock.withLock {
            var s = GhosttyTerminalScrollbar()
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_SCROLLBAR, &s)
            let total = Int(s.total)
            func ref(_ y: Int, _ x: Int = 0) -> GhosttyGridRef? {
                var point = GhosttyPoint()
                point.tag = GHOSTTY_POINT_TAG_SCREEN
                point.value.coordinate = GhosttyPointCoordinate(x: UInt16(x), y: UInt32(y))
                var r = GhosttyGridRef()
                r.size = MemoryLayout<GhosttyGridRef>.size
                return ghostty_terminal_grid_ref(terminal, point, &r) == GHOSTTY_SUCCESS ? r : nil
            }
            func isPrompt(_ y: Int) -> Bool {
                guard var r = ref(y) else { return false }
                var row: GhosttyRow = 0
                var state = GHOSTTY_ROW_SEMANTIC_NONE
                guard ghostty_grid_ref_row(&r, &row) == GHOSTTY_SUCCESS else { return false }
                _ = ghostty_row_get(row, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &state)
                return state != GHOSTTY_ROW_SEMANTIC_NONE
            }
            // From the bottom: the current prompt, then the output above it,
            // up to the previous command's prompt rows.
            var y = total - 1
            while y >= 0, !isPrompt(y) { y -= 1 }      // skip past anything under the prompt
            while y >= 0, isPrompt(y) { y -= 1 }       // the current prompt
            let last = y
            while y >= 0, !isPrompt(y) { y -= 1 }      // the output
            let first = y + 1
            guard y >= 0, first <= last, let start = ref(first), let end = ref(last, Int(size.cols) - 1) else { return false }
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            selection.start = start
            selection.end = end
            return ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_SELECTION, &selection) == GHOSTTY_SUCCESS
        }
    }

    /// The selection as HTML (colors and styles), for rich-text pasting.
    func selectedHTML() -> String? {
        lock.withLock {
            var options = GhosttyTerminalSelectionFormatOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
            options.emit = GHOSTTY_FORMATTER_FORMAT_HTML
            options.unwrap = true
            options.trim = true
            options.selection = nil
            var ptr: UnsafeMutablePointer<UInt8>?
            var len = 0
            guard ghostty_terminal_selection_format_alloc(terminal, nil, options, &ptr, &len) == GHOSTTY_SUCCESS,
                  let ptr, len > 0 else { return nil }
            defer { ghostty_free(nil, ptr, len) }
            return String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
        }
    }

    /// Everything: the scrollback and the screen, as plain text.
    func scrollbackText() -> String {
        lock.withLock { Snapshots.plainText(terminal, scrollback: true) }
    }
}

// MARK: - Web access

extension TerminalSession {
    struct WebScreen: Equatable {
        var html: String
        var cols: Int
        var rows: Int
        /// Row and column of the cursor in the active screen, when it shows.
        var cursor: [Int]?
    }

    /// The live screen (not the scrolled-back viewport) as HTML with colors
    /// and styles, for a browser showing this pane.
    func webScreen() -> WebScreen? {
        lock.withLock {
            let cols = Int(size.cols), rows = Int(size.rows)
            func ref(_ x: Int, _ y: Int) -> GhosttyGridRef? {
                var point = GhosttyPoint()
                point.tag = GHOSTTY_POINT_TAG_ACTIVE
                point.value.coordinate = GhosttyPointCoordinate(x: UInt16(x), y: UInt32(y))
                var r = GhosttyGridRef()
                r.size = MemoryLayout<GhosttyGridRef>.size
                return ghostty_terminal_grid_ref(terminal, point, &r) == GHOSTTY_SUCCESS ? r : nil
            }
            guard let start = ref(0, 0), let end = ref(cols - 1, rows - 1) else { return nil }
            var selection = GhosttySelection()
            selection.size = MemoryLayout<GhosttySelection>.size
            selection.start = start
            selection.end = end
            selection.rectangle = false
            var options = GhosttyTerminalSelectionFormatOptions()
            options.size = MemoryLayout<GhosttyTerminalSelectionFormatOptions>.size
            options.emit = GHOSTTY_FORMATTER_FORMAT_HTML
            options.unwrap = false
            options.trim = true
            var ptr: UnsafeMutablePointer<UInt8>?
            var len = 0
            let ok = withUnsafePointer(to: &selection) { sel -> Bool in
                options.selection = sel
                return ghostty_terminal_selection_format_alloc(terminal, nil, options, &ptr, &len) == GHOSTTY_SUCCESS
            }
            guard ok, let ptr else { return nil }
            defer { ghostty_free(nil, ptr, len) }
            let html = String(decoding: UnsafeBufferPointer(start: ptr, count: len), as: UTF8.self)
            var visible = true
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_VISIBLE, &visible)
            var cx: UInt16 = 0, cy: UInt16 = 0
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cx)
            _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cy)
            return WebScreen(html: html, cols: cols, rows: rows, cursor: visible ? [Int(cy), Int(cx)] : nil)
        }
    }

    /// A key pressed in a browser (`KeyboardEvent.code`, `.key` and its
    /// modifiers), encoded for the program like a key typed here.
    func sendWebKey(code: String, key: String, ctrl: Bool, alt: Bool, shift: Bool, meta: Bool) {
        let printable = key.count == 1 ? key : nil
        guard let physical = WebKeys.codes[code] else {
            // A key without a code (some soft keyboards): its text, if any.
            if let printable { sendText(printable) }
            return
        }
        var mods: GhosttyMods = 0
        if shift { mods |= GhosttyMods(GHOSTTY_MODS_SHIFT) }
        if ctrl { mods |= GhosttyMods(GHOSTTY_MODS_CTRL) }
        if alt { mods |= GhosttyMods(GHOSTTY_MODS_ALT) }
        if meta { mods |= GhosttyMods(GHOSTTY_MODS_SUPER) }
        var unshifted: UInt32 = 0
        if code.hasPrefix("Key"), let c = code.dropFirst(3).lowercased().unicodeScalars.first { unshifted = c.value }
        else if code.hasPrefix("Digit"), let c = code.dropFirst(5).unicodeScalars.first { unshifted = c.value }
        else if let printable, let c = printable.lowercased().unicodeScalars.first { unshifted = c.value }
        // Ctrl and Alt combinations are the encoder's to spell; plain text is the text.
        let text = (ctrl || meta) ? nil : printable
        send(Key(action: GHOSTTY_KEY_ACTION_PRESS, key: physical, mods: mods,
                 consumedMods: text != nil && shift ? GhosttyMods(GHOSTTY_MODS_SHIFT) : 0,
                 text: text, unshiftedCodepoint: unshifted, composing: false))
    }
}
