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
}
