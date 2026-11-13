import AppKit
import CGhosttyVt

/// A cell of the whole screen, scrollback included: row 0 is the oldest.
/// Ordered as text reads, row by row.
struct ScreenPoint: Equatable, Comparable {
    var x: Int
    var y: Int
    static func < (a: ScreenPoint, b: ScreenPoint) -> Bool { (a.y, a.x) < (b.y, b.x) }
}

/// The screen as copy mode and hints read it, through grid references,
/// with the session's lock held (`TerminalSession.withTerminal`).
struct ScreenCells {
    let terminal: GhosttyTerminal
    let cols: Int
    /// Rows in all, the scrollback's and the screen's.
    let rows: Int
    /// The viewport: its first row and how many it shows.
    let top: Int
    let height: Int

    init(_ terminal: GhosttyTerminal) {
        self.terminal = terminal
        var cols: UInt16 = 0, active: UInt16 = 0
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_COLS, &cols)
        _ = ghostty_terminal_get(terminal, GHOSTTY_TERMINAL_DATA_ROWS, &active)
        self.cols = max(1, Int(cols))
        // The active area's last row and the viewport's first, in screen rows.
        let bottom = Self.screenRow(terminal, GHOSTTY_POINT_TAG_ACTIVE, y: Int(max(1, active)) - 1)
        rows = max(1, (bottom ?? 0) + 1)
        top = Self.screenRow(terminal, GHOSTTY_POINT_TAG_VIEWPORT, y: 0) ?? 0
        height = max(1, min(Int(active), rows - top))
    }

    /// A row of another coordinate space (the active area, the viewport) as a screen row.
    static func screenRow(_ terminal: GhosttyTerminal, _ tag: GhosttyPointTag, y: Int) -> Int? {
        screenPoint(terminal, tag, x: 0, y: y)?.y
    }

    static func screenPoint(_ terminal: GhosttyTerminal, _ tag: GhosttyPointTag, x: Int, y: Int) -> ScreenPoint? {
        var point = GhosttyPoint()
        point.tag = tag
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: max(0, x)), y: UInt32(clamping: max(0, y)))
        var ref = GhosttyGridRef()
        var p = GhosttyPointCoordinate()
        guard ghostty_terminal_grid_ref(terminal, point, &ref) == GHOSTTY_SUCCESS,
              ghostty_terminal_point_from_grid_ref(terminal, &ref, GHOSTTY_POINT_TAG_SCREEN, &p) == GHOSTTY_SUCCESS
        else { return nil }
        return ScreenPoint(x: Int(p.x), y: Int(p.y))
    }

    func ref(_ x: Int, _ y: Int) -> GhosttyGridRef? {
        guard x >= 0, x < cols, y >= 0, y < rows else { return nil }
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_SCREEN
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(x), y: UInt32(y))
        var r = GhosttyGridRef()
        return ghostty_terminal_grid_ref(terminal, point, &r) == GHOSTTY_SUCCESS ? r : nil
    }

    private func cell(_ x: Int, _ y: Int) -> GhosttyCell? {
        guard var r = ref(x, y) else { return nil }
        var raw: GhosttyCell = 0
        return ghostty_grid_ref_cell(&r, &raw) == GHOSTTY_SUCCESS ? raw : nil
    }

    func wide(_ x: Int, _ y: Int) -> GhosttyCellWide {
        var wide = GHOSTTY_CELL_WIDE_NARROW
        if let c = cell(x, y) { _ = ghostty_cell_get(c, GHOSTTY_CELL_DATA_WIDE, &wide) }
        return wide
    }

    /// The second half of a wide character, or the gap a wide character
    /// left at a row's end when it went on to the next: no character of its own.
    func isSpacer(_ x: Int, _ y: Int) -> Bool {
        let w = wide(x, y)
        return w == GHOSTTY_CELL_WIDE_SPACER_TAIL || w == GHOSTTY_CELL_WIDE_SPACER_HEAD
    }

    /// What the cell shows: its character (a grapheme), "" when empty.
    func character(_ x: Int, _ y: Int) -> String {
        guard var r = ref(x, y) else { return "" }
        var scalars = [UInt32](repeating: 0, count: 16)
        var n = 0
        guard ghostty_grid_ref_graphemes(&r, &scalars, scalars.count, &n) == GHOSTTY_SUCCESS, n > 0 else { return "" }
        return String(String.UnicodeScalarView(scalars.prefix(n).compactMap(Unicode.Scalar.init)))
    }

    func semantic(_ x: Int, _ y: Int) -> GhosttyCellSemanticContent {
        var content = GHOSTTY_CELL_SEMANTIC_OUTPUT
        if let c = cell(x, y) { _ = ghostty_cell_get(c, GHOSTTY_CELL_DATA_SEMANTIC_CONTENT, &content) }
        return content
    }

    private func row(_ y: Int) -> GhosttyRow? {
        guard var r = ref(0, y) else { return nil }
        var raw: GhosttyRow = 0
        return ghostty_grid_ref_row(&r, &raw) == GHOSTTY_SUCCESS ? raw : nil
    }

    /// The row goes on in the next (soft-wrapped): one line of text.
    func wraps(_ y: Int) -> Bool {
        var wrap = false
        if let r = row(y) { _ = ghostty_row_get(r, GHOSTTY_ROW_DATA_WRAP, &wrap) }
        return wrap
    }

    /// A shell prompt starts on the row (OSC 133;A).
    func startsPrompt(_ y: Int) -> Bool {
        var state = GHOSTTY_ROW_SEMANTIC_NONE
        if let r = row(y) { _ = ghostty_row_get(r, GHOSTTY_ROW_DATA_SEMANTIC_PROMPT, &state) }
        return state == GHOSTTY_ROW_SEMANTIC_PROMPT
    }

    func isBlank(_ x: Int, _ y: Int) -> Bool { character(x, y).allSatisfy(\.isWhitespace) }

    func firstNonBlank(_ y: Int) -> Int { (0..<cols).first { !isSpacer($0, y) && !isBlank($0, y) } ?? 0 }

    func lastNonBlank(_ y: Int) -> Int { (0..<cols).reversed().first { !isSpacer($0, y) && !isBlank($0, y) } ?? 0 }

    /// The row's text, trailing blanks left out.
    func text(_ y: Int) -> String {
        var line = ""
        for x in 0..<cols where !isSpacer(x, y) {
            let c = character(x, y)
            line += c.isEmpty ? " " : c
        }
        while line.hasSuffix(" ") { line.removeLast() }
        return line
    }

    /// The cell after `p` (its character's, a wide one's spacer skipped),
    /// on into the next row; nil after the last.
    func next(_ p: ScreenPoint) -> ScreenPoint? {
        var q = p
        repeat {
            q.x += 1
            if q.x >= cols { q.x = 0; q.y += 1 }
            if q.y >= rows { return nil }
        } while isSpacer(q.x, q.y)
        return q
    }

    func previous(_ p: ScreenPoint) -> ScreenPoint? {
        var q = p
        repeat {
            q.x -= 1
            if q.x < 0 { q.x = cols - 1; q.y -= 1 }
            if q.y < 0 { return nil }
        } while isSpacer(q.x, q.y)
        return q
    }

    /// From `a` to the next cell `b` the text goes straight on: the same
    /// row, or a row soft-wrapped into the next. (A row's end that isn't
    /// is a line break: a word stops there.)
    func continues(_ a: ScreenPoint, _ b: ScreenPoint) -> Bool { a.y == b.y || wraps(min(a.y, b.y)) }

    /// A character's kind, for words: 0 blank, 1 a word's (letters, digits,
    /// _), 2 punctuation and the like. A WORD (`big`) is anything not blank.
    func kind(_ p: ScreenPoint, big: Bool) -> Int {
        let c = character(p.x, p.y)
        guard let s = c.unicodeScalars.first, !c.allSatisfy(\.isWhitespace) else { return 0 }
        if big { return 1 }
        return s.properties.isAlphabetic || s.properties.numericType != nil || s == "_" ? 1 : 2
    }
}

/// Copy mode (iTerm2's Copy Mode, the vi mode of kitty and Alacritty,
/// Otty's Vi Mode): a cursor of its own goes through the screen and the
/// scrollback by key — h j k l, words, lines, pages, prompts, matches — then
/// selects (v, V, ⌃V) and copies (y), while the program runs on: its
/// output still arrives, and nothing typed reaches it.
///
/// The cursor and the selection's other end are tracked references: new
/// output, the oldest scrollback lines going, a resize's reflow leave them
/// on the text they were on.
final class CopyMode {
    enum Selecting: Equatable { case none, characters, lines, block }

    /// What a key did.
    enum Outcome: Equatable {
        case moved, unchanged, unknown
        /// Leave copy mode; with text, that was copied.
        case leave(copied: String?)
        /// Open the find bar: `/` (down the page) or `?` (up it).
        case search(older: Bool)
        /// Go to the next match the last search's way (n), or the other (N).
        case nextMatch(sameWay: Bool)
    }

    private(set) var selecting = Selecting.none
    /// The screen it began on: a program switching screens ends it.
    let alternate: Bool
    /// The last search went up the page (`?`), or down (`/`).
    private(set) var searchesOlder = true

    private let session: TerminalSession
    private var cursor: GhosttyTrackedGridRef?
    private var anchor: GhosttyTrackedGridRef?
    /// The column up and down aim for (vim's curswant); nil: a line's end ($).
    private var wantColumn: Int? = 0
    /// Digits typed before a motion (5j).
    private var count = ""
    /// The first g of gg.
    private var pendingG = false

    /// Starts on the terminal's cursor, or, scrolled back past it, on the
    /// viewport's last line.
    init(session: TerminalSession) {
        self.session = session
        alternate = session.isAlternateScreen
        cursor = session.withTerminal { t -> GhosttyTrackedGridRef? in
            let cells = ScreenCells(t)
            var x: UInt16 = 0, y: UInt16 = 0
            _ = ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_X, &x)
            _ = ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &y)
            var at = ScreenCells.screenPoint(t, GHOSTTY_POINT_TAG_ACTIVE, x: Int(x), y: Int(y)) ?? ScreenPoint(x: 0, y: cells.top)
            if at.y < cells.top || at.y >= cells.top + cells.height {
                at.y = min(cells.rows - 1, cells.top + cells.height - 1)
                at.x = cells.firstNonBlank(at.y)
            }
            if at.x > 0, cells.isSpacer(at.x, at.y) { at.x -= 1 }
            return Self.track(t, at)
        }
        wantColumn = point?.x ?? 0
    }

    deinit {
        let refs = [cursor, anchor].compactMap { $0 }
        guard !refs.isEmpty else { return }
        session.withTerminal { _ in refs.forEach(ghostty_tracked_grid_ref_free) }
    }

    private static func track(_ t: GhosttyTerminal, _ p: ScreenPoint) -> GhosttyTrackedGridRef? {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_SCREEN
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: p.x), y: UInt32(clamping: p.y))
        var ref: GhosttyTrackedGridRef?
        return ghostty_terminal_grid_ref_track(t, point, &ref) == GHOSTTY_SUCCESS ? ref : nil
    }

    private static func point(of ref: GhosttyTrackedGridRef?, _ tag: GhosttyPointTag = GHOSTTY_POINT_TAG_SCREEN) -> ScreenPoint? {
        guard let ref else { return nil }
        var p = GhosttyPointCoordinate()
        guard ghostty_tracked_grid_ref_point(ref, tag, &p) == GHOSTTY_SUCCESS else { return nil }
        return ScreenPoint(x: Int(p.x), y: Int(p.y))
    }

    /// Where the cursor is on the screen (the UI probe, VoiceOver).
    var point: ScreenPoint? { session.withTerminal { _ in Self.point(of: cursor) } }

    /// The cursor's cell in the viewport, and whether it's a wide
    /// character's (two cells): nil when it's scrolled out of view.
    func viewportCursor() -> (row: Int, col: Int, wide: Bool)? {
        session.withTerminal { t in
            guard let p = Self.point(of: cursor, GHOSTTY_POINT_TAG_VIEWPORT), let s = Self.point(of: cursor) else { return nil }
            return (p.y, p.x, ScreenCells(t).wide(s.x, s.y) == GHOSTTY_CELL_WIDE_WIDE)
        }
    }

    /// The line the cursor is on, as text (VoiceOver reads it as it moves).
    func currentLine() -> String {
        session.withTerminal { t in Self.point(of: cursor).map { ScreenCells(t).text($0.y) } ?? "" }
    }

    /// The character, or the word, under the cursor (VoiceOver).
    func underCursor(word: Bool) -> String {
        session.withTerminal { t in
            let cells = ScreenCells(t)
            guard let p = Self.point(of: cursor) else { return "" }
            guard word, cells.kind(p, big: true) != 0 else { return cells.character(p.x, p.y) }
            var a = p, b = p
            while let q = cells.previous(a), cells.continues(q, a), cells.kind(q, big: true) != 0 { a = q }
            while let q = cells.next(b), cells.continues(b, q), cells.kind(q, big: true) != 0 { b = q }
            var out = "", at = a
            while true {
                out += cells.character(at.x, at.y)
                guard at != b, let q = cells.next(at) else { break }
                at = q
            }
            return out
        }
    }

    // MARK: Keys

    /// A key pressed in copy mode: `key` is what it types on a US layout
    /// (so h j k l are the same keys on any layout), `control` whether ⌃ is held.
    func press(_ key: String, control: Bool) -> Outcome {
        if control {
            count = ""
            pendingG = false
            switch key {
            case "u": return scrollAndMove(halfPages: -1)
            case "d": return scrollAndMove(halfPages: 1)
            case "b": return scrollAndMove(halfPages: -2)
            case "f": return scrollAndMove(halfPages: 2)
            case "y": return scrollKeepingCursor(-1)
            case "e": return scrollKeepingCursor(1)
            case "v": return toggle(.block)
            case "c", "[": return .leave(copied: nil)
            default: return .unknown
            }
        }
        if pendingG {
            pendingG = false
            let n = takeCount()
            guard key == "g" else { return .unknown }
            return move { cells, _ in
                let y = min(cells.rows - 1, (n ?? 1) - 1)
                return ScreenPoint(x: cells.firstNonBlank(y), y: y)
            }
        }
        if let digit = key.first, key.count == 1, digit.isNumber, digit != "0" || !count.isEmpty {
            count.append(digit)
            return .unchanged
        }
        let times = max(1, takeCount() ?? 1)
        switch key {
        case "h", "left": return step(times) { cells, p in
            p.x > 0 ? ScreenPoint(x: p.x - (cells.isSpacer(p.x - 1, p.y) && p.x > 1 ? 2 : 1), y: p.y) : p
        }
        case "l", "right": return step(times) { cells, p in
            guard let q = cells.next(p), q.y == p.y else { return p }
            return q
        }
        case "j", "down": return vertical(times)
        case "k", "up": return vertical(-times)
        case "pageup": return scrollAndMove(halfPages: -2)
        case "pagedown": return scrollAndMove(halfPages: 2)
        case "space": return step(times) { cells, p in cells.next(p) ?? p }
        case "backspace": return step(times) { cells, p in cells.previous(p) ?? p }
        case "0", "home": return move { _, p in ScreenPoint(x: 0, y: p.y) }
        case "^": return move { cells, p in ScreenPoint(x: cells.firstNonBlank(p.y), y: p.y) }
        case "$", "end":
            let outcome = move { cells, p in ScreenPoint(x: cells.lastNonBlank(p.y), y: p.y) }
            wantColumn = nil  // up and down: to each line's end
            return outcome
        case "w": return step(times) { cells, p in Self.wordForward(cells, p, big: false) }
        case "W": return step(times) { cells, p in Self.wordForward(cells, p, big: true) }
        case "b": return step(times) { cells, p in Self.wordBackward(cells, p, big: false) }
        case "B": return step(times) { cells, p in Self.wordBackward(cells, p, big: true) }
        case "e": return step(times) { cells, p in Self.wordEnd(cells, p, big: false) }
        case "E": return step(times) { cells, p in Self.wordEnd(cells, p, big: true) }
        case "g":
            pendingG = true
            if times > 1 { count = String(times) }
            return .unchanged
        case "G": return move { cells, _ in
            // The last line with anything on it (under the prompt, rows are blank).
            let last = (0..<cells.rows).reversed().first { !cells.text($0).isEmpty } ?? cells.rows - 1
            let y = times > 1 ? min(cells.rows - 1, times - 1) : last
            return ScreenPoint(x: cells.firstNonBlank(y), y: y)
        }
        case "H": return move { cells, _ in
            let y = min(cells.rows - 1, cells.top + times - 1)
            return ScreenPoint(x: cells.firstNonBlank(y), y: y)
        }
        case "M": return move { cells, _ in
            let y = min(cells.rows - 1, cells.top + (cells.height - 1) / 2)
            return ScreenPoint(x: cells.firstNonBlank(y), y: y)
        }
        case "L": return move { cells, _ in
            let y = max(cells.top, min(cells.rows, cells.top + cells.height) - times)
            return ScreenPoint(x: cells.firstNonBlank(y), y: y)
        }
        case "{": return step(times) { cells, p in Self.prompt(cells, from: p, older: true) ?? p }
        case "}": return step(times) { cells, p in Self.prompt(cells, from: p, older: false) ?? p }
        case "v": return toggle(.characters)
        case "V": return toggle(.lines)
        case "o": return swapEnds()
        case "y", "return":
            let text = copy()
            return .leave(copied: text)
        case "Y":
            let text = currentLine()
            return .leave(copied: text.isEmpty ? nil : text)
        case "/": searchesOlder = false; return .search(older: false)
        case "?": searchesOlder = true; return .search(older: true)
        case "n": return .nextMatch(sameWay: true)
        case "N": return .nextMatch(sameWay: false)
        case "q", "escape": return .leave(copied: nil)
        default: return .unknown
        }
    }

    /// The count typed, at most so much: a key held on 9 can't make one
    /// motion take minutes.
    private func takeCount() -> Int? {
        defer { count = "" }
        return Int(count.prefix(6))
    }

    // MARK: Moving

    /// Move the cursor where `target` says, from where it is, and show it:
    /// the viewport scrolls to it if it went out of view. The selection
    /// follows, and up and down aim for its column from now (moves up and
    /// down keep theirs themselves).
    @discardableResult
    private func move(_ target: (ScreenCells, ScreenPoint) -> ScreenPoint) -> Outcome {
        let moved: Bool = session.withTerminal(redraw: true) { t in
            let cells = ScreenCells(t)
            let from = Self.point(of: cursor) ?? ScreenPoint(x: 0, y: cells.top)
            var to = target(cells, from)
            to.y = max(0, min(cells.rows - 1, to.y))
            to.x = max(0, min(cells.cols - 1, to.x))
            if to.x > 0, cells.isSpacer(to.x, to.y) { to.x -= 1 }
            set(t, &cursor, to)
            reveal(t, cells, to.y)
            applySelection(t)
            return to != from
        }
        wantColumn = point?.x ?? 0
        return moved ? .moved : .unchanged
    }

    /// `times` steps of `motion` (a thousand at most), stopping where one goes nowhere.
    private func step(_ times: Int, _ motion: (ScreenCells, ScreenPoint) -> ScreenPoint) -> Outcome {
        move { cells, p in
            var at = p
            for _ in 0..<min(times, 1000) {
                let next = motion(cells, at)
                if next == at { break }
                at = next
            }
            return at
        }
    }

    private func vertical(_ rows: Int) -> Outcome {
        let want = wantColumn
        let outcome = move { cells, p in
            let y = max(0, min(cells.rows - 1, p.y + rows))
            return ScreenPoint(x: want.map { min($0, cells.cols - 1) } ?? cells.lastNonBlank(y), y: y)
        }
        wantColumn = want
        return outcome
    }

    /// ⌃U ⌃D ⌃B ⌃F: the view and the cursor go half a page (or a page) together.
    private func scrollAndMove(halfPages: Int) -> Outcome {
        let rows = session.withTerminal { t in ScreenCells(t).height } / 2 * halfPages
        session.scroll(rows: rows)
        return vertical(rows)
    }

    /// ⌃E ⌃Y: the view goes a line, the cursor stays (in view).
    private func scrollKeepingCursor(_ rows: Int) -> Outcome {
        session.scroll(rows: rows)
        let want = wantColumn
        let outcome = move { cells, p in
            ScreenPoint(x: p.x, y: max(cells.top, min(cells.top + cells.height - 1, p.y)))
        }
        wantColumn = want
        return outcome
    }

    /// Put the cursor on `point` (a search's match, a click).
    func moveTo(_ point: ScreenPoint) { move { _, _ in point } }

    /// The cursor's row in view: scrolled to, if it isn't.
    private func reveal(_ t: GhosttyTerminal, _ cells: ScreenCells, _ y: Int) {
        let row: Int
        if y < cells.top { row = y } else if y >= cells.top + cells.height { row = y - cells.height + 1 } else { return }
        var behavior = GhosttyTerminalScrollViewport()
        behavior.tag = GHOSTTY_TERMINAL_SCROLL_VIEWPORT_ROW
        behavior.value.row = max(0, row)
        ghostty_terminal_scroll_viewport(t, behavior)
    }

    private func set(_ t: GhosttyTerminal, _ ref: inout GhosttyTrackedGridRef?, _ p: ScreenPoint) {
        var point = GhosttyPoint()
        point.tag = GHOSTTY_POINT_TAG_SCREEN
        point.value.coordinate = GhosttyPointCoordinate(x: UInt16(clamping: p.x), y: UInt32(clamping: p.y))
        if let existing = ref, ghostty_tracked_grid_ref_set(existing, t, point) == GHOSTTY_SUCCESS { return }
        if let existing = ref { ghostty_tracked_grid_ref_free(existing) }
        ref = Self.track(t, p)
    }

    static func wordForward(_ cells: ScreenCells, _ p: ScreenPoint, big: Bool) -> ScreenPoint {
        var at = p
        let start = cells.kind(at, big: big)
        // The rest of this word, then the blanks (and line breaks) after it.
        if start != 0 {
            while let q = cells.next(at), cells.continues(at, q), cells.kind(q, big: big) == start { at = q }
        }
        guard var q = cells.next(at) else { return p }
        while cells.kind(q, big: big) == 0 {
            guard let r = cells.next(q) else { return p }
            q = r
        }
        return q
    }

    static func wordEnd(_ cells: ScreenCells, _ p: ScreenPoint, big: Bool) -> ScreenPoint {
        guard var at = cells.next(p) else { return p }
        while cells.kind(at, big: big) == 0 {
            guard let q = cells.next(at) else { return p }
            at = q
        }
        let kind = cells.kind(at, big: big)
        while let q = cells.next(at), cells.continues(at, q), cells.kind(q, big: big) == kind { at = q }
        return at
    }

    static func wordBackward(_ cells: ScreenCells, _ p: ScreenPoint, big: Bool) -> ScreenPoint {
        guard var at = cells.previous(p) else { return p }
        while cells.kind(at, big: big) == 0 {
            guard let q = cells.previous(at) else { return p }
            at = q
        }
        let kind = cells.kind(at, big: big)
        while let q = cells.previous(at), cells.continues(q, at), cells.kind(q, big: big) == kind { at = q }
        return at
    }

    /// The prompt before (`older`) or after the cursor's row (OSC 133
    /// marks): its input's first cell, or the row's start.
    static func prompt(_ cells: ScreenCells, from p: ScreenPoint, older: Bool) -> ScreenPoint? {
        let rows = older ? Array((0..<p.y).reversed()) : Array((p.y + 1)..<cells.rows)
        guard let y = rows.first(where: cells.startsPrompt) else { return nil }
        // Where input begins (OSC 133;B), on its row or a wrapped one after it.
        var at = ScreenPoint(x: 0, y: y)
        while true {
            if cells.semantic(at.x, at.y) == GHOSTTY_CELL_SEMANTIC_INPUT { return at }
            guard let q = cells.next(at), cells.continues(at, q), q.y - y < 4 else { break }
            at = q
        }
        return ScreenPoint(x: 0, y: y)
    }

    // MARK: Selecting

    /// v, V, ⌃V: start selecting that way from here; the same key again stops.
    private func toggle(_ kind: Selecting) -> Outcome {
        count = ""
        session.withTerminal(redraw: true) { t in
            if selecting == kind {
                selecting = .none
                if let anchor { ghostty_tracked_grid_ref_free(anchor) }
                anchor = nil
                _ = ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SELECTION, nil)
                return
            }
            if selecting == .none, let p = Self.point(of: cursor) { set(t, &anchor, p) }
            selecting = kind
            applySelection(t)
        }
        return .moved
    }

    /// o: go to the selection's other end.
    private func swapEnds() -> Outcome {
        guard selecting != .none else { return .unknown }
        let other: ScreenPoint? = session.withTerminal { _ in Self.point(of: anchor) }
        guard let other, let here = point else { return .unchanged }
        session.withTerminal { t in set(t, &anchor, here) }
        moveTo(other)
        return .moved
    }

    /// The terminal's selection from the anchor to the cursor, as it selects.
    private func applySelection(_ t: GhosttyTerminal) {
        guard selecting != .none, let a = Self.point(of: anchor), let c = Self.point(of: cursor) else { return }
        let cells = ScreenCells(t)
        var start = a, end = c
        switch selecting {
        case .lines:
            start = ScreenPoint(x: 0, y: min(a.y, c.y))
            end = ScreenPoint(x: cells.cols - 1, y: max(a.y, c.y))
        case .characters, .block:
            // A wide character at the far end: both its cells.
            if start > end { swap(&start, &end) }
            if selecting == .block {
                (start.x, end.x) = (min(a.x, c.x), max(a.x, c.x))
            }
            if end.x + 1 < cells.cols, cells.wide(end.x, end.y) == GHOSTTY_CELL_WIDE_WIDE { end.x += 1 }
        case .none: return
        }
        guard let s = cells.ref(start.x, start.y), let e = cells.ref(end.x, end.y) else { return }
        var selection = GhosttySelection()
        selection.start = s
        selection.end = e
        selection.rectangle = selecting == .block
        _ = ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SELECTION, &selection)
    }

    /// y: what's selected; nothing selected, the cursor's line.
    private func copy() -> String? {
        if selecting != .none, let text = session.selectedText(), !text.isEmpty { return text }
        let line = currentLine()
        return line.isEmpty ? nil : line
    }

    /// Leaving: the selection goes too.
    func end() {
        session.withTerminal(redraw: true) { t in
            if selecting != .none { _ = ghostty_terminal_set(t, GHOSTTY_TERMINAL_OPT_SELECTION, nil) }
        }
        selecting = .none
    }
}
