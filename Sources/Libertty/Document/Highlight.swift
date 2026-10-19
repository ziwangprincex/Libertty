import Foundation

/// A small, fast highlighter for code blocks and source files: comments,
/// strings, numbers, keywords, types and calls, by language family. Output
/// is escaped HTML with `<span class="hl-…">`; colors come from the
/// terminal theme (see DocumentView's CSS).
enum Highlighter {
    private struct Language {
        var keywords: Set<String>
        var lineComments: [String] = ["//"]
        var blockComment: (String, String)? = ("/*", "*/")
        var strings: [Character] = ["\"", "'"]
        /// Strings that may span lines (Python's triple quotes, JS templates).
        var multilineStrings: [String] = []
    }

    private static func words(_ s: String) -> Set<String> { Set(s.split(separator: " ").map(String.init)) }

    private static let c = words("auto break case char const continue default do double else enum extern float for goto if inline int long register restrict return short signed sizeof static struct switch typedef union unsigned void volatile while bool true false NULL nullptr class namespace template typename public private protected virtual override new delete this using try catch throw const_cast static_cast dynamic_cast reinterpret_cast constexpr noexcept nil YES NO self super id instancetype @interface @implementation @end @property @selector @protocol import include define ifdef ifndef endif pragma")

    private static let languages: [String: Language] = {
        var l: [String: Language] = [:]
        let swift = Language(keywords: words("associatedtype class deinit enum extension fileprivate func import init inout internal let open operator private precedencegroup protocol public rethrows static struct subscript typealias var break case catch continue default defer do else fallthrough for guard if in repeat return throw switch where while as Any false is nil self Self super throws true try async await actor some any weak unowned lazy final override mutating nonmutating convenience required dynamic optional get set willSet didSet"),
                             multilineStrings: ["\"\"\""])
        let rust = Language(keywords: words("as async await break const continue crate dyn else enum extern false fn for if impl in let loop match mod move mut pub ref return self Self static struct super trait true type unsafe use where while Box Option Result Some None Ok Err Vec String"))
        let go = Language(keywords: words("break case chan const continue default defer else fallthrough for func go goto if import interface map package range return select struct switch type var true false nil iota append len cap make new panic recover error string int int64 uint byte rune bool float64"),
                          strings: ["\"", "'", "`"])
        let js = Language(keywords: words("await break case catch class const continue debugger default delete do else export extends false finally for from function if import in instanceof let new null of return static super switch this throw true try typeof undefined var void while with yield async interface type enum implements namespace declare readonly private public protected abstract as keyof never unknown any string number boolean"),
                          strings: ["\"", "'", "`"])
        let python = Language(keywords: words("False None True and as assert async await break class continue def del elif else except finally for from global if import in is lambda nonlocal not or pass raise return try while with yield self print len range"),
                              lineComments: ["#"], blockComment: nil, multilineStrings: ["\"\"\"", "'''"])
        let ruby = Language(keywords: words("BEGIN END alias and begin break case class def defined? do else elsif end ensure false for if in module next nil not or redo rescue retry return self super then true undef unless until when while yield require attr_accessor puts"),
                            lineComments: ["#"], blockComment: nil)
        let shell = Language(keywords: words("if then else elif fi case esac for while until do done in function return local export readonly declare set unset shift exit echo cd source alias test trap eval exec"),
                             lineComments: ["#"], blockComment: nil)
        let java = Language(keywords: words("abstract assert boolean break byte case catch char class const continue default do double else enum extends final finally float for goto if implements import instanceof int interface long native new package private protected public return short static strictfp super switch synchronized this throw throws transient try void volatile while true false null var val fun object when is in data sealed companion lateinit override open internal suspend"))
        let zig = Language(keywords: words("addrspace align allowzero and anyframe anytype asm async await break callconv catch comptime const continue defer else enum errdefer error export extern fn for if inline linksection noalias noinline nosuspend opaque or orelse packed pub resume return struct suspend switch test threadlocal try union unreachable usingnamespace var volatile while true false null undefined"),
                           blockComment: nil)
        let data = Language(keywords: words("true false null yes no on off"), lineComments: ["#"], blockComment: nil)
        let json = Language(keywords: words("true false null"), lineComments: [], blockComment: nil, strings: ["\""])
        let sql = Language(keywords: words("select from where insert into values update set delete create table index drop alter add join left right inner outer on group by order having limit offset as and or not null is in like primary key foreign references distinct union all case when then else end SELECT FROM WHERE INSERT INTO VALUES UPDATE SET DELETE CREATE TABLE JOIN ON GROUP BY ORDER LIMIT AS AND OR NOT NULL"),
                           lineComments: ["--"])
        let cLang = Language(keywords: c)
        for (names, lang) in [
            (["swift"], swift), (["rust", "rs"], rust), (["go", "golang"], go),
            (["js", "javascript", "jsx", "ts", "typescript", "tsx", "mjs", "cjs"], js),
            (["py", "python", "python3"], python), (["rb", "ruby"], ruby),
            (["sh", "bash", "zsh", "shell", "console", "fish"], shell),
            (["java", "kotlin", "kt", "kts", "scala", "cs", "csharp"], java), (["zig"], zig),
            (["yaml", "yml", "toml", "ini", "conf", "dockerfile", "makefile", "make"], data),
            (["json", "jsonc"], json), (["sql"], sql),
            (["c", "h", "cpp", "cc", "cxx", "hpp", "c++", "objc", "m", "mm", "metal", "glsl", "wgsl"], cLang),
        ] as [([String], Language)] {
            for n in names { l[n] = lang }
        }
        return l
    }()

    /// The language for a file name, by extension or well-known name.
    static func language(forFile name: String) -> String {
        let lower = name.lowercased()
        switch lower {
        case "makefile", "gnumakefile": return "makefile"
        case "dockerfile": return "dockerfile"
        case ".zshrc", ".bashrc", ".zprofile", ".bash_profile", ".profile", ".zshenv": return "sh"
        default: break
        }
        return (lower as NSString).pathExtension
    }

    static func html(_ code: String, language: String) -> String {
        guard let lang = languages[language.lowercased()] else { return MarkdownRenderer.escape(code) }
        let chars = Array(code)
        var out = ""
        out.reserveCapacity(code.count * 2)
        var i = 0
        func span(_ cls: String, _ text: String) {
            out += "<span class=\"hl-\(cls)\">\(MarkdownRenderer.escape(text))</span>"
        }
        func startsWith(_ s: String, at j: Int) -> Bool {
            let sc = Array(s)
            guard j + sc.count <= chars.count else { return false }
            for k in 0..<sc.count where chars[j + k] != sc[k] { return false }
            return true
        }
        while i < chars.count {
            let ch = chars[i]
            // Comments.
            if let lc = lang.lineComments.first(where: { startsWith($0, at: i) }),
               lc != "#" || i == 0 || chars[i - 1].isWhitespace || chars[i - 1] == ";" {
                var j = i
                while j < chars.count, chars[j] != "\n" { j += 1 }
                span("c", String(chars[i..<j]))
                i = j
                continue
            }
            if let (open, close) = lang.blockComment, startsWith(open, at: i) {
                var j = i + open.count
                while j < chars.count, !startsWith(close, at: j) { j += 1 }
                j = min(chars.count, j + close.count)
                span("c", String(chars[i..<j]))
                i = j
                continue
            }
            // Strings.
            if let triple = lang.multilineStrings.first(where: { startsWith($0, at: i) }) {
                var j = i + triple.count
                while j < chars.count, !startsWith(triple, at: j) { j += chars[j] == "\\" ? 2 : 1 }
                j = min(chars.count, j + triple.count)
                span("s", String(chars[i..<j]))
                i = j
                continue
            }
            if lang.strings.contains(ch), !(ch == "'" && language == "rust" && i + 2 < chars.count && chars[i + 2] != "'") {
                var j = i + 1
                while j < chars.count, chars[j] != ch {
                    if chars[j] == "\\" { j += 2; continue }
                    if chars[j] == "\n", ch != "`" { break }
                    j += 1
                }
                j = min(chars.count, j + 1)
                span("s", String(chars[i..<j]))
                i = j
                continue
            }
            // Numbers.
            if ch.isNumber, i == 0 || !(chars[i - 1].isLetter || chars[i - 1] == "_") {
                var j = i
                while j < chars.count, chars[j].isHexDigit || "xXoObB_.eE".contains(chars[j]) { j += 1 }
                span("n", String(chars[i..<j]))
                i = j
                continue
            }
            // Words: keywords, types, calls.
            if ch.isLetter || ch == "_" || ch == "@" || (ch == "$" && language.hasPrefix("sh")) {
                var j = i + 1
                while j < chars.count, chars[j].isLetter || chars[j].isNumber || chars[j] == "_" || chars[j] == "?" && language == "ruby" { j += 1 }
                let word = String(chars[i..<j])
                if lang.keywords.contains(word) {
                    span("k", word)
                } else if ch == "$" {
                    span("v", word)
                } else if j < chars.count, chars[j] == "(" {
                    span("f", word)
                } else if ch.isUppercase, word.count > 1 {
                    span("t", word)
                } else {
                    out += MarkdownRenderer.escape(word)
                }
                i = j
                continue
            }
            out += MarkdownRenderer.escape(String(ch))
            i += 1
        }
        return out
    }
}
