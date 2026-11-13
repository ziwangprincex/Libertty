import Foundation
import Testing
@testable import LiberttyApp

/// `libertty +browser`'s command lines, and what it reads and writes besides the page.
struct BrowserAutomationTests {
    private func parsed(_ line: [String], caller: String? = nil) -> BrowserAutomation.Request? {
        try? BrowserAutomation.parse(line, caller: caller).get()
    }

    private func problem(_ line: [String]) -> String? {
        if case .failure(let why) = BrowserAutomation.parse(line, caller: nil) { return why.text }
        return nil
    }

    @Test func aTargetIsASelectorOrARef() {
        let bySelector = parsed(["click", "#go"])
        #expect(bySelector?.info["op"] == "click")
        #expect(bySelector?.info["selector"] == "#go")
        let byRef = parsed(["click", "--ref", "e4"])
        #expect(byRef?.info["ref"] == "e4")
        #expect(byRef?.info["selector"] == nil)
        #expect(problem(["click"])?.contains("which element") == true)
        #expect(problem(["click", "--ref", "e4", "#go"])?.contains("takes no #go") == true)
    }

    @Test func typeTakesItsTextAfterTheTarget() {
        let r = parsed(["type", "#q", "hello world", "--enter"])
        #expect(r?.info["selector"] == "#q")
        #expect(r?.info["text"] == "hello world")
        #expect(r?.info["enter"] == "1")
        #expect(parsed(["type", "--ref", "e3", "Ada"])?.info["text"] == "Ada")
        // A text that starts with -- goes after a --.
        #expect(problem(["type", "#q", "--verbose"])?.contains("unknown option --verbose") == true)
        #expect(parsed(["type", "#q", "--", "--verbose"])?.info["text"] == "--verbose")
    }

    @Test func optionsGoAnywhere() {
        let r = parsed(["--pane", "b2", "text", "#out"], caller: "66a80177")
        #expect(r?.info["pane"] == "b2")
        #expect(r?.info["selector"] == "#out")
        #expect(r?.info["caller"] == "66a80177")
        #expect(parsed(["text", "#out", "--pane", "b2"])?.info["pane"] == "b2")
        #expect(problem(["text", "--pane"]) == "--pane needs a value")
    }

    @Test func openBesideIsASplit() {
        let r = parsed(["open", "--beside", "66a80177", "--no-focus", "localhost:3000"])
        #expect(r?.info["split"] == "1")
        #expect(r?.info["noFocus"] == "1")
        #expect(r?.info["url"] == "localhost:3000")
        #expect(problem(["open", "--split", "--tab", "x"]) == "--split or --tab, not both")
    }

    @Test func waitIsForOneThingAndForAWhile() {
        let r = parsed(["wait", "#late", "--timeout", "2.5"])
        #expect(r?.info["waitSelector"] == "#late")
        #expect(r?.patience == 17.5)
        #expect(parsed(["wait", "--text", "Done"])?.info["timeout"] == "10.0")
        #expect(problem(["wait"])?.contains("wait for one thing") == true)
        #expect(problem(["wait", "#a", "--text", "b"])?.contains("wait for one thing") == true)
        #expect(problem(["wait", "--load", "--gone"]) == "--load can't be --gone")
        #expect(problem(["wait", "--load", "--timeout", "soon"]) == "--timeout takes seconds, up to 600")
        #expect(problem(["wait", "--load", "--timeout", "601"]) == "--timeout takes seconds, up to 600")
    }

    @Test func scrollGoesSomewhere() {
        let r = parsed(["scroll", "down", "300"])
        #expect(r?.info["direction"] == "down")
        #expect(r?.info["amount"] == "300")
        #expect(parsed(["scroll", "#footer"])?.info["selector"] == "#footer")
        #expect(parsed(["scroll", "up", "--ref", "e2"])?.info["ref"] == "e2")
        #expect(problem(["scroll"])?.hasPrefix("scroll where") == true)
    }

    @Test func filesAreTheCommandsOwn() {
        // The command writes and reads them, in its own name; Libertty only its reply file.
        let shot = parsed(["screenshot", "shot.png"])
        #expect(shot?.saveTo == URL(fileURLWithPath: "shot.png").standardizedFileURL.path)
        #expect(shot?.info["file"] == nil)
        #expect(parsed(["cookies", "load", "/tmp/c.json"])?.loadFrom == "/tmp/c.json")
        #expect(parsed(["cookies", "save", "/tmp/c.json", "--domain", "example.com"])?.info["domain"] == "example.com")
        #expect(problem(["cookies", "eat"]) == "cookies save FILE, load FILE or clear")
    }

    @Test func unknownCommandsSaySo() {
        #expect(problem(["frobnicate"])?.hasPrefix("unknown +browser command frobnicate") == true)
        #expect(problem([]) == BrowserAutomation.usage)
        #expect(problem(["select", "#color"])?.hasPrefix("usage: libertty +browser select") == true)
    }

    @Test func addressPatterns() {
        #expect(BrowserAutomation.matches("http://localhost:3000/done", "/done"))
        #expect(!BrowserAutomation.matches("http://localhost:3000/", "/done"))
        #expect(BrowserAutomation.matches("http://localhost:3000/users/7/edit", "*/users/*/edit"))
        #expect(!BrowserAutomation.matches("http://localhost:3000/users/7/edit?x", "*/users/*/edit"))
        // Regex characters in a pattern are themselves.
        #expect(BrowserAutomation.matches("http://a.test/?q=1", "*?q=1"))
        #expect(!BrowserAutomation.matches("http://aXtest/", "http://a.test*"))
    }

    @Test func cookiesOfAHostAndItsSites() {
        let make = { (domain: String) in HTTPCookie(properties: [.name: "n", .value: "v", .domain: domain, .path: "/"])! }
        #expect(BrowserAutomation.within("example.com", make(".example.com")))
        #expect(BrowserAutomation.within("example.com", make("app.example.com")))
        #expect(!BrowserAutomation.within("example.com", make("notexample.com")))
        #expect(!BrowserAutomation.within("app.example.com", make("example.com")))
        #expect(BrowserAutomation.within(nil, make("anything.test")))
    }

    @Test func cookiesComeBackAsTheyWent() throws {
        // (Foundation keeps no cookie past 400 days.)
        let expires = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 + 30 * 86400).rounded())
        let cookie = HTTPCookie(properties: [.name: "session", .value: "abc=1", .domain: ".example.com", .path: "/app",
                                             .secure: "TRUE", .expires: expires, HTTPCookiePropertyKey("HttpOnly"): "TRUE",
                                             .sameSitePolicy: "lax"])!
        let data = BrowserAutomation.cookieJSON([cookie])
        let back = try BrowserAutomation.cookies(from: data)
        #expect(back.count == 1)
        let c = try #require(back.first)
        #expect(c.name == "session" && c.value == "abc=1" && c.domain == ".example.com" && c.path == "/app")
        #expect(c.isSecure && c.isHTTPOnly)
        #expect(c.expiresDate == expires)
        #expect(c.sameSitePolicy == .sameSiteLax)
        #expect(throws: (any Error).self) { try BrowserAutomation.cookies(from: Data("{}".utf8)) }
        #expect(throws: (any Error).self) { try BrowserAutomation.cookies(from: Data(#"[{"name": "x"}]"#.utf8)) }
    }

    @Test func evalAnswersAsJSON() {
        #expect(BrowserAutomation.json(nil) == "undefined")
        #expect(BrowserAutomation.json(NSNull()) == "null")
        #expect(BrowserAutomation.json("text") == "text")
        #expect(BrowserAutomation.json(["a": 1]) == #"{"a":1}"#)
        #expect(BrowserAutomation.json(Double.nan) == "nan")
    }
}
