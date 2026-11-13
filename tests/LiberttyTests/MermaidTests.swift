import Foundation
import Testing
@testable import LiberttyApp

/// Mermaid fences: what the document gets in their place, and what's left
/// of a diagram's SVG before it goes into the page.
struct MermaidTests {
    @Test func fencesGoToTheDiagramHook() {
        var renderer = MarkdownRenderer()
        renderer.diagram = { "<div class=\"diagram\">\($0.count)</div>" }
        let html = renderer.render("# A\n\n```mermaid\ngraph TD\n  A --> B\n```\n\n```swift\nlet x = 1\n```\n")
        #expect(renderer.diagrams == ["graph TD\n  A --> B"])
        #expect(html.contains("<div class=\"diagram\">18</div>"))
        #expect(html.contains("language-swift"))
        // Without a hook (`+render-markdown`, notebooks), code like any other.
        var plain = MarkdownRenderer()
        #expect(plain.render("```mermaid\ngraph TD\n```\n").contains("class=\"language-mermaid\""))
        #expect(plain.diagrams.isEmpty)
    }

    @Test func aPendingDiagramShowsItsSourceEscaped() {
        let theme = Theme(name: "t", background: RGB(255, 255, 255), foreground: RGB(0, 0, 0), cursor: RGB(0, 0, 0),
                          selection: RGB(200, 200, 200), ansi: Array(repeating: RGB(1, 2, 3), count: 16))
        let source = "graph TD\n  A[<b>x</b>] --> B \"q\" \(UUID().uuidString)"
        let html = MermaidRenderer.shared.html(source, theme: theme)
        #expect(html.contains("mermaid-pending"))
        #expect(html.contains("A[&lt;b&gt;x&lt;/b&gt;]") && !html.contains("<b>x</b>"))
    }

    @Test func whatOfTheSVGStays() {
        let svg = """
            <svg id="d1" xmlns="http://www.w3.org/2000/svg"><style>@import url(https://evil.example/x.css); #d1 .a{fill:url(#grad)} \
            .b{background:url(https://evil.example/t.png)}</style><script>alert(1)</script><script src="https://evil.example/x.js"/>\
            <g onclick="alert(2)" onMouseOver='alert(3)'><path marker-end="url(#d1_arrow)"/><use href="#d1_node"/>\
            <a href="javascript:alert(4)">x</a><a xlink:href="https://example.com">y</a>\
            <foreignObject><div><img src="https://evil.example/p.png"><img src="data:image/png;base64,AAAA">\
            <iframe src="https://evil.example"></iframe></div></foreignObject></g></svg>
            """
        let clean = MermaidRenderer.clean(svg)
        for gone in ["<script", "alert(", "evil.example", "javascript:", "@import", "<iframe", "https://example.com"] {
            #expect(!clean.contains(gone), "still has \(gone)")
        }
        for kept in ["url(#grad)", "url(#d1_arrow)", "href=\"#d1_node\"", "data:image/png;base64,AAAA", "<foreignObject>"] {
            #expect(clean.contains(kept), "lost \(kept)")
        }
    }

    @Test func whatWentWrongInOneLine() {
        #expect(MermaidRenderer.firstLine("UnknownDiagramError: No diagram type detected matching given configuration for text: x\nmore")
                == "No diagram type detected matching given configuration for text: x")
        #expect(MermaidRenderer.firstLine("Error: Parse error on line 3:\n...") == "Parse error on line 3:")
    }
}
