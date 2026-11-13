import Foundation
import CGhosttyVt
import CPty
import LiberttyCore

/// A pane's surfaces (SurfaceProtocol): what its programs asked to show,
/// where, and whose they are. Commands arrive while output is parsed (the
/// io queue, the session's lock held) and are applied on the main thread,
/// where the pane draws them (TerminalView+Surfaces).
///
/// The rules that keep a program honest:
/// - A surface is live — its controls work and its events are told — from
///   when it's shown until the shell's next prompt, or another program
///   comes to the front (on this Mac, where that can be asked). Then an
///   inline one stays in the output, dimmed, its controls off; an overlay goes.
/// - One drawn on the alternate screen (vim, a TUI) shows only there, and
///   goes when the program leaves it; the main screen's hide meanwhile.
/// - An inline surface covers rows its program left blank: once anything
///   is written there (the screen cleared and a prompt drawn), it goes. So
///   does one whose rows fell out of the scrollback, and every one at a
///   reset (RIS) or when the terminal is replaced (a reattach).
final class SurfaceStore {
    struct Surface {
        var spec: SurfaceSpec
        /// The cursor's row when it was first shown (inline): its top is
        /// `rows` above it (`above`) or that row (`cursor`).
        var anchor: GhosttyTrackedGridRef?
        var alternate: Bool
        /// The process group in front when it was shown (this Mac's panes).
        var owner: pid_t?
        /// Who drew it, shown on it: "python3".
        var program: String
        var live = true
        /// Bumped with each change, so a view rebuilds only what changed.
        var revision = 0
    }

    /// A finished command's lens (CommandLenses): what it found, and the
    /// row of the command line it hangs on.
    struct Lens {
        var id: Int
        var result: CommandLenses.Result
        var anchor: GhosttyTrackedGridRef?
        var directory: String?
    }

    private(set) var surfaces: [Surface] = []
    private(set) var lenses: [Lens] = []
    /// Told on the main thread when surfaces or lenses change.
    var onChange: (() -> Void)?

    // MARK: From the io queue (the session's lock held)

    private struct Pending {
        var command: SurfaceProtocol.Command
        var anchor: GhosttyTrackedGridRef?
        var alternate: Bool
        var owner: pid_t?
    }

    /// What came, in the order it came: a program's command, or the shell's
    /// prompt (a surface sent just before it is a program's that ended)
    /// or a reset. Kept in one queue so neither overtakes the other.
    private enum Entry {
        case command(Pending)
        case prompt(row: Int)
        case reset
    }

    private let pendingLock = NSLock()
    private var pending: [Entry] = []
    private var flushScheduled = false
    private var windowStart: UInt64 = 0
    private var inWindow = 0
    /// The program asked (`q`): it reads errors too.
    private var spoke = false
    /// `surfaces` in the config, as the main thread last set it.
    private var enabledFlag = true
    var enabled: Bool {
        get { pendingLock.withLock { enabledFlag } }
        set { pendingLock.withLock { enabledFlag = newValue } }
    }
    /// Where the last command's output began and ended (OSC 133 C, D).
    private var outputStart: GhosttyTrackedGridRef?
    private var outputEnd: GhosttyTrackedGridRef?

    /// The terminal reports sequences it doesn't know to us (only ours act).
    static func install(on terminal: GhosttyTerminal) {
        var max = SurfaceProtocol.maxSequenceBytes
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_UNKNOWN_SEQUENCE, unsafeBitCast(onUnknownSequence, to: UnsafeRawPointer.self))
        _ = ghostty_terminal_set(terminal, GHOSTTY_TERMINAL_OPT_UNKNOWN_MAX_BYTES, &max)
    }

    /// An OSC the terminal doesn't know: ours, or nothing.
    func received(_ content: String, truncated: Bool, terminal: GhosttyTerminal, session: TerminalSession) {
        guard content.hasPrefix("\(SurfaceProtocol.number);") || content == "\(SurfaceProtocol.number)" else { return }
        let (on, talks) = pendingLock.withLock { (enabledFlag, spoke) }
        guard on else { return }  // off: as if Libertty didn't know the sequence (no reply either)
        if truncated {
            if talks { session.surfaceReply(SurfaceProtocol.errorReply("over \(SurfaceProtocol.maxSequenceBytes) bytes", surface: nil)) }
            return
        }
        let command: SurfaceProtocol.Command
        do {
            guard let c = try SurfaceProtocol.command(content) else { return }
            command = c
        } catch {
            if talks { session.surfaceReply(SurfaceProtocol.errorReply("\(error)", surface: nil)) }
            return
        }
        if case .query = command {
            pendingLock.withLock { spoke = true }
            session.surfaceReply(SurfaceProtocol.queryReply)
            return
        }
        // A flood: past the rate, commands wait for the next second, a
        // surface's later sets replacing its earlier one still waiting (the
        // first's anchor stands): its latest is what shows.
        let now = DispatchTime.now().uptimeNanoseconds
        var item = Pending(command: command, anchor: nil, alternate: Self.isAlternate(terminal), owner: session.foregroundGroup)
        if case .set = command { item.anchor = Self.trackCursorRow(terminal) }
        pendingLock.lock()
        if now - windowStart > 1_000_000_000, deferred.isEmpty { windowStart = now; inWindow = 0 }
        inWindow += 1
        if inWindow > SurfaceProtocol.ratePerSecond || !deferred.isEmpty {
            func sameSurface(_ entry: Entry, _ id: String) -> Bool {
                guard case .command(let p) = entry, case .set(let j) = p.command else { return false }
                return Self.peekID(j) == id
            }
            if case .set(let json) = command, let id = Self.peekID(json),
               let i = deferred.lastIndex(where: { sameSurface($0, id) }), case .command(let earlier) = deferred[i] {
                if let new = item.anchor, earlier.anchor != nil { ghostty_tracked_grid_ref_free(new) }
                item.anchor = earlier.anchor ?? item.anchor
                deferred[i] = .command(item)
            } else if deferred.count < SurfaceProtocol.ratePerSecond {
                deferred.append(.command(item))
            } else {
                // More waiting than a second takes: this one goes.
                if let anchor = item.anchor { ghostty_tracked_grid_ref_free(anchor) }
            }
            let schedule = !deferredScheduled
            deferredScheduled = true
            let wait = Double(1_000_000_000 - min(1_000_000_000, now - windowStart)) / 1e9
            pendingLock.unlock()
            if schedule {
                DispatchQueue.main.asyncAfter(deadline: .now() + wait) { [weak self, weak session] in
                    guard let self, let session else { return }
                    self.pendingLock.withLock {
                        self.pending += self.deferred
                        self.deferred = []
                        self.deferredScheduled = false
                        self.windowStart = DispatchTime.now().uptimeNanoseconds
                        self.inWindow = 0
                    }
                    self.flush(session)
                }
            }
            return
        }
        pending.append(.command(item))
        let schedule = !flushScheduled
        flushScheduled = true
        pendingLock.unlock()
        if schedule { DispatchQueue.main.async { [weak self, weak session] in if let session { self?.flush(session) } } }
    }

    /// Commands held back by the rate, and whether their second's end is set to let them through.
    private var deferred: [Entry] = []
    private var deferredScheduled = false

    /// The shell's prompt, or the command's output beginning or ending (OSC 133).
    func semantic(_ kind: GhosttySemanticPromptKind, primary: Bool, terminal: GhosttyTerminal, session: TerminalSession) {
        switch kind {
        case GHOSTTY_SEMANTIC_PROMPT_PROMPT_START where primary:
            guard let row = Self.cursorScreenRow(terminal) else { return }
            // The next program hasn't asked: it hears no errors.
            pendingLock.withLock { spoke = false }
            enqueue(.prompt(row: row), session)
        case GHOSTTY_SEMANTIC_PROMPT_OUTPUT_START:
            if let old = outputStart { ghostty_tracked_grid_ref_free(old) }
            if let old = outputEnd { ghostty_tracked_grid_ref_free(old) }
            outputStart = Self.trackCursorRow(terminal)
            outputEnd = nil
        case GHOSTTY_SEMANTIC_PROMPT_COMMAND_END:
            if outputStart != nil, outputEnd == nil { outputEnd = Self.trackCursorRow(terminal) }
        default:
            break
        }
    }

    /// RIS: everything goes.
    func reset(_ session: TerminalSession) { enqueue(.reset, session) }

    private func enqueue(_ entry: Entry, _ session: TerminalSession) {
        pendingLock.lock()
        // What the rate held back came before this: it goes first (a prompt
        // after it ends what it showed).
        pending += deferred
        deferred = []
        pending.append(entry)
        let schedule = !flushScheduled
        flushScheduled = true
        pendingLock.unlock()
        if schedule { DispatchQueue.main.async { [weak self, weak session] in if let session { self?.flush(session) } } }
    }

    // MARK: On the main thread

    private func flush(_ session: TerminalSession) {
        pendingLock.lock()
        let entries = pending
        pending = []
        flushScheduled = false
        pendingLock.unlock()
        var changed = false
        for entry in entries {
            switch entry {
            case .reset: changed = removeAll(session) || changed
            case .prompt(let row): changed = promptStarted(at: row, session) || changed
            case .command(let item): changed = apply(item, session) || changed
            }
        }
        if changed { onChange?() }
    }

    private func apply(_ item: Pending, _ session: TerminalSession) -> Bool {
        switch item.command {
        case .query:
            return false
        case .clear:
            let before = surfaces.count
            let gone = surfaces.filter(\.live)
            surfaces.removeAll(where: \.live)
            free(gone.compactMap(\.anchor), session)
            return surfaces.count != before
        case .delete(let id):
            guard let i = surfaces.firstIndex(where: { $0.spec.id == id && $0.live }) else { return false }
            free([surfaces[i].anchor].compactMap { $0 }, session)
            surfaces.remove(at: i)
            return true
        case .set(let json):
            let spec: SurfaceSpec
            let program = session.surfaceProgramName(item.owner)
            // A program on another machine: a host pane's, or one through ssh
            // in a pane here. Its file paths are that machine's.
            let remote = session.host != nil || ["ssh", "mosh", "mosh-client", "autossh", "et"].contains(program.lowercased())
            do {
                spec = try SurfaceSpec.parse(json, remote: remote)
            } catch {
                free([item.anchor].compactMap { $0 }, session)
                tellError("\(error)", surface: Self.peekID(json), session)
                return false
            }
            // An update keeps where it was first shown, and its state.
            if let i = surfaces.firstIndex(where: { $0.spec.id == spec.id && $0.live }) {
                free([item.anchor].compactMap { $0 }, session)
                guard surfaces[i].spec.isInline == spec.isInline else {
                    tellError("a surface can't change from inline to overlay", surface: spec.id, session)
                    return false
                }
                guard surfaces[i].spec != spec else { return false }
                surfaces[i].spec = spec
                surfaces[i].revision += 1
                return true
            }
            if spec.isInline, item.anchor == nil {
                tellError("no row to show it on", surface: spec.id, session)
                return false
            }
            // Room: an old, dimmed one goes first; with only live ones, it's refused.
            if surfaces.count >= SurfaceProtocol.maxSurfaces {
                guard let i = surfaces.firstIndex(where: { !$0.live }) else {
                    free([item.anchor].compactMap { $0 }, session)
                    tellError("at most \(SurfaceProtocol.maxSurfaces) surfaces a pane", surface: spec.id, session)
                    return false
                }
                free([surfaces[i].anchor].compactMap { $0 }, session)
                surfaces.remove(at: i)
            }
            let anchor = spec.isInline ? item.anchor : nil
            if !spec.isInline, let unused = item.anchor { free([unused], session) }
            surfaces.append(Surface(spec: spec, anchor: anchor, alternate: item.alternate, owner: item.owner,
                                    program: program))
            return true
        }
    }

    private func tellError(_ message: String, surface: String?, _ session: TerminalSession) {
        guard pendingLock.withLock({ spoke }) else { return }
        session.surfaceReply(SurfaceProtocol.errorReply(message, surface: surface))
    }

    /// The shell's prompt: what was live ends (overlays go, inline ones dim),
    /// and inline ones at or below the prompt's row go — the screen was
    /// cleared under them.
    private func promptStarted(at row: Int, _ session: TerminalSession) -> Bool {
        guard !surfaces.isEmpty else { return false }
        let anchors = session.withTerminal { _ in surfaces.map { s in s.anchor.flatMap(Self.screenRow) } }
        var keep: [Surface] = [], gone: [GhosttyTrackedGridRef] = []
        for (s, anchor) in zip(surfaces, anchors) {
            guard case .inline(let rows, let fromCursor) = s.spec.placement else {
                continue  // an overlay ends with its program
            }
            // Its first row: below the prompt's start, the prompt is drawn over it.
            let top = anchor.map { fromCursor ? $0 : $0 - rows }
            if s.alternate || (top.map { $0 >= row } ?? false) {
                if let a = s.anchor { gone.append(a) }
                continue
            }
            var dimmed = s
            if dimmed.live {
                dimmed.live = false
                dimmed.revision += 1
            }
            keep.append(dimmed)
        }
        let changed = keep.count != surfaces.count || zip(keep, surfaces).contains { $0.revision != $1.revision }
        surfaces = keep
        free(gone, session)
        return changed
    }

    private func removeAll(_ session: TerminalSession) -> Bool {
        let had = !surfaces.isEmpty || !lenses.isEmpty
        free(surfaces.compactMap(\.anchor) + lenses.compactMap(\.anchor), session)
        surfaces = []
        lenses = []
        return had
    }

    /// The terminal was replaced (a reattach, a catch-up): its rows, and so
    /// every anchor, are gone. Called with the session's lock held.
    func terminalReplaced(_ session: TerminalSession) {
        // The output marks are this side's; the surfaces and lenses go on the
        // main thread, in order with what came before and comes after (a
        // reset). (Refs whose terminal is freed report nothing, and can still be freed.)
        [outputStart, outputEnd].compactMap { $0 }.forEach(ghostty_tracked_grid_ref_free)
        outputStart = nil
        outputEnd = nil
        enqueue(.reset, session)
    }

    /// Takes away the surface `id` (the user closed an overlay).
    func remove(_ id: String, _ session: TerminalSession) {
        guard let i = surfaces.firstIndex(where: { $0.spec.id == id }) else { return }
        free([surfaces[i].anchor].compactMap { $0 }, session)
        surfaces.remove(at: i)
        onChange?()
    }

    /// Whether `id`'s events may be told: it's live and its program still in
    /// front (where that can be asked).
    func mayTell(_ id: String, _ session: TerminalSession) -> Bool {
        guard let s = surfaces.first(where: { $0.spec.id == id }), s.live else { return false }
        if s.alternate != session.isAlternateScreen { return false }
        if let owner = s.owner, let now = session.foregroundGroup, owner != now {
            // Its program left: what it showed stops answering.
            if let i = surfaces.firstIndex(where: { $0.spec.id == id }) {
                surfaces[i].live = false
                surfaces[i].revision += 1
                if !surfaces[i].spec.isInline {
                    free([surfaces[i].anchor].compactMap { $0 }, session)
                    surfaces.remove(at: i)
                }
                onChange?()
            }
            return false
        }
        return true
    }

    /// What the pane shows now, and where (rows from the viewport's top),
    /// dropping what can't be shown any more: an anchor gone with the
    /// scrollback, rows written over, an alternate screen left.
    struct Placed {
        var surface: Surface
        /// Inline: its first row from the viewport's top (negative: above it).
        var row: Int?
    }

    /// `checkRows`: also look whether their rows were written over (costlier:
    /// every cell they cover), else only where they are.
    func placed(_ session: TerminalSession, checkRows: Bool = true) -> [Placed] {
        guard !surfaces.isEmpty else { return [] }
        let alternate = session.isAlternateScreen
        var gone: [Int] = []
        let result: [Placed] = session.withTerminal { t in
            let cells = ScreenCells(t)
            var out: [Placed] = []
            for (i, s) in surfaces.enumerated() {
                // Drawn on the alternate screen, and that's gone: so is it.
                if s.alternate, !alternate { gone.append(i); continue }
                if s.alternate != alternate { continue }
                guard case .inline(let rows, let fromCursor) = s.spec.placement else {
                    out.append(Placed(surface: s, row: nil))
                    continue
                }
                guard let anchorRow = s.anchor.flatMap(Self.screenRow) else { gone.append(i); continue }
                let top = fromCursor ? anchorRow : anchorRow - rows
                if top < 0 { gone.append(i); continue }
                // Its rows were written over: it's no longer what's there.
                if checkRows, (top..<min(cells.rows, top + rows)).contains(where: { Self.rowHasText(cells, $0) }) {
                    gone.append(i)
                    continue
                }
                out.append(Placed(surface: s, row: top - cells.top))
            }
            return out
        }
        if !gone.isEmpty {
            let refs = gone.compactMap { surfaces[$0].anchor }
            for i in gone.reversed() { surfaces.remove(at: i) }
            free(refs, session)
            DispatchQueue.main.async { [weak self] in self?.onChange?() }
        }
        return result
    }

    // MARK: Lenses

    /// The text of the last command's output (OSC 133 C to D), at most
    /// `maxBytes` of it, and the row of its command line; nil when the
    /// shell didn't mark it.
    func lastOutput(_ session: TerminalSession, maxBytes: Int = 2 << 20) -> (text: String, commandRow: GhosttyTrackedGridRef?)? {
        session.withTerminal { t -> (String, GhosttyTrackedGridRef?)? in
            guard let start = outputStart, let end = outputEnd,
                  let first = Self.screenRow(start), let last = Self.screenRow(end) else { return nil }
            let cells = ScreenCells(t)
            var point = GhosttyPoint()
            point.tag = GHOSTTY_POINT_TAG_SCREEN
            point.value.coordinate = GhosttyPointCoordinate(x: 0, y: UInt32(max(0, first - 1)))
            var commandRow: GhosttyTrackedGridRef?
            _ = ghostty_terminal_grid_ref_track(t, point, &commandRow)
            // Nothing printed: no text to read. (A long output's last rows:
            // the formatter reads them under the lock, which parsing waits on.)
            let from = max(first, last - 5000)
            guard last > first, let start = cells.ref(0, from), let to = cells.ref(cells.cols - 1, last - 1) else {
                return ("", commandRow)
            }
            var selection = GhosttySelection()
            selection.start = start
            selection.end = to
            let data = Snapshots.format(t, emit: GHOSTTY_FORMATTER_FORMAT_PLAIN, unwrap: true, trim: true, selection: selection) ?? Data()
            return (String(decoding: data.prefix(maxBytes), as: UTF8.self), commandRow)
        }
    }

    private var lensCount = 0

    func addLens(_ result: CommandLenses.Result, anchor: GhosttyTrackedGridRef?, directory: String?, _ session: TerminalSession) {
        lensCount += 1
        lenses.append(Lens(id: lensCount, result: result, anchor: anchor, directory: directory))
        // The latest few: older ones go with their rows' history.
        if lenses.count > 20 {
            free([lenses[0].anchor].compactMap { $0 }, session)
            lenses.removeFirst()
        }
        onChange?()
    }

    /// The lenses on rows in view: rows from the viewport's top.
    func placedLenses(_ session: TerminalSession) -> [(lens: Lens, row: Int)] {
        guard !lenses.isEmpty, !session.isAlternateScreen else { return [] }
        return session.withTerminal { t in
            let cells = ScreenCells(t)
            return lenses.compactMap { lens in
                guard let row = lens.anchor.flatMap(Self.screenRow) else { return nil }
                let r = row - cells.top
                return (0..<cells.height).contains(r) ? (lens, r) : nil
            }
        }
    }

    // MARK: Helpers (the session's lock held)

    private func free(_ refs: [GhosttyTrackedGridRef], _ session: TerminalSession) {
        guard !refs.isEmpty else { return }
        session.withTerminal { _ in refs.forEach(ghostty_tracked_grid_ref_free) }
    }

    static func isAlternate(_ t: GhosttyTerminal) -> Bool {
        var screen = GHOSTTY_TERMINAL_SCREEN_PRIMARY
        _ = ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_ACTIVE_SCREEN, &screen)
        return screen == GHOSTTY_TERMINAL_SCREEN_ALTERNATE
    }

    static func cursorScreenRow(_ t: GhosttyTerminal) -> Int? {
        var y: UInt16 = 0
        _ = ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
        return ScreenCells.screenRow(t, GHOSTTY_POINT_TAG_ACTIVE, y: Int(y))
    }

    static func trackCursorRow(_ t: GhosttyTerminal) -> GhosttyTrackedGridRef? {
        var y: UInt16 = 0
        _ = ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_ACTIVE
        point.value.coordinate = GhosttyPointCoordinate(x: 0, y: UInt32(y))
        var ref: GhosttyTrackedGridRef?
        return ghostty_terminal_grid_ref_track(t, point, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    static func screenRow(_ ref: GhosttyTrackedGridRef) -> Int? {
        var p = GhosttyPointCoordinate()
        guard ghostty_tracked_grid_ref_point(ref, GHOSTTY_POINT_TAG_SCREEN, &p) == GHOSTTY_SUCCESS else { return nil }
        return Int(p.y)
    }

    /// Anything but blanks on the row.
    static func rowHasText(_ cells: ScreenCells, _ y: Int) -> Bool {
        for x in 0..<cells.cols {
            guard var r = cells.ref(x, y) else { continue }
            var raw: GhosttyCell = 0
            guard ghostty_grid_ref_cell(&r, &raw) == GHOSTTY_SUCCESS else { continue }
            var cp: UInt32 = 0
            _ = ghostty_cell_get(raw, GHOSTTY_CELL_DATA_CODEPOINT, &cp)
            if cp != 0, cp != 0x20 { return true }
        }
        return false
    }

    /// A set's id without parsing the whole of it (for coalescing a flood).
    static func peekID(_ json: String) -> String? {
        guard let range = json.range(of: #""id"\s*:\s*"([A-Za-z0-9_.\-]{1,64})""#, options: .regularExpression) else { return nil }
        let match = json[range]
        guard let open = match.dropLast().lastIndex(of: "\"") else { return nil }
        return String(match[match.index(after: open)..<match.index(before: match.endIndex)])
    }
}

private let onUnknownSequence: GhosttyTerminalUnknownSequenceFn = { terminal, userdata, sequence in
    guard let terminal, let userdata, let sequence = sequence?.pointee, sequence.tag == GHOSTTY_TERMINAL_UNKNOWN_SEQUENCE_OSC else { return }
    let osc = sequence.value.osc
    // (Borrowed for this call only: copied.)
    let content = String(borrowed: osc.content)
    let session = Unmanaged<TerminalSession>.fromOpaque(userdata).takeUnretainedValue()
    session.surfaces.received(content, truncated: osc.truncated, terminal: terminal, session: session)
}
