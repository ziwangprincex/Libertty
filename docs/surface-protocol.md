# Libertty's surface protocol

A program in a Libertty pane can ask for native UI: a card in its output (it
scrolls with the text around it) or a panel over its pane, with buttons,
lists, tables, progress bars, fields and more. Libertty draws it with its
own controls and tells the program what the user clicked, chose or typed.
The sequences are OSC 7502, which other terminals ignore.

Version 1. A reference client is `tools/surface/surface.py` (Python, standard
library only); `libertty +surface` does the same from a shell script
(`tools/surface/demo.sh`).

## Sequences

Every sequence is `ESC ] 7502 ; VERB [; PAYLOAD] BEL` (or ending in `ESC \`).

| Sequence | What it does |
|---|---|
| `7502;q` | Asks whether the terminal draws surfaces. Libertty replies `ESC ] 7502 ; q ; v=1;elements=…;max=262144 BEL`, but only when surfaces are on. A terminal without them replies nothing, so wait half a second at most. |
| `7502;s;{JSON}` | Shows a surface, or replaces the one with the same id. |
| `7502;s;b64:BASE64` | The same, with the JSON base64-encoded. Use this whenever the JSON isn't plain ASCII. |
| `7502;d;ID` | Removes a surface. |
| `7502;c` | Removes every live surface in the pane. |

Read the reply and the events with the terminal in cbreak mode (no echo, no line buffering), as you would for any terminal report.

## A surface

```json
{
  "id": "build",
  "placement": "inline",
  "rows": 6,
  "anchor": "above",
  "title": "Build",
  "elements": [ … ]
}
```

| Key | |
|---|---|
| `id` | Required. Letters, digits, `_`, `.` and `-`, at most 64. |
| `placement` | `inline` (the default) or `overlay`. |
| `rows` | Inline: how many rows the card covers, 1–40 (default 4). Overlay: its height in rows (default 10). |
| `anchor` | Inline only. `above` (the default) covers the `rows` rows just above the cursor: print that many lines first, then send the surface, and your output continues below it. `cursor` covers rows from the cursor's row down; you make room for them yourself. |
| `position` | Overlay only: `top`, `bottom`, `center`, `top-right`, `bottom-right` (the default) or `full`. |
| `cols` | Overlay only: its width in columns (default 60). It's clamped to the pane. |
| `title` | Shown on the card after the program's name. |
| `elements` | The contents, top to bottom, at most 200. |

Sending a surface again with the same id updates it. An inline surface stays where it was first shown. What the user has typed into its fields, and the rows they've picked in its lists and tables, carry over when the element ids match. So a progress update doesn't wipe a half-typed note. A surface can't switch between inline and overlay.

## Elements

Each element has a `type`. An `id` is optional, except on inputs; events and kept state go by it. All text is plain: control characters and bidirectional overrides are removed.

| Type | Keys |
|---|---|
| `text` | `text`; `style`: `title`, `body` (the default), `secondary` or `mono`. |
| `markdown` | `text`, as inline Markdown: emphasis, code and links. There are no images and no HTML. A link opens only with ⌘-click, and only if it's `http`, `https` or `file`. |
| `buttons` | `items`: up to 12 of `{id, label, style, disabled}`, where `style` is `primary`, `default` or `destructive`. |
| `list` | `items`: up to 1000 of `{id, label, detail}`; `select`: `none`, `single` (the default) or `multi`; `height` in rows. |
| `table` | `columns`: up to 12 titles; `rows`: up to 1000, each a list of cells or `{id, cells}`; `select` and `height` as for `list`. |
| `progress` | `value` from 0 to 1, or `null` while it can't be told; `label`. |
| `keyvalue` | `items`: up to 50 `[key, value]` pairs. |
| `input` | `id` (required), `label`, `placeholder`, `value`. A single line. |
| `image` | Either `data`, a base64 PNG, JPEG or GIF of at most 1 MB, or `path`, an absolute path to an image file on the machine running Libertty (at most 10 MB; refused when the program runs on another host). Also `height` in rows and `label` (what VoiceOver reads). |
| `diff` | `text`: a unified diff, shown in monospace with added and removed lines colored. |
| `divider` | A line. |

## Events

Libertty types events into the program's input as `ESC ] 7502 ; e ; b64:BASE64 BEL`, where BASE64 encodes a JSON object:

| `type` | Sent when | Other fields |
|---|---|---|
| `click` | A button is clicked | `item`: the button's id; `element`: the buttons element's id, if it has one |
| `select` | The selection in a list or table changes | `element`, `items`: the ids now selected |
| `activate` | A row is double-clicked | `element`, `item` |
| `submit` | Return is pressed in an input | `element`: the input's id |
| `closed` | The user closes an overlay with its × | — |
| `error` | Something you sent couldn't be shown (only after you've sent `q`) | `message`, and `surface` if known |

Every event except `error` also carries `surface` (the surface's id) and `values` (each input's current text, by id).

## When a surface works

A surface is live from the moment it's shown. While it's live, its controls work and its events are sent. It stops being live when any of these happens:

- The shell shows its next prompt (shell integration, OSC 133), meaning the program ended.
- Another process group takes over the terminal. Libertty can only check this on this Mac.
- The program removes the surface.

After that, an inline surface stays in the output as a record of what was shown, dimmed and with its controls off. An overlay goes away.

Inline surfaces also go away in these cases:

- Anything gets written into the rows they cover.
- They're inside the screen area cleared before a new prompt.
- Their rows drop out of the scrollback.
- The terminal is reset (RIS).

A surface drawn while the program is on the alternate screen is shown only on that screen, and goes away when the program leaves it.

## Limits and safety

- Surfaces can be turned off: `surfaces = false` in the config, or Settings ▸ Terminal ▸ Programs. Then OSC 7502 does nothing, and the query gets no reply.
- Size limits:
  - A sequence may be at most 256 KB. A longer one is dropped.
  - A pane holds at most 16 surfaces. The oldest dimmed one goes first; if all 16 are live, a new one is refused.
  - A pane takes at most 60 commands a second. Past that, commands wait for the next second, in order. A surface's waiting updates collapse into its latest, so a progress bar sent a thousand times a second still ends where it should. Beyond 60 waiting commands, more are dropped.
- What a program shows is treated as untrusted:
  - Nothing runs. There's no web view, no script and no network access.
  - Images come only from the bytes sent, or from an image file on this Mac.
- Every surface shows the program's name ("From python3") and has a border of its own, so nothing it draws can pass for Libertty's own interface. Overlays stay inside their pane and always have Libertty's own × to close them.
- Events go only to the program that drew the surface, while the surface is live. Their contents are base64-encoded, so nothing a user types into a field can be read as a terminal sequence.

## liberttyd, other hosts, other windows

Surfaces belong to the window showing the pane. The sequences pass through liberttyd unchanged: it ignores OSC 7502, so its snapshots aren't affected. They also travel over Connect to Host like any other output.

Some things don't carry over:

- A window that attaches later, or reattaches after liberttyd is replaced or a link comes back, gets the screen without the surfaces. Programs that want them back should send them again, for example on `SIGWINCH`.
- Image `path`s aren't accepted from a program on another host.

## Command lenses

Command lenses are Libertty's own, not part of the protocol. After a command finishes, a lens may read what it printed and offer the results as a list, as a chip on the command's line ("3 errors · Open as List"):

- `git-status`: the files, grouped (staged, not staged, untracked, conflicts). Each opens in Libertty and can be staged or unstaged from the list. "Show in Git" opens the Git block.
- `diagnostics`: errors, warnings and notes in the `path:line:col: error:` style (swift, clang, gcc), tsc's `path(line,col): error TS…`, rustc's `error[E…]` followed by `--> path:line:col`, and go's `path.go:line:col: …`. Each opens at its line.
- `search`: `rg`, `grep -n` and `git grep` matches, flat or under rg's file headings. Each opens at its line.

Lenses need shell integration (OSC 133 with the command line). They don't apply to commands piped into another command, or to panes on another host. Set them with `command-lenses = true | false | git-status,diagnostics,search`.

## Not yet

- Surfaces aren't restored after a reattach (see above).
- Inputs have no secure variant, and there are no checkboxes, sliders or menus.
- Plugins can't add lenses of their own yet.
