import Foundation
import Testing
@testable import LiberttyApp

/// The Markdown renderer's inline text: its placeholders never run out or
/// collide with the text's own characters, and paragraphs full of what
/// doesn't close (`<`, `[`, `**`) are read once, not once per opener.
struct MarkdownTests {
    private func render(_ text: String) -> String {
        var renderer = MarkdownRenderer()
        return renderer.render(text)
    }

    @Test func aParagraphOfEscapesNeverRunsOutOfPlaceholders() {
        // One scalar per placeholder ran out past 131,071 of them (a crash).
        let count = 140_000
        #expect(render(String(repeating: "\\.", count: count)) == "<p>" + String(repeating: ".", count: count) + "</p>\n")
        let links = String(repeating: "`x` ", count: 70_000)
        #expect(render(links).components(separatedBy: "<code>x</code>").count == 70_001)
    }

    @Test func privateUseCharactersInTheTextStayThemselves() {
        // A character from the planes placeholders use is no placeholder.
        let html = render("\u{F0000}\u{100000} `a` \u{F0001}")
        #expect(html == "<p>&#xF0000;&#x100000; <code>a</code> &#xF0001;</p>\n")
    }

    @Test func inlinePiecesAsBefore() {
        #expect(render("<https://x.y> <a@b.co> <kbd>k</kbd> <!-- a < b --> a < b > c")
            == "<p><a href=\"https://x.y\">https://x.y</a> <a href=\"mailto:a@b.co\">a@b.co</a> <kbd>k</kbd> <!-- a < b --> a &lt; b &gt; c</p>\n")
        #expect(render("<x <y> <!-- two\nlines -->") == "<p>&lt;x <y> &lt;!-- two\nlines --&gt;</p>\n")
        #expect(render("[a [b] c](u) [a [b](v) [`]`](w)")
            == "<p><a href=\"u\">a [b] c</a> [a <a href=\"v\">b</a> <a href=\"w\"><code>]</code></a></p>\n")
        #expect(render("**bold** *x* __y__ snake_case_words ~~z~~ ***both***")
            == "<p><strong>bold</strong> <em>x</em> <strong>y</strong> snake_case_words <del>z</del> <strong><em>both</em></strong></p>\n")
    }

    /// Paragraphs of openers with nothing to close them took seconds each
    /// (minutes at a few hundred KB): every one read to the paragraph's end.
    @Test func paragraphsOfUnclosedOpenersAreReadOnce() {
        var texts = ["< ", "[ ", "![ ", "[", "**a ", "__a ", "*a ", "_a ", "~~a ", "<!--\n", "h ", "<!-- <x> "].map {
            String(repeating: $0, count: 100_000 / $0.count)
        }
        // A link's text read through backticks; runs of every length, none closed.
        texts.append("[" + String(repeating: "`", count: 100_000))
        texts.append((1...440).map { String(repeating: "`", count: $0) }.joined(separator: " "))
        for text in texts {
            let start = Date()
            _ = render(text)
            let took = Date().timeIntervalSince(start)
            #expect(took < 5, "\(String(text.prefix(12)).debugDescription)…: \(took) s")
        }
    }

    /// The emphasis expressions the renderer used to run: what reading each
    /// marker once must find exactly as they did.
    private static let expressions: [(NSRegularExpression, String)] = [
        (try! NSRegularExpression(pattern: #"\*\*\*(?=\S)(.+?)(?<=\S)\*\*\*"#), "<strong><em>$1</em></strong>"),
        (try! NSRegularExpression(pattern: #"\*\*(?=\S)(.+?)(?<=\S)\*\*"#), "<strong>$1</strong>"),
        (try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}])__(?=\S)(.+?)(?<=\S)__(?![\p{L}\p{N}])"#), "<strong>$1</strong>"),
        (try! NSRegularExpression(pattern: #"\*(?=[^\s*])(.+?)(?<=[^\s*])\*"#), "<em>$1</em>"),
        (try! NSRegularExpression(pattern: #"(?<![\p{L}\p{N}_])_(?=[^\s_])(.+?)(?<=[^\s_])_(?![\p{L}\p{N}_])"#), "<em>$1</em>"),
        (try! NSRegularExpression(pattern: #"~~(?=\S)(.+?)(?<=\S)~~"#), "<del>$1</del>"),
    ]

    private static func expressionsSay(_ s: String) -> String {
        var s = s
        for (re, template) in expressions {
            s = re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: template)
        }
        return s
    }

    @Test func emphasisAsTheExpressionsFoundIt() {
        let samples = [
            "**bold** *em* ***both*** __strong__ _em_ ~~del~~", "snake_case_words a*b*c a**b**c **a **b** c**",
            "**a\nb** *a b * c* _a_b_ __a__b__ ***a** b* **a *b*** x__y__z _x_ y_z_", "** a ** * a * a_ b _c d_ é*x*é *é* _é_",
            "中*文*字 **中文** _中_ ****a**** ***** *** ** * __ _ ~~ ~~~a~~~", "*a\u{2028}b* *a\u{0B}b* *a\u{85}b* *a\u{0C}b* **a\u{3000}**",
            "_1_ _a1_ 1_a_1 *\u{F0000}\u{100000}* **x\u{F0000}\u{100000}** _\u{F0000}\u{100000}_ *👍🏽* _e\u{301}_",
        ]
        for sample in samples { #expect(MarkdownRenderer.emphasis(sample) == Self.expressionsSay(sample), "\(sample.debugDescription)") }
        // And text made of the markers and what's around them, at random.
        let alphabet: [String] = ["*", "*", "*", "_", "_", "~", "a", "b", "1", " ", " ", "\n", "é", "中", "\t", "\u{2028}", "\u{A0}", "-", "👍"]
        var generator = SystemRandomNumberGenerator()
        for _ in 0..<3000 {
            let length = Int.random(in: 1...24, using: &generator)
            let sample = (0..<length).map { _ in alphabet.randomElement(using: &generator)! }.joined()
            #expect(MarkdownRenderer.emphasis(sample) == Self.expressionsSay(sample), "\(sample.debugDescription)")
        }
    }
}
