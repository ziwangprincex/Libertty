import Foundation
import LiberttyCore
import Metal
import Testing
@testable import LiberttyApp

/// Autocomplete against a real terminal: the line read off libghostty-vt's
/// cells as shell integration marks them, and the ghost text drawn — a
/// frame when it changes, none when it doesn't.
@Suite @MainActor struct AutocompleteRenderTests {
    private func session(cols: UInt16 = 40, rows: UInt16 = 4, fonts: FontSet) throws -> TerminalSession {
        try TerminalSession(size: GridSize(cols: cols, rows: rows, widthPx: UInt16(Int(cols) * fonts.cellWidth),
                                           heightPx: UInt16(Int(rows) * fonts.cellHeight)), config: Config())
    }

    @Test func readsTheMarkedLine() throws {
        let fonts = FontSet(pointSize: 13, scale: 2)
        let s = try session(fonts: fonts)
        // A prompt, input marked after it, then what's typed (echoed).
        s.show("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}git st")
        let (line, cursor) = try #require(s.promptLine())
        #expect(line.typed == "git st" && line.atEnd && cursor.col == 8)
        // Back over a character: not at the end.
        s.show("\u{1b}[D")
        #expect(s.promptLine()?.line.atEnd == false)
        // A command running: no prompt.
        s.show("\u{1b}[C\r\n\u{1b}]133;C\u{07}output")
        #expect(s.promptLine() == nil)
    }

    /// No input mark (fish's way): what's typed can't be told from the prompt.
    @Test func noInputMarkNoLine() throws {
        let fonts = FontSet(pointSize: 13, scale: 2)
        let s = try session(fonts: fonts)
        s.show("\u{1b}]133;A\u{07}> git st")
        #expect(s.promptLine() == nil)
    }

    @Test func drawnWhenItChanges() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fonts = FontSet(pointSize: 13, scale: 2)
        let renderer = try TerminalRenderer(device: device, fonts: fonts)
        let s = try session(fonts: fonts)
        s.show("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}git st")
        #expect(renderer.refresh(s))
        #expect(!renderer.refresh(s))
        renderer.ghost = TerminalRenderer.Ghost(text: "atus --short", row: 0, col: 8, room: 32)
        #expect(renderer.refresh(s))
        // The same suggestion: nothing to draw.
        #expect(!renderer.refresh(s))
        renderer.ghost = nil
        #expect(renderer.refresh(s))
    }

    /// Its glyphs land in the cells after the cursor, dimmer than the text's.
    @Test func dimmedAfterTheCursor() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let fonts = FontSet(pointSize: 13, scale: 2)
        let renderer = try TerminalRenderer(device: device, fonts: fonts)
        let s = try session(fonts: fonts)
        s.show("\u{1b}]133;A\u{07}$ \u{1b}]133;B\u{07}ls")
        let width = 40 * fonts.cellWidth, height = 4 * fonts.cellHeight
        func ink(columns: Range<Int>) throws -> Int {
            let desc = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: width, height: height, mipmapped: false)
            desc.usage = [.renderTarget, .shaderRead]
            desc.storageMode = .shared
            let texture = try #require(device.makeTexture(descriptor: desc))
            renderer.renderOffscreen(s, into: texture)
            var pixels = [UInt8](repeating: 0, count: width * height * 4)
            texture.getBytes(&pixels, bytesPerRow: width * 4, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
            // How far from the background the cells' pixels are, all told.
            let bg = (pixels[0], pixels[1], pixels[2])
            var total = 0
            for y in 0..<fonts.cellHeight {
                for x in (columns.lowerBound * fonts.cellWidth)..<(columns.upperBound * fonts.cellWidth) {
                    let i = (y * width + x) * 4
                    total += abs(Int(pixels[i]) - Int(bg.0)) + abs(Int(pixels[i + 1]) - Int(bg.1)) + abs(Int(pixels[i + 2]) - Int(bg.2))
                }
            }
            return total
        }
        // Past the cursor's own cell (a block cursor covers it).
        let blank = try ink(columns: 5..<9)
        renderer.ghost = TerminalRenderer.Ghost(text: " -la /tmp", row: 0, col: 4, room: 36)
        let ghost = try ink(columns: 5..<9)
        let typed = try ink(columns: 2..<4)
        #expect(blank == 0)
        #expect(ghost > 0)
        // Dimmer: less ink per drawn character than what's typed.
        #expect(Double(ghost) / 4 < Double(typed) / 2)
        // No room: nothing drawn.
        renderer.ghost = TerminalRenderer.Ghost(text: " -la /tmp", row: 0, col: 4, room: 0)
        #expect(try ink(columns: 5..<9) == 0)
    }
}
