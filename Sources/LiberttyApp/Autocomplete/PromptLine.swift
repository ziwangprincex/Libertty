import Foundation

/// The command line being edited at a shell's prompt, as the screen shows
/// it: what's typed before the cursor and how much room there is after it.
/// Read from the cells shell integration marks as input (after OSC 133 B),
/// so only a marked prompt has one — never a running program's screen, and
/// not fish's (it marks no input, and draws suggestions of its own).
struct PromptLine: Equatable {
    /// What's typed from the start of the input to the cursor.
    var typed: String
    /// Columns free on the cursor's row from the cursor on (to the row's end,
    /// or to just before a right prompt).
    var room: Int
    /// The cursor is at the end of what's typed (nothing typed after it).
    var atEnd: Bool

    /// One cell as the screen has it.
    struct Cell: Equatable {
        enum Kind: Equatable { case output, input, prompt }
        /// Its text ("" when blank); a wide character's second cell is `spacer`.
        var text: String
        var kind: Kind
        var spacer = false

        static func blank(_ kind: Kind = .output) -> Cell { Cell(text: "", kind: kind) }
    }

    struct Row: Equatable {
        var cells: [Cell]
        /// It goes on in the row below (a soft wrap).
        var wraps = false
        /// Where shell integration marked a prompt's first row (133 A) or
        /// one of its other rows (a multi-line prompt's, PS2).
        enum Mark: Equatable { case none, prompt, continuation }
        var mark = Mark.none
    }

    /// The line at `cursor` (row, column) in `rows`, or nil when the cursor
    /// isn't in a prompt's input: right after a prompt or what's typed after
    /// one. A command of several lines (rows above holding input since the
    /// prompt) has none either: a suggestion of one line would only confuse it.
    static func read(_ rows: [Row], cursor: (row: Int, col: Int)) -> PromptLine? {
        let r = cursor.row, c = cursor.col
        guard r >= 0, r < rows.count, c >= 0, c <= rows[r].cells.count else { return nil }
        // The logical line: the rows above that wrap into this one.
        var start = r
        while start > 0, rows[start - 1].wraps { start -= 1 }

        // What's just before the cursor must be the prompt or input.
        func cell(_ row: Int, _ col: Int) -> Cell? {
            guard row >= 0, row < rows.count, col >= 0, col < rows[row].cells.count else { return nil }
            return rows[row].cells[col]
        }
        var x = c - 1, y = r
        if x < 0, y > start { y -= 1; x = rows[y].cells.count - 1 }
        while let found = cell(y, x), found.spacer { x -= 1 }
        if let before = cell(y, x) {
            guard before.kind == .input || before.kind == .prompt else { return nil }
        } else if rows[r].mark == .none {
            return nil
        }

        // A line that continues a prompt (a prompt's second row, or PS2): a
        // command of more than one line if rows above it, back to the
        // prompt's first, hold input.
        if rows[start].mark == .continuation {
            var above = start - 1
            while above >= 0 {
                if rows[above].cells.contains(where: { $0.kind == .input && !$0.text.isEmpty }) { return nil }
                if rows[above].mark != .continuation { break }
                above -= 1
            }
        }

        // Typed: the input cells, in order, up to the cursor.
        var typed = ""
        var sawInput = false
        for y in start...r {
            let end = y == r ? c : rows[y].cells.count
            for x in 0..<end {
                let cell = rows[y].cells[x]
                guard cell.kind == .input, !cell.spacer else { continue }
                sawInput = true
                typed += cell.text.isEmpty ? " " : cell.text
            }
        }
        if !sawInput { typed = "" }

        // After the cursor: blank to the end of the line, or only a right
        // prompt there (zsh's RPROMPT, after a gap at the row's end). Spaces
        // are blank: a line editor erases what was there with them.
        func blank(_ cell: Cell) -> Bool { cell.text.isEmpty || cell.text == " " }
        let row = rows[r].cells
        var lastWrapped = r
        while lastWrapped < rows.count - 1, rows[lastWrapped].wraps { lastWrapped += 1 }
        let laterRows = lastWrapped > r ? Array(rows[(r + 1)...lastWrapped]) : []
        let laterBlank = laterRows.allSatisfy { $0.cells.allSatisfy(blank) }
        let firstAfter = row.indices.dropFirst(c).first { !blank(row[$0]) }
        guard let firstAfter else {
            return PromptLine(typed: typed, room: laterBlank ? row.count - c : 0, atEnd: laterBlank)
        }
        let lastAfter = row.indices.last { !blank(row[$0]) } ?? firstAfter
        let gap = firstAfter - c
        if laterBlank, gap >= 2, lastAfter >= row.count - 3 {
            // A right prompt: room up to a space before it.
            return PromptLine(typed: typed, room: gap - 1, atEnd: true)
        }
        return PromptLine(typed: typed, room: 0, atEnd: false)
    }
}
