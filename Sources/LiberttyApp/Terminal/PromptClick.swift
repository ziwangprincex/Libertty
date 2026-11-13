import CGhosttyVt

extension TerminalSession {
    /// Something is selected.
    var hasSelection: Bool {
        withTerminal { t in
            var selection = GhosttySelection()
            return ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_SELECTION, &selection) == GHOSTTY_SUCCESS
        }
    }

    /// `cursor-click-to-move` (Ghostty's, the way it does it for `cl=line`
    /// prompts): how many presses of → (positive) or ← (negative) take the
    /// shell's cursor to the viewport cell clicked, along the command being
    /// typed — its input cells (OSC 133;B), one press a character, so a
    /// wide one is one press too. Over the rows a long command soft-wraps
    /// onto, not the lines of a multi-line one. Nil when the click isn't
    /// on that line, or the cursor isn't at a prompt.
    func promptClickMove(col: Int, row: Int) -> Int? {
        withTerminal { t -> Int? in
            var atPrompt = false
            _ = ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_AT_PROMPT, &atPrompt)
            guard atPrompt else { return nil }
            let cells = ScreenCells(t)
            var cx: UInt16 = 0, cy: UInt16 = 0
            _ = ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_X, &cx)
            _ = ghostty_terminal_get(t, GHOSTTY_TERMINAL_DATA_CURSOR_Y, &cy)
            guard let cursor = ScreenCells.screenPoint(t, GHOSTTY_POINT_TAG_ACTIVE, x: Int(cx), y: Int(cy)),
                  var click = ScreenCells.screenPoint(t, GHOSTTY_POINT_TAG_VIEWPORT, x: max(0, min(col, cells.cols - 1)),
                                                      y: max(0, row))
            else { return nil }
            if click.x > 0, cells.isSpacer(click.x, click.y) { click.x -= 1 }
            // The cursor's line: its rows, joined by soft wraps.
            var first = cursor.y, last = cursor.y
            while first > 0, cells.wraps(first - 1) { first -= 1 }
            while last < cells.rows - 1, cells.wraps(last) { last += 1 }
            guard (first...last).contains(click.y) else { return nil }
            if click == cursor { return 0 }
            func isInput(_ p: ScreenPoint) -> Bool {
                !cells.isSpacer(p.x, p.y) && cells.semantic(p.x, p.y) == GHOSTTY_CELL_SEMANTIC_INPUT
            }
            var count = 0
            if cursor < click {
                // Each input character after the cursor, up to the one clicked.
                var at = cursor
                while let next = cells.next(at), next.y <= last {
                    at = next
                    guard isInput(at) else { continue }
                    count += 1
                    if at == click { return count }
                }
                // Past the command's end: to its end, after its last character
                // (from on a character; already after it, no further).
                return isInput(cursor) ? count + 1 : count
            }
            // Each input character before the cursor, back to the one clicked
            // (before the command: to its start).
            var at = cursor
            while let previous = cells.previous(at), previous.y >= first {
                at = previous
                if isInput(at) { count += 1 }
                if at == click { break }
            }
            return -count
        }
    }
}
