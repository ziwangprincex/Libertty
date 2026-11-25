import Foundation
import LiberttyCore
import Metal
import Testing
@testable import LiberttyApp

/// A cursor that only moves is something to draw. libghostty's dirty state
/// is about rows, and ← or → at a prompt changes none of them: 0.6.1–0.6.4
/// drew no frame for it, so the cursor showed where it had been until the
/// blink drew one, half a second on (and you deleted in the wrong place).
@Suite @MainActor struct CursorRedrawTests {
    @Test func aCursorThatOnlyMovesIsDrawn() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fonts = FontSet(pointSize: 13, scale: 2)
        let renderer = try TerminalRenderer(device: device, fonts: fonts)
        let session = try TerminalSession(size: GridSize(cols: 40, rows: 4, widthPx: UInt16(40 * fonts.cellWidth),
                                                         heightPx: UInt16(4 * fonts.cellHeight)), config: Config())
        session.show("$ echo hello")
        #expect(renderer.refresh(session))
        // Nothing new: nothing to draw.
        #expect(!renderer.refresh(session))
        // ← (the shell moves the cursor back): no row changes, the cursor does.
        session.show("\u{1b}[D")
        #expect(renderer.refresh(session))
        #expect(!renderer.refresh(session))
        // Shown or hidden (DECTCEM) is drawn too.
        session.show("\u{1b}[?25l")
        #expect(renderer.refresh(session))
        // A shape change (DECSCUSR: a bar).
        session.show("\u{1b}[?25h\u{1b}[5 q")
        #expect(renderer.refresh(session))
        #expect(!renderer.refresh(session))
    }

    /// Counts the session's asks for a frame (each wakes its pane's display link).
    private final class Wakes: TerminalSessionDelegate {
        var count = 0
        func sessionNeedsRender(_ session: TerminalSession) { count += 1 }
        func sessionNeedsFrame(_ session: TerminalSession) { count += 1 }
        func sessionTitleChanged(_ session: TerminalSession, title: String) {}
        func sessionBell(_ session: TerminalSession) {}
        func sessionProgramStatusChanged(_ session: TerminalSession) {}
        func sessionExited(_ session: TerminalSession, status: Int32) {}
    }

    /// What the session sent the main thread meanwhile arrives.
    private func settle() async throws { try await Task.sleep(for: .milliseconds(50)) }

    /// A change made on the main thread (a key scrolling to the bottom, a
    /// selection) asks for a frame as output does. It used to only mark one
    /// due: with the pane's display link paused (idle) and nothing else
    /// drawing, the mark stayed, every later output found it there and asked
    /// for nothing, and the pane stopped updating.
    @Test func aChangeOnTheMainThreadAsksForAFrame() async throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fonts = FontSet(pointSize: 13, scale: 2)
        let renderer = try TerminalRenderer(device: device, fonts: fonts)
        let session = try TerminalSession(size: GridSize(cols: 40, rows: 4, widthPx: UInt16(40 * fonts.cellWidth),
                                                         heightPx: UInt16(4 * fonts.cellHeight)), config: Config())
        let wakes = Wakes()
        session.delegate = wakes
        // Its first frame; then output asks for the next.
        _ = renderer.refresh(session)
        try await settle()
        let before = wakes.count
        session.show("$ less file")
        try await settle()
        #expect(wakes.count == before + 1)
        // Drawn; the display link pauses.
        _ = renderer.refresh(session)
        // The wheel over the pane sends ↑ (session.send scrolls to the
        // bottom), and the program redraws: the pane is asked to draw it.
        session.scrollToBottom()
        session.show("\u{1b}[Hline")
        try await settle()
        #expect(wakes.count > before + 1)
        // Drawn, and on as before.
        _ = renderer.refresh(session)
        let drawn = wakes.count
        session.show("more")
        try await settle()
        #expect(wakes.count == drawn + 1)
    }
}
