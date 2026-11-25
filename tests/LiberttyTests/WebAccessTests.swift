import Foundation
import Testing
@testable import LiberttyApp

/// Web Access's WebSocket frames, as a browser (or anyone with the token)
/// sends them: what a header says, and what's refused before it's read.
@MainActor
struct WebAccessTests {
    @Test func headersOfEachLength() {
        // A masked text frame of 5, its mask next.
        #expect(WebClient.frameHeader([0x81, 0x85, 1, 2, 3, 4]) == .frame(fin: true, opcode: 1, length: 5, offset: 2))
        #expect(WebClient.frameHeader([0x01, 0xFE, 0x01, 0x00]) == .frame(fin: false, opcode: 1, length: 256, offset: 4))
        #expect(WebClient.frameHeader([0x80, 0xFF, 0, 0, 0, 0, 0, 0x01, 0, 0]) == .frame(fin: true, opcode: 0, length: 65536, offset: 10))
        // Not all there yet.
        #expect(WebClient.frameHeader([0x81]) == nil)
        #expect(WebClient.frameHeader([0x81, 0xFE, 0x01]) == nil)
        #expect(WebClient.frameHeader([0x81, 0xFF, 0, 0, 0, 0]) == nil)
    }

    @Test func refusedBeforeItsLengthIsUsed() {
        // Unmasked: not a browser.
        #expect(WebClient.frameHeader([0x81, 0x05]) == .refused)
        // Over the limit.
        #expect(WebClient.frameHeader([0x81, 0xFF, 0, 0, 0, 0, 0, 0x10, 0, 1]) == .refused)
        // The 64-bit length's top bit set (RFC 6455: it's 0): as an Int it
        // was negative, passed the limit, and slicing the buffer trapped.
        #expect(WebClient.frameHeader([0x81, 0xFF, 0x80, 0, 0, 0, 0, 0, 0, 5]) == .refused)
        #expect(WebClient.frameHeader([0x81, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]) == .refused)
    }
}
