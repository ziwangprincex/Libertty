import AppKit
import WebKit

/// `libertty +browser`: a command for a browser block, from a script or an
/// agent in a terminal. It reaches the running app as a distributed
/// notification; the answer is written to a file of the command's own (in
/// the temporary folder, named for its token) and announced by another.
/// Reading or acting in pages needs `browser-automation = true`: a page may
/// be one you're signed in to. Opening and moving between pages don't.
///
/// Which browser: `--pane ID` names one (its own ID, `b1`, from `list` or
/// `open`; or a terminal's session, for the browser beside it), else the
/// one beside the terminal the command runs in (`$LIBERTTY_SESSION`), else
/// the one in front. None of it brings anything forward or takes the
/// keyboard, so it works on a page in a tab not in front, or another window.
enum BrowserAutomation {
    static let replied = Notification.Name("dev.libertty.terminal.browser-reply")

    /// What doesn't need the setting: nothing of a page comes back from these.
    static let unguarded: Set<String> = ["open", "go", "back", "forward", "reload"]

    static let usage = """
        usage: libertty +browser [--pane ID] COMMAND (libertty +help lists them)
          list | open [--split | --tab] [--beside SESSION] [--no-focus] [URL]
          go URL | back | forward | reload | url | title | eval JS | screenshot FILE.png
          snapshot [--interactive] [SELECTOR | --ref REF] | text [SELECTOR] | html [SELECTOR]
          click | hover | check | uncheck (SELECTOR | --ref REF) [--force]
          type (SELECTOR | --ref REF) TEXT [--append] [--keys] [--enter] | press KEY [SELECTOR] | select (SELECTOR | --ref REF) VALUE...
          scroll (up | down | left | right | top | bottom) [PIXELS] | scroll SELECTOR
          wait (SELECTOR | --selector CSS | --text TEXT | --url PATTERN | --load) [--gone] [--timeout S]
          cookies save FILE | cookies load FILE | cookies clear [--domain HOST]
        """

    /// One `+browser` command, ready to send.
    struct Request {
        var info: [String: String]
        /// The answer goes here (a screenshot, saved cookies), written by the command: Libertty writes only its reply file.
        var saveTo: String?
        /// A file the command hands over (cookies to load).
        var loadFrom: String?
        /// How long the command waits for the answer.
        var patience: TimeInterval = 30
    }

    private static let valued = ["--pane": "pane", "--ref": "ref", "--beside": "beside", "--timeout": "timeout",
                                 "--selector": "waitSelector", "--text": "waitText", "--url": "waitURL",
                                 "--domain": "domain", "--max": "max"]
    private static let flags = ["--split": "split", "--tab": "tab", "--no-focus": "noFocus", "--enter": "enter",
                                "--force": "force", "--interactive": "interactive", "--load": "waitLoad",
                                "--gone": "gone", "--append": "append", "--keys": "keys", "--json": "json"]
    static let scrollDirections: Set<String> = ["up", "down", "left", "right", "top", "bottom"]

    /// `args` (after `+browser`) as a request, or what's wrong with them.
    /// `caller`: the session the command runs in, whose tab's browser is the one meant.
    static func parse(_ args: [String], caller: String?) -> Result<Request, Problem> {
        var info = ["kind": "browser"]
        var words: [String] = []
        var i = 0
        while i < args.count {
            let a = args[i]
            if a == "--" {
                words += args[(i + 1)...]
                break
            }
            if let key = valued[a] {
                guard i + 1 < args.count else { return .failure("\(a) needs a value") }
                info[key] = args[i + 1]
                i += 2
                continue
            }
            if let key = flags[a] {
                info[key] = "1"
                i += 1
                continue
            }
            if a.hasPrefix("--"), a.count > 2 { return .failure("unknown option \(a) (a text that starts with -- goes after a --)") }
            words.append(a)
            i += 1
        }
        guard let op = words.first else { return .failure(Problem(text: usage)) }
        var rest = Array(words.dropFirst())
        if let caller, !caller.isEmpty { info["caller"] = caller }
        var request = Request(info: info)
        func target() -> String? {
            // SELECTOR or --ref, not both: what's left after it is the command's.
            if request.info["ref"] != nil { return nil }
            guard !rest.isEmpty else { return "which element: a CSS selector, or --ref REF from a snapshot" }
            request.info["selector"] = rest.removeFirst()
            return nil
        }
        func none(_ extra: [String]) -> String? { extra.isEmpty ? nil : "\(op) takes no \(extra.joined(separator: " "))" }
        var problem: String?
        switch op {
        case "list":
            problem = none(rest)
        case "open":
            if request.info["split"] != nil, request.info["tab"] != nil { return .failure("--split or --tab, not both") }
            if request.info["beside"] != nil { request.info["split"] = "1" }
            if rest.count > 1 { return .failure("open takes one address") }
            request.info["url"] = rest.first ?? ""
        case "go":
            guard rest.count == 1 else { return .failure("usage: libertty +browser go URL") }
            request.info["url"] = rest[0]
        case "back", "forward", "reload", "url", "title":
            problem = none(rest)
        case "text", "html", "snapshot":
            if request.info["ref"] == nil, let selector = rest.first {
                request.info["selector"] = selector
                rest.removeFirst()
            }
            problem = none(rest)
            if let max = request.info["max"], Int(max) == nil { problem = "--max takes a number of lines" }
        case "click", "hover", "check", "uncheck":
            problem = target() ?? none(rest)
        case "type":
            problem = target()
            if problem == nil {
                guard rest.count == 1 else { return .failure("usage: libertty +browser type (SELECTOR | --ref REF) TEXT [--enter]") }
                request.info["text"] = rest[0]
            }
        case "press":
            guard let key = rest.first else { return .failure("usage: libertty +browser press KEY [SELECTOR | --ref REF]") }
            request.info["key"] = key
            rest.removeFirst()
            if request.info["ref"] == nil, let selector = rest.first {
                request.info["selector"] = selector
                rest.removeFirst()
            }
            problem = none(rest)
        case "select":
            problem = target()
            if problem == nil {
                guard !rest.isEmpty else { return .failure("usage: libertty +browser select (SELECTOR | --ref REF) VALUE...") }
                request.info["values"] = rest.joined(separator: "\u{1f}")
            }
        case "scroll":
            if let first = rest.first, scrollDirections.contains(first) {
                request.info["direction"] = first
                rest.removeFirst()
                if let amount = rest.first, let n = Int(amount), n > 0 {
                    request.info["amount"] = String(n)
                    rest.removeFirst()
                }
            } else if request.info["ref"] == nil, let selector = rest.first {
                request.info["selector"] = selector
                rest.removeFirst()
            }
            if request.info["direction"] == nil, request.info["selector"] == nil, request.info["ref"] == nil {
                return .failure("scroll where: up, down, left, right, top, bottom [PIXELS], or an element")
            }
            problem = none(rest)
        case "wait":
            if let selector = rest.first, request.info["waitSelector"] == nil {
                request.info["waitSelector"] = selector
                rest.removeFirst()
            }
            let conditions = ["waitSelector", "waitText", "waitURL", "waitLoad"].filter { request.info[$0] != nil }
            guard conditions.count == 1 else {
                return .failure("wait for one thing: SELECTOR, --text TEXT, --url PATTERN or --load")
            }
            if request.info["waitLoad"] != nil, request.info["gone"] != nil { return .failure("--load can't be --gone") }
            let timeout = request.info["timeout"].map { Double($0) } ?? 10
            guard let timeout, timeout >= 0, timeout <= 600 else { return .failure("--timeout takes seconds, up to 600") }
            request.info["timeout"] = String(timeout)
            request.patience = timeout + 15
            problem = none(rest)
        case "eval":
            guard rest.count == 1 else { return .failure("usage: libertty +browser eval JS (one argument: quote it)") }
            request.info["text"] = rest[0]
        case "screenshot":
            guard rest.count == 1 else { return .failure("usage: libertty +browser screenshot FILE.png") }
            request.saveTo = absolute(rest[0])
        case "cookies":
            guard let what = rest.first else { return .failure("usage: libertty +browser cookies save FILE | load FILE | clear [--domain HOST]") }
            rest.removeFirst()
            request.info["what"] = what
            switch what {
            case "save":
                guard rest.count == 1 else { return .failure("usage: libertty +browser cookies save FILE [--domain HOST]") }
                request.saveTo = absolute(rest[0])
            case "load":
                guard rest.count == 1 else { return .failure("usage: libertty +browser cookies load FILE") }
                request.loadFrom = absolute(rest[0])
            case "clear":
                problem = none(rest)
            default:
                return .failure("cookies save FILE, load FILE or clear")
            }
        default:
            return .failure("unknown +browser command \(op)\n\(usage)")
        }
        if let problem { return .failure(Problem(text: problem)) }
        request.info["op"] = op
        return .success(request)
    }

    private static func absolute(_ path: String) -> String {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL.path
    }

    // MARK: The command's side

    /// Carry out `request`: hand it to `deliver` (a notification to the
    /// running app; the probe hands it over itself) and wait for its answer,
    /// running the loop with `pump`. What to print and the exit status: 0, 1
    /// when it failed, 124 when a wait ran out of time.
    static func perform(_ request: Request, deliver: ([String: String]) -> Void,
                        pump: (TimeInterval) -> Void) -> (out: String, err: String, status: Int32) {
        let token = UUID().uuidString
        let out = FileManager.default.temporaryDirectory.appendingPathComponent("libertty-browser-\(token)")
        let input = URL(fileURLWithPath: out.path + "-in")
        var info = request.info
        info["token"] = token
        info["out"] = out.path
        defer {
            try? FileManager.default.removeItem(at: out)
            try? FileManager.default.removeItem(at: input)
        }
        if let from = request.loadFrom {
            guard let data = FileManager.default.contents(atPath: from) else { return ("", "can't read \(from)", 1) }
            guard FileManager.default.createFile(atPath: input.path, contents: data, attributes: [.posixPermissions: 0o600]) else {
                return ("", "can't hand \(from) over", 1)
            }
        }
        var answer: (ok: Bool, code: Int32?)?
        let center = DistributedNotificationCenter.default()
        let observer = center.addObserver(forName: replied, object: nil, queue: .main) { note in
            guard note.userInfo?["token"] as? String == token else { return }
            answer = (note.userInfo?["ok"] as? String == "1", (note.userInfo?["code"] as? String).flatMap { Int32($0) })
        }
        defer { center.removeObserver(observer) }
        deliver(info)
        let deadline = Date().addingTimeInterval(request.patience)
        while answer == nil, Date() < deadline { pump(0.05) }
        guard let answer else { return ("", "no answer from Libertty", 1) }
        let data = (try? Data(contentsOf: out)) ?? Data()
        guard answer.ok else {
            let text = String(decoding: data, as: UTF8.self)
            return ("", text.isEmpty ? "\(info["op"] ?? "it") failed" : text, answer.code ?? 1)
        }
        if let to = request.saveTo {
            // Cookies are as good as being signed in: for this user only.
            // (A file there is replaced; a folder isn't.)
            let attributes: [FileAttributeKey: Any]? = info["op"] == "cookies" ? [.posixPermissions: 0o600] : nil
            guard FileManager.default.createFile(atPath: to, contents: data, attributes: attributes) else {
                return ("", "can't write \(to)", 1)
            }
            if info["op"] == "cookies" {
                let count = (try? JSONSerialization.jsonObject(with: data) as? [Any])?.count ?? 0
                return ("\(count) cookie\(count == 1 ? "" : "s") saved to \(to)", "", 0)
            }
            return (to, "", 0)
        }
        return (String(decoding: data, as: UTF8.self), "", 0)
    }

    // MARK: Libertty's side

    /// Carry out `info` among `controllers` and answer through the reply
    /// file. `front`: where `open` goes by default (`newWindow` when there's
    /// none); `activate`: bring Libertty forward (`open` without --no-focus).
    static func handle(_ info: [String: String], in controllers: [TerminalWindowController], front: TerminalWindowController?,
                       newWindow: () -> TerminalWindowController?, activate: () -> Void) {
        // The answer goes only where the command waits for it: its token's
        // file in the temporary folder (any process can post this notification).
        guard let token = info["token"], UUID(uuidString: token) != nil, let out = info["out"] else { return }
        let outURL = URL(fileURLWithPath: out)
        guard outURL.lastPathComponent == "libertty-browser-\(token)",
              outURL.deletingLastPathComponent().resolvingSymlinksInPath().path
                == URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path else { return }
        func reply(_ ok: Bool, _ data: Data, code: Int32? = nil) {
            try? data.write(to: outURL, options: .atomic)
            var answer = ["token": token, "ok": ok ? "1" : "0"]
            if let code { answer["code"] = String(code) }
            DistributedNotificationCenter.default().postNotificationName(replied, object: nil, userInfo: answer, deliverImmediately: true)
        }
        func say(_ ok: Bool, _ text: String, code: Int32? = nil) { reply(ok, Data(text.utf8), code: code) }

        let op = info["op"] ?? ""
        let config = ConfigStore.shared.config
        if !unguarded.contains(op), !config.browserAutomation {
            return say(false, "\(op) needs browser-automation = true in the config (pages may be ones you're signed in to)")
        }
        if op == "open" { return open(info, in: controllers, front: front, newWindow: newWindow, activate: activate, say: say) }
        if op == "list" { return say(true, list(info, in: controllers, front: front)) }
        let page: DocumentView
        switch browser(for: info, in: controllers, front: front) {
        case .success(let p): page = p
        case .failure(let why): return say(false, why.text)
        }
        // One in a tab never shown has no size to click in or picture yet.
        let owner = controllers.first { $0.documents(in: $0.everyTab).contains { $0 === page } }
        page.lendSize(owner?.pageSize ?? NSSize(width: 1280, height: 800))
        let search = config.browserSearch
        switch op {
        case "url": say(true, page.pageURL.absoluteString)
        case "title": say(true, page.pageTitle)
        case "back": page.browserBack(); say(true, "")
        case "forward": page.browserForward(); say(true, "")
        case "reload": page.reload(); say(true, "")
        case "go":
            guard let url = BrowserBar.destination(info["url"] ?? "", search: search) else { return say(false, "not an address: \(info["url"] ?? "")") }
            page.browse(to: url)
            say(true, url.absoluteString)
        case "eval":
            page.pageScript(info["text"] ?? "") { value, error in
                if let error { return say(false, error) }
                say(true, Self.json(value))
            }
        case "screenshot":
            page.snapshot { image in
                guard let image, let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    return say(false, "couldn't take the picture")
                }
                reply(true, png)
            }
        case "cookies":
            cookies(info, page: page, outURL: outURL, reply: reply)
        case "wait":
            wait(on: page, info, say: say)
        case _ where automated.contains(op):
            page.automate(op == "uncheck" ? "check" : op, arguments(info)) { ok, text in say(ok, text) }
        default:
            say(false, "unknown +browser command \(op)")
        }
    }

    /// What the page's own library does (BrowserScript).
    private static let automated: Set<String> = ["text", "html", "snapshot", "click", "hover", "type", "press", "select",
                                                 "check", "uncheck", "scroll"]

    /// What the page's library takes from `info`.
    private static func arguments(_ info: [String: String]) -> [String: Any] {
        var a: [String: Any] = [:]
        for key in ["selector", "ref", "text", "key", "direction"] { if let v = info[key] { a[key] = v } }
        for key in ["force", "append", "enter", "keys", "interactive"] { a[key] = info[key] == "1" }
        if let values = info["values"] { a["values"] = values.components(separatedBy: "\u{1f}") }
        if let max = info["max"].flatMap(Int.init) { a["max"] = max }
        if let amount = info["amount"].flatMap(Int.init) { a["amount"] = amount }
        a["want"] = info["op"] != "uncheck"
        return a
    }

    /// What a command got wrong, or what it names that isn't there.
    struct Problem: Error, ExpressibleByStringInterpolation {
        let text: String
        init(text: String) { self.text = text }
        init(stringLiteral value: String) { text = value }
    }

    /// The browser a command means (see the type's comment).
    static func browser(for info: [String: String], in controllers: [TerminalWindowController],
                        front: TerminalWindowController?) -> Result<DocumentView, Problem> {
        if let id = info["pane"] {
            for c in controllers {
                if let page = c.browsers.first(where: { $0.page.browserID == id })?.page { return .success(page) }
            }
            for c in controllers where c.pane(showing: id) != nil {
                if let page = c.browser(besideSession: id) { return .success(page) }
                return .failure(Problem(text: "no browser beside session \(id) (libertty +browser open --split --beside \(id) URL)"))
            }
            return .failure(Problem(text: "no browser or session \(id) (libertty +browser list)"))
        }
        if let caller = info["caller"], let page = controllers.lazy.compactMap({ $0.browser(besideSession: caller) }).first {
            return .success(page)
        }
        if let page = front?.frontBrowser ?? controllers.lazy.compactMap(\.frontBrowser).first { return .success(page) }
        return .failure(Problem(text: "no browser open (libertty +browser open URL)"))
    }

    private static func open(_ info: [String: String], in controllers: [TerminalWindowController], front: TerminalWindowController?,
                             newWindow: () -> TerminalWindowController?, activate: () -> Void, say: (Bool, String, Int32?) -> Void) {
        let address = info["url"] ?? ""
        guard let url = BrowserBar.destination(address.isEmpty ? "about:blank" : address, search: ConfigStore.shared.config.browserSearch) else {
            return say(false, "not an address: \(address)", nil)
        }
        // Beside a terminal named, else the command's own, else in front.
        var controller = front
        var pane: TerminalView?
        if let beside = info["beside"] {
            guard let found = controllers.lazy.compactMap({ c in c.pane(showing: beside).map { (c, $0) } }).first else {
                return say(false, "no session \(beside) in a window", nil)
            }
            (controller, pane) = (found.0, found.1)
        } else if let caller = info["caller"], let found = controllers.lazy.compactMap({ c in c.pane(showing: caller).map { (c, $0) } }).first {
            controller = found.0
            if info["split"] == "1" { pane = found.1 }
        }
        guard let controller = controller ?? newWindow() else { return say(false, "no Libertty window", nil) }
        let focus = info["noFocus"] != "1"
        guard let page = controller.openBrowserPage(url, beside: pane, split: info["split"] == "1", focus: focus) else {
            return say(false, "no terminal to put it beside", nil)
        }
        if focus { activate() }
        say(true, page.browserID, nil)
    }

    /// `+browser list`: every browser, the one a command would act on marked `*`.
    private static func list(_ info: [String: String], in controllers: [TerminalWindowController],
                             front: TerminalWindowController?) -> String {
        var key = info
        key["pane"] = nil
        let meant = try? browser(for: key, in: controllers, front: front).get()
        var rows: [[String: Any]] = []
        for (w, c) in controllers.enumerated() {
            for b in c.browsers {
                var row: [String: Any] = ["id": b.page.browserID, "url": b.page.pageURL.absoluteString, "title": b.page.pageTitle,
                                          "window": w + 1, "where": b.place, "default": b.page === meant]
                if let beside = b.beside { row["beside"] = beside }
                rows.append(row)
            }
        }
        if info["json"] == "1" { return JSON.text(rows) }
        return rows.map { row in
            let id = row["id"] as? String ?? "", mark = row["default"] as? Bool == true ? " *" : ""
            return "\(id)  \(row["url"] as? String ?? "")  \(Self.quoted(row["title"] as? String ?? ""))  window \(row["window"] ?? 1) \(row["where"] ?? "")\(mark)"
        }.joined(separator: "\n")
    }

    /// `wait`: asked again every tenth of a second until it holds, or its time is up (status 124).
    private static func wait(on page: DocumentView, _ info: [String: String], say: @escaping (Bool, String, Int32?) -> Void) {
        let timeout = Double(info["timeout"] ?? "") ?? 10
        let deadline = Date().addingTimeInterval(timeout)
        let gone = info["gone"] == "1"
        let what: String
        if let s = info["waitSelector"] { what = gone ? "\(s) is still there" : "nothing shown matches \(s)" }
        else if let t = info["waitText"] { what = gone ? "the page still says \(Self.quoted(t))" : "the page doesn't say \(Self.quoted(t))" }
        else if let u = info["waitURL"] { what = gone ? "the address still matches \(u)" : "the address doesn't match \(u)" }
        else { what = "the page hasn't loaded" }
        func ask() {
            check { holds, failure in
                if let failure { return say(false, failure, nil) }
                if holds { return say(true, page.pageURL.absoluteString, nil) }
                guard Date() < deadline else { return say(false, "waited \(Self.seconds(timeout)): \(what)", 124) }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { ask() }
            }
        }
        func check(_ done: @escaping (Bool, String?) -> Void) {
            if let pattern = info["waitURL"] {
                return done(Self.matches(page.pageURL.absoluteString, pattern) != gone, nil)
            }
            if info["waitLoad"] != nil, page.isPageLoading { return done(false, nil) }
            var a: [String: Any] = ["gone": gone]
            if let s = info["waitSelector"] { a["selector"] = s }
            if let t = info["waitText"] { a["text"] = t }
            page.automate("holds", a) { ok, text in
                // A page between documents doesn't answer: not yet. A selector that isn't one never will.
                if !ok, text.hasPrefix("not a CSS selector") { return done(false, text) }
                done(ok && text == "yes", nil)
            }
        }
        ask()
    }

    /// An address against `wait --url`'s pattern: a part of it, or with `*` the whole of it.
    static func matches(_ address: String, _ pattern: String) -> Bool {
        guard pattern.contains("*") else { return address.contains(pattern) }
        let regex = "^" + pattern.split(separator: "*", omittingEmptySubsequences: false)
            .map { NSRegularExpression.escapedPattern(for: String($0)) }.joined(separator: ".*") + "$"
        return address.range(of: regex, options: .regularExpression) != nil
    }

    // MARK: Cookies

    private static func cookies(_ info: [String: String], page: DocumentView, outURL: URL,
                                reply: @escaping (Bool, Data, Int32?) -> Void) {
        let store = page.cookieStore
        let domain = info["domain"]
        func say(_ ok: Bool, _ text: String) { reply(ok, Data(text.utf8), nil) }
        switch info["what"] {
        case "save":
            store.getAllCookies { all in reply(true, cookieJSON(all.filter { within(domain, $0) }), nil) }
        case "load":
            let input = URL(fileURLWithPath: outURL.path + "-in")
            guard let data = try? Data(contentsOf: input) else { return say(false, "the cookies weren't handed over") }
            try? FileManager.default.removeItem(at: input)
            let cookies: [HTTPCookie]
            do { cookies = try Self.cookies(from: data) } catch { return say(false, "not a cookies file \(Self.quoted(error.localizedDescription))") }
            let group = DispatchGroup()
            for cookie in cookies {
                group.enter()
                store.setCookie(cookie) { group.leave() }
            }
            group.notify(queue: .main) { say(true, "\(cookies.count) cookie\(cookies.count == 1 ? "" : "s") loaded") }
        case "clear":
            store.getAllCookies { all in
                let going = all.filter { within(domain, $0) }
                let group = DispatchGroup()
                for cookie in going {
                    group.enter()
                    store.delete(cookie) { group.leave() }
                }
                group.notify(queue: .main) { say(true, "\(going.count) cookie\(going.count == 1 ? "" : "s") cleared") }
            }
        default:
            say(false, "cookies save FILE, load FILE or clear")
        }
    }

    /// A cookie of `host` (or a site under it); every cookie without one.
    static func within(_ host: String?, _ cookie: HTTPCookie) -> Bool {
        guard let host = host?.lowercased(), !host.isEmpty else { return true }
        let domain = (cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain).lowercased()
        return domain == host || domain.hasSuffix("." + host)
    }

    /// Cookies as `cookies save` writes them: a JSON list of what each is.
    static func cookieJSON(_ cookies: [HTTPCookie]) -> Data {
        let list: [[String: Any]] = cookies.sorted { ($0.domain, $0.name) < ($1.domain, $1.name) }.map { c in
            var item: [String: Any] = ["name": c.name, "value": c.value, "domain": c.domain, "path": c.path,
                                       "secure": c.isSecure, "httpOnly": c.isHTTPOnly]
            if let expires = c.expiresDate { item["expires"] = expires.timeIntervalSince1970 }
            if let policy = c.sameSitePolicy { item["sameSite"] = policy.rawValue }
            return item
        }
        return Data(JSON.text(list).utf8)
    }

    struct CookieFileError: LocalizedError {
        let errorDescription: String?
    }

    /// The cookies of a file `cookies save` wrote.
    static func cookies(from data: Data) throws -> [HTTPCookie] {
        guard let list = try JSONSerialization.jsonObject(with: data) as? [[String: Any]] else {
            throw CookieFileError(errorDescription: "a list of cookies")
        }
        return try list.enumerated().map { n, item in
            guard let name = item["name"] as? String, let value = item["value"] as? String,
                  let domain = item["domain"] as? String, !domain.isEmpty else {
                throw CookieFileError(errorDescription: "cookie \(n + 1) needs a name, a value and a domain")
            }
            var properties: [HTTPCookiePropertyKey: Any] = [.name: name, .value: value, .domain: domain,
                                                             .path: item["path"] as? String ?? "/"]
            if item["secure"] as? Bool == true { properties[.secure] = "TRUE" }
            if item["httpOnly"] as? Bool == true { properties[HTTPCookiePropertyKey("HttpOnly")] = "TRUE" }
            if let expires = item["expires"] as? Double { properties[.expires] = Date(timeIntervalSince1970: expires) }
            if let policy = item["sameSite"] as? String { properties[.sameSitePolicy] = policy }
            guard let cookie = HTTPCookie(properties: properties) else {
                throw CookieFileError(errorDescription: "cookie \(n + 1) (\(name)) isn't one WebKit takes")
            }
            return cookie
        }
    }

    // MARK: Text

    /// A value from `eval` as JSON (a string as itself).
    static func json(_ value: Any?) -> String {
        guard let value else { return "undefined" }
        if value is NSNull { return "null" }
        if let s = value as? String { return s }
        // NaN or a date would make JSONSerialization raise (not throw): ask first.
        guard JSONSerialization.isValidJSONObject([value]),
              let data = try? JSONSerialization.data(withJSONObject: [value]) else { return String(describing: value) }
        return String(String(decoding: data, as: UTF8.self).dropFirst().dropLast())
    }

    private static func quoted(_ s: String) -> String { JSON.text(s) }

    private static func seconds(_ t: Double) -> String {
        t == t.rounded() ? "\(Int(t)) s" : String(format: "%.1f s", t)
    }
}
