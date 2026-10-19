# Libertty Markdown check

A paragraph with **bold**, *italic*, ***both***, ~~struck~~, `inline code`, a [link](https://example.com "Example"),
an autolink <https://ghostty.org>, a bare URL https://github.com/ghostty-org/ghostty, and an
escaped \*star\*. 中文段落：终端渲染测试，emoji 👍🏽 和 snake_case_words stay plain.
Line one with a hard break  
line two.

## Lists

- First item
- Second item with `code`
  - Nested item
  - Another nested
    1. Deep ordered
    2. Still deep
- [ ] Open task
- [x] Done task

3. Starts at three
4. Then four

* Loose item one

* Loose item two

## Code

```swift
// A comment
struct Pane: View {
    let title = "Libertty"   // trailing
    func render(count: Int) -> Bool { count > 42 }
}
```

```bash
export PATH="$HOME/bin:$PATH"  # comment
for f in *.md; do echo "$f"; done
```

    indented code block
    second line

## Quote

> Block quote with **emphasis**
> spanning two lines.
>
> > Nested quote.

## Table

| Terminal | Throughput | Notes |
|:---------|-----------:|:-----:|
| Libertty    | 358 MB/s   | `libghostty-vt` |
| Tern     | 266 MB/s   | Rust |
| Ghostty  | 134 MB/s   | Zig \| Swift |

Setext heading
--------------

---

![missing image](does-not-exist.png)

<details><summary>Raw HTML details</summary>

Hidden content with <kbd>⌘</kbd> + <kbd>K</kbd>.

</details>

[Reference link][ref] and [another].

[ref]: https://example.org "Reference"
[another]: https://example.net
