import AppKit

/// VoiceOver: the terminal is a read-only text area holding what's on
/// screen, with the cursor as its insertion point, so it can be read by
/// line, word or character and new output is announced.
extension TerminalView {
    /// The screen text as VoiceOver sees it, and where each row starts in it.
    private var accessibleText: (text: String, lineStarts: [Int], cursor: Int) {
        let (lines, cursor) = session.viewportText()
        var starts: [Int] = []
        var text = ""
        for line in lines {
            starts.append((text as NSString).length)
            text += line + "\n"
        }
        let row = min(max(0, cursor.row), max(0, lines.count - 1))
        let col = lines.isEmpty ? 0 : min(cursor.col, (lines[row] as NSString).length)
        return (text, starts, (starts.isEmpty ? 0 : starts[row]) + col)
    }

    override func isAccessibilityElement() -> Bool { true }
    override func accessibilityRole() -> NSAccessibility.Role? { .textArea }
    override func accessibilityRoleDescription() -> String? { "terminal" }
    override func accessibilityLabel() -> String? {
        let title = session.title.isEmpty ? (session.workingDirectory.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "") : session.title
        return title.isEmpty ? "Terminal" : "Terminal, \(title)"
    }
    override func isAccessibilityEnabled() -> Bool { true }
    override func accessibilityValue() -> Any? { accessibleText.text }
    override func accessibilityNumberOfCharacters() -> Int { (accessibleText.text as NSString).length }
    override func accessibilityVisibleCharacterRange() -> NSRange { NSRange(location: 0, length: accessibilityNumberOfCharacters()) }
    override func accessibilityInsertionPointLineNumber() -> Int { session.cursorPosition.y.toInt }

    override func accessibilitySelectedTextRange() -> NSRange {
        NSRange(location: accessibleText.cursor, length: 0)
    }

    override func accessibilitySelectedText() -> String? { session.selectedText() ?? "" }

    override func accessibilityLine(for index: Int) -> Int {
        let starts = accessibleText.lineStarts
        return max(0, (starts.lastIndex { $0 <= index } ?? 0))
    }

    override func accessibilityRange(forLine line: Int) -> NSRange {
        let (text, starts, _) = accessibleText
        guard starts.indices.contains(line) else { return NSRange(location: NSNotFound, length: 0) }
        let end = line + 1 < starts.count ? starts[line + 1] : (text as NSString).length
        return NSRange(location: starts[line], length: end - starts[line])
    }

    override func accessibilityString(for range: NSRange) -> String? {
        let text = accessibleText.text as NSString
        guard range.location >= 0, range.location + range.length <= text.length else { return nil }
        return text.substring(with: range)
    }

    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        accessibilityString(for: range).map { NSAttributedString(string: $0) }
    }

    /// Screen rectangle of a range (its first row), for VoiceOver's cursor.
    override func accessibilityFrame(for range: NSRange) -> NSRect {
        let starts = accessibleText.lineStarts
        let row = max(0, starts.lastIndex { $0 <= range.location } ?? 0)
        let col = range.location - (starts.isEmpty ? 0 : starts[row])
        let cell = cellSizePoints, pad = padding
        let width = max(1, min(range.length, Int((bounds.width - pad.left) / cell.width) - col))
        let local = NSRect(x: pad.left + CGFloat(col) * cell.width, y: pad.top + CGFloat(row) * cell.height,
                           width: CGFloat(width) * cell.width, height: cell.height)
        guard let window else { return .zero }
        return window.convertToScreen(convert(local, to: nil))
    }

    /// New output: let VoiceOver know (at most a few times a second).
    func announceOutputIfNeeded() {
        guard NSWorkspace.shared.isVoiceOverEnabled else { return }
        let now = CACurrentMediaTime()
        guard now - lastAccessibilityAnnouncement > 0.25 else { return }
        lastAccessibilityAnnouncement = now
        NSAccessibility.post(element: self, notification: .valueChanged)
    }
}

private extension UInt16 {
    var toInt: Int { Int(self) }
}
