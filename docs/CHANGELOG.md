# Changelog

## Unreleased

- Every setting from the command palette: besides the pickers, each other key of the config (scrollback, quick terminal, notifications, Web Access…) is listed in the Settings chip and found by its name; Return lets you type its value, saying as you type what line it writes or why the value doesn't fit, with the key's help under it. Empty goes back to the default.
- Codex shows working on its tab while a turn runs: Codex's notify says when a turn ends, not when it starts, so Return in its pane says working until the turn ends, Codex asks for approval, or its output stays quiet for 5 s. Checked with a stand-in named codex, not Codex itself.
- A closed split pane no longer lives on (its terminal, its scrollback) until the next split changes: the animation that closed it kept it. Memory checked with `heap` after 20 rounds of tabs, splits and documents opened and closed: what stays is the window's own, about 70 MB; `leaks` finds nothing of Libertty's.
- The Theme Editor's name fields no longer move to the right the first time it opens; the bright colors are labeled by color under their heading (Bright Magenta was cut short), VoiceOver still says Bright. A setting's help in the palette reads as a paragraph.

## 0.3.9

> Fixes found by running everything on a clean machine: a captured page with its colors, bash naming the folder at once, Linux hosts' liberttyd up to date.

- `libertty +capture --html` wrote a page whose palette colors (a prompt's red, a program's blues) were CSS variables the page never defined, so they showed in no color; the page defines them now.
- bash: after `cd proj && vim`, the tab and the pane's folder named the old folder until the next prompt; bash's integration now says the folder before each command, as zsh's does.
- The liberttyd that Libertty installs on a Linux host is current again. The one shipped since 0.3.0 could no longer be built from the sources (it needed Foundation pieces Linux's lean build lacks): it was an old build, without keeping windows' layouts on the host. It's built by CI now, from the commit's own sources.
- Fonts in unbundled runs (tests, `swift run`) come from where the checkout keeps them.
- Inside, for whoever builds Libertty: the window controller in nine files by what each does; the probes and benches out of release builds (a release asked for one stops, rather than opening a window that could take over your sessions); the app as a library with unit tests (`swift test`); `tests/run.sh` four checks at a time, each with a liberttyd of its own, in about 4 minutes instead of 10, its UI expectations patient on a loaded machine; CI for the Mac and for Linux liberttyd; `scripts/release.sh` refusing a Linux liberttyd that isn't the commit's and running the tests first; `docs/DEVELOPMENT.md`.

## 0.3.8

> Settings from the command palette, tried out live; a Theme Editor; panes moved by dragging; compact and glass panes, a theme accent and colored tab icons; minimum contrast and line height; Codex in agent setup; Web Access over Tailscale.

- `minimum-contrast` (as in Ghostty): text that reads worse against its background than this WCAG ratio is drawn white or black; dark-gray output on a dark theme, or a program's colors that clash with the theme's, stay readable. Box drawing, blocks and powerline glyphs keep their colors.
- `adjust-cell-height` (as in Ghostty; Rex's line height): taller or shorter rows, in pixels (`2`) or a percentage (`20%`), the text centered in them; box drawing and powerline glyphs follow the cell.
- Settings from the command palette (Rex's Change Terminal Font…, Change Cursor Style…): Change Theme, Terminal Font (each listed in its own face), Font Size, Line Height, Minimum Text Contrast, Cursor Style and Blink, Padding Color, Background Opacity, Unfocused Pane Fade, Option Key Behavior, Tab Style and Pane Headers. Each choice is tried out in every window as it's selected (the window isn't dimmed meanwhile); Return writes it to the config (that one line), Esc puts it back. The palette's Themes chip previews the same way, starting at the theme in use. A Settings chip lists them; a search finds them.
- Libertty ▸ Theme Editor… (Rex's custom themes; also `open_theme_editor` and the palette): start from any theme, change its background, text, cursor, selection and sixteen colors in color wells, each change showing in every window at once, with every color's contrast against the background; Save and Use writes it to `themes/` in Ghostty's format and makes it the theme (only this appearance's side of `light:…,dark:…`), offering to take out config colors that would cover it. Imports Ghostty theme files and iTerm2's `.itermcolors`; deletes themes of your own (to the Trash).
- `palette-generate` and `palette-harmonious` (as in Ghostty): colors 16–255 made from the theme's own, the cube blended in CIELAB between the background, the six base hues and the foreground and the grays running from background to foreground, so programs using the 256 colors match the theme. The Theme Editor shows the result.
- Panes move by dragging: the grip beside a split pane's × (on hover), or its header. Over another pane of the split, the half it would take lights up — beside that pane on the side the pointer is nearest, or in its middle, trading places with it; dropped outside the window, a terminal gets a window of its own; Esc lets go. Programs keep running throughout.
- Split Best Fit (Ghostty's `new_split:auto`, Rex's Split Pane Best Fit): beside a wide pane, below a tall one. File menu and palette.
- `split-autobalance` (Rex's Autobalance splits): after every split, close and move the panes even out, animated — three side by side get a third each. Also in the palette's settings.
- `pane-style = compact` (Rex's Compact Pane Style): the panes meet with a hairline of the frame between them, square, out to the window's edges; `comfortable` (default) keeps the cards.
- `pane-glass` (Rex's glass panes): the desktop shows through the terminals, blurred, while the frame around them (toolbar, sidebar, gaps) stays solid; the frame's holes follow splits, zoom and their animations.
- `accent-color` (Rex's Use theme accent): `system` (default), `theme` (the theme's cursor color when it's a color, else its blue) or any `#rrggbb`, for the focused pane's line, the palette's and sidebar's marks, progress rings and the drag's lit area.
- `tab-icon-color` (Rex's Use color for tab icons): each program's glyph on the tabs in its color (Claude orange, Vim green, SSH cyan…); off by default, as before.
- All four, and Autobalance Splits, are in the palette's settings too, tried out live.
- `libertty +swap-pane [ID] OTHER`, `+resize-pane [ID] --right|--left|--down|--up POINTS | --equalize` and `+move-pane [ID] --beside OTHER [--down…]` (Rex's `swap`, `resize`, `move`): a split rearranged from the command line by session ID, refusing with why (another split, the same pane, a parked one).
- Go to Directory's ⌥↵ (and the sidebar's cd Here): go there in the focused pane, at its prompt — the line there cleared first; with a program running in the pane, a new tab opens there instead of typing into the program. The palette's footer says so in Folders.
- Codex in `libertty +agent-setup` (`--agent codex|claude|all`, `--codex-dir`; Codex by default when `~/.codex` is there): its `config.toml` gets a `notify` running `libertty +agent-hook codex notify`, so the tab says when Codex is done (with its last message) or waits for approval, and the libertty skill goes to `skills/`. A `notify` of someone else's is left alone (Codex runs only one) with a note on how to add Libertty's; `--remove` gives the file back as it was. Codex says nothing as a turn starts, so its tab shows done and waiting, not working. Not tried with a real Codex here (none installed): the hook's checked as the line runs it.
- Web Access over Tailscale (`web-access = tailscale`, the panel's My tailnet; Rex's Serve over Tailscale): Libertty listens on this Mac only and `tailscale serve` hands the port to your tailnet over HTTPS, at the Mac's tailnet name (`https://mac.tail….ts.net:7682/#…`); devices in the tailnet open it with the link's secret, nothing listens on the local network, and turning it off lets go of the port. Tailscale missing or signed out is said in the panel. Checked with a stand-in for Tailscale's command line (none installed here), not a real tailnet.
- Web Access switching between This Mac only and My tailnet keeps its listener; a port still held a moment by the listener just closed is bound again shortly rather than failing.
- `tests/screen.sh` (`Libertty --screen-probe`): an on-screen check of what the window server shows, which `--ui-probe`'s off-screen windows can't see. A real window shows a test pattern in its terminal while ScreenCaptureKit records the display there, this process's windows only, frame by frame through: the window hidden and brought back, the app hidden and shown, another app's window in front and gone (Stage Manager's strip), the sidebar folded, a resize, miniaturizing, and a second window opening on the session. A square drawn by AppKit beside the terminal is the ruler: a frame whose terminal isn't at the ruler's scale fails, and is saved; the whole window drawn smaller (the strip, the genie) isn't judged. It takes the screen for about 40 s, so it's run by hand, away from the Mac, and skips without Screen Recording permission or with another app kept in front. On this Mac it hasn't reproduced the squeeze 0.3.7 fixed, even with that fix taken out: a guard for the cases it records, not proof about that one.
- `tests/linux.sh`: liberttyd on a real Linux — Docker containers (aarch64 and x86_64) as the host, `tests/fixtures/docker-ssh` standing in for ssh — through the remote probe: install, a session, the link dropped and back, reattaching, the login shell's integration. With bash and with fish (whose integration hadn't run anywhere before): both work. Found: the Linux liberttyd the bundle ships (built 2026-10-16) is older than the Mac side and doesn't keep layouts on the host (Connect to Host doesn't bring back windows from there); it needs building again with the swift.org toolchain and static Linux SDK.
- The config is read again when it's emptied by truncation (`: > config`); it used to be missed until the next write.
- ⌘-clicking a program's link to a file that would run (an app, an installer, a `.command`, any executable) asks first, showing its path; documents, source files and folders open as before. A link's text needn't say where it goes.

## 0.3.7

> The terminal's text no longer shows squeezed for a moment when a window comes back (Stage Manager, the Dock, launching).

- Fixed, this time where the window server is concerned too: a window brought back (Stage Manager, the Dock, launching) showed the terminal's last frame squeezed (to about 90% wide and 70% tall) until the next frame. The terminal's drawable was larger than the view (it grew in 256-pixel steps), and there the window server maps the contents onto the view whatever the layer's gravity says. The drawable is the view's size now, pixel for pixel (as Ghostty's), so mapped onto the view it shows as it is. Picture in Picture and the floating card, which show it scaled, keep the pane's true shape as well.

## 0.3.6

> The terminal's text no longer shows squeezed for a moment (after Shift+Tab, the sidebar's button and others): fixed at its cause.

- Fixed, at its cause: the terminal's text still showed squeezed (to about 90% wide and 80% tall) for a moment, after Shift+Tab among others. The terminal's layer is AppKit's, and AppKit sets its contents' gravity from the view's placement at times of its own; the default stretches the contents to the view, and the terminal's drawable is larger than the view (it grows in 256-pixel steps). The view's placement is top-left now, which AppKit turns into the gravity the terminal already used, and each frame checks the gravity before it's drawn. 0.3.5 only took away one of the times it happened (the sidebar's button).

## 0.3.5

> Showing or hiding the sidebar no longer shrinks the terminal's text for a moment, and new windows appear without a zoom.

- Fixed: showing or hiding the sidebar or the inspector with its button showed the terminal's text shrunk to about 90% for up to half a second, then back: the terminal drew two frames at the sizes it passed through while the window took the column's width, and the last of them showed scaled until the next frame (the cursor's next blink). It draws none now; the frame on screen, its own size's, stays.
- A window appears as it is, without AppKit's opening zoom: drawn at about 98% and growing to full size over 0.4 s, it made the terminal's text seem to change size each time a window opened (a screenshot, taken after, showed it as it was).

## 0.3.4

> Bug fixes throughout: background tabs no longer take the keyboard from the find bar, Redo after Undo Close no longer crashes, Korean and Japanese input keeps every character, Chinese folder names and links work, the cursor covers a whole Chinese character, Ctrl keys work on AZERTY, QWERTZ and Dvorak, and focus reporting and colored, curly underlines are supported.

- Fixed: a tab changing in the background (its title, its program's state, output) took the keyboard out of the find bar or the tab filter and gave it to the terminal, closed the tab overview, and scrolled the sidebar's tabs back to the selected one; rows also lost their hover and their spinners restarted. The sidebar now updates only the rows that changed and never selects a tab again by itself.
- Fixed: Redo after Undo Close (⇧⌘Z) crashed Libertty.
- Fixed: Korean, and Japanese typed on after a conversion, lost text: a key that finished one character and began the next sent only the new one.
- Fixed: holding a key (vim's hjkl) offered accents instead of repeating it.
- Fixed: two sibling panes ending at once (a broadcast `exit`) left a blank pane that couldn't be clicked, and kept their tab open.
- Fixed: Shift-dragging a selection in a program that uses the mouse (tmux, vim) gave the rest of the drag to the program when Shift was let go before the button.
- Fixed: while a pane was zoomed, moving to the pane beside it did nothing; Undo put a closed zoomed pane back on the wrong side.
- Fixed: the command palette in the Quick Terminal made it slide away; clicking a section heading in the palette ran the item hovered last; a host's window listed this Mac's sessions, and Go to Directory there showed nothing.
- Fixed: clicking a Picture in Picture window, or a notification, of a Quick Terminal pane did nothing.
- Fixed: in rendered Markdown, a link to a heading (a table of contents) opened the folder in Finder instead of scrolling to it.
- Fixed: vim's `:wq` in the editor asked to save changes it had just saved.
- Fixed: the editor stripped a UTF-8 file's byte-order mark on saving, and wouldn't edit a symlinked file (dotfiles kept elsewhere).
- Fixed: the system's light/dark switching (or a theme change) reloaded every web page and PDF, losing what was typed and where they were.
- Fixed: a document reloading as its file changed jumped to the top when the file was briefly gone or written in pieces.
- Fixed: in a document, the find bar's arrows searched the wrong way.
- Fixed: Enclosing Folder in the file tree went back at the next update; the tree lost its selection and scroll after each command; the tab's context menu could act on another tab if one closed while it was open.
- Fixed: Install and Restart left "Installing…" up for good when the quit was cancelled; Check for Updates did nothing while an update downloaded.
- Fixed: Close All Windows or Quit and End Sessions hung when saving a document needed to ask something (the file changed on disk, or couldn't be written).
- Fixed: in a folder whose name has Chinese (or other non-ASCII) text and a space, or a `#`, `?` or `%`, Libertty lost track of the shell's folder: new tabs and splits opened in the folder before.
- Fixed: ⌘K at a prompt left the last screenful in the scrollback.
- Fixed: ⌘-clicking a link followed by Chinese punctuation (`详见 https://…，然后`) took the punctuation and the text after it into the link.
- Fixed: the block cursor on a Chinese (wide) character covered only half of it and hid the other half; it covers both cells now. VoiceOver's caret on a line with wide characters was in the wrong place.
- Fixed: Ctrl+letter on AZERTY, QWERTZ and Dvorak sent the US key's control code (AZERTY's Ctrl+A sent ^Q, Ctrl+W suspended vim); characters typed with Option (German `@`, `{`) went out as Alt+key to programs using the kitty keyboard protocol (fish, Neovim, Helix); `macos-option-as-alt = right` never worked; modifier keys alone never reached programs that ask for them.
- Focus reporting (mode 1004): programs that ask for it (tmux's `focus-events`, editors reloading files) hear when their pane gains or loses the keyboard.
- Underlines in their own color (SGR 58) and curly, dotted and dashed ones, as Neovim's diagnostics draw them; they were all straight and in the text's color.
- Fixed: a screen of many distinct characters at a large size (Chinese at 72 pt) drew some of them wrong: the glyph cache grows once before it starts over, and a frame that fills it is drawn again.
- Fixed: the find bar's highlights stayed on a pane after focus moved to another pane of the split; its count stopped short after a flood of output.
- Fixed: Copy Output of Last Command after a command that printed nothing (`cd`) copied the output of the one before.
- Fixed: text that may run commands, dropped on a terminal, went nowhere; it asks, as pasting does.
- Fixed: the browser block replaced the page with a file a link said to download (`<a download>`, an export) instead of saving it to Downloads.
- Fixed: a removed `-- comment` line (SQL, Lua, Haskell) in a diff started a phantom file and miscounted the rest; a `.patch` from `git format-patch` showed its signature as a change.
- Fixed: the SQLite block turned text typed into a TEXT column into a number (`02139` became `2139`); a batch that failed part-way left its transaction open, and the next action committed its changes; rows with very large rowids couldn't be edited.
- Fixed: the Git block's Stage, Unstage and Discard Hunk failed with `diff.noprefix` set; Show Changes could hang in a repository whose line-ending warnings filled git's error output.
- Fixed: Reload, or turning a plugin off and on, while it was stuck in a loop started another thread pinned at full speed each time.
- Fixed: in rendered Markdown, a link to a local program or script (`install.command`, an app) ran it in one click; it asks first now, and a folder shows in Finder. Two headings could get the same anchor; a UTF-8 file's byte-order mark was dropped by the board, notebook and canvas; source shown without the editor in a CRLF file colored everything after the first comment.
- Fixed: the Quick Terminal's hotkey brought another Libertty window forward with it and couldn't put the Quick Terminal away; menu commands could act on a window floating on top instead of the one in front; ⌘N stacked new windows exactly on top of each other; a folder opened from Finder (or Services, `--cwd`) was ignored with `working-directory = home`, and so were restored panes' folders; a folder opened as Libertty launched ended up behind the restored windows; the Dock icon opened a new window when every window was minimized; notifications from before a relaunch weren't cleared when their pane was looked at.
- The floating pane card and Picture in Picture stay within half the height of a tall, narrow pane's split or screen; a tab with more than four programs keeps the focused one's glyph; the overlay scroller, pane × buttons, find bar, palette and status rings follow the window's light or dark.

## 0.3.3

> Showing or hiding the sidebar or the inspector leaves the terminal exactly as it was: the window grows or shrinks around it, and nothing in it reflows or redraws.

- Showing or hiding the sidebar or the inspector leaves the terminal exactly as it was: the window grows or shrinks by the column's width on its side, at once, so the terminal keeps its size and its place on the screen, nothing in it reflows and the shell doesn't redraw its prompt. Where the window can't grow — full screen, a window filling its screen, the Quick Terminal — the column slides in over the terminal's width as before. UI tests' windows stay off every screen (they could land on a laptop's built-in display).

## 0.3.2

> Install and Restart in the update dialog installs again (from 0.3.1 or earlier, update this once with `brew upgrade --cask libertty` or `libertty +update`); and a slow first start of the session daemon after an install no longer leaves that run's shells outside it.

- Fixed: when liberttyd's first run took long (macOS checks a newly installed binary; seen at over half a minute, after `brew install`), Libertty gave up after 10 s and ran every shell of that run itself, so none outlived quitting; liberttyd, coming up later with no session, then exited. Libertty now keeps waiting for it in the background and starts it again for a new pane that finds it gone; panes from then on persist. Quitting asks first when panes liberttyd doesn't hold still run programs (before, with persistence on, it ended them without asking).
- Fixed: Check for Updates found the new version, but Install and Restart did nothing — the dialog was shown while the check still counted as under way, and an install won't start while anything else is. The daily check's dialog (`auto-update = check`) had the same fault; `libertty +update` and `auto-update = download` weren't affected. tests/update-test.sh now installs through the dialog too.

## 0.3.1

> The sidebar slides without the terminal jerking; config changes reach the panes again (files saved in place, theme files, light and dark); Reload Configuration also resets the text size; settings kept under Lumen's name move to Libertty's; and Check for Updates lists what's new.

- Settings and window layouts kept under Lumen's name (`~/.config/lumen`, Application Support/Lumen) move to Libertty's the first time Libertty starts; they used to be read where they were for good.
- Fixed: the sidebar and inspector sliding in or out made the terminal jerk: its grid changed at nearly every frame of the slide, redrawing everything each time and having the shell redraw its prompt mid-way. The grid now stays as it is through the slide and takes the new width once, at its end.
- `libertty +list-panes`: every pane of the running Libertty with its session, text size and font, cell size, scale and grid — what to look at when text seems to change size.
- Fixed: a config saved in place (VS Code, nano, `>>`) wasn't reloaded until the file was replaced; changes to a theme's file never reached the panes, not even with Reload Configuration; and with `theme = light:A,dark:B` the panes didn't follow the system's light/dark switch.
- Reload Configuration also takes every pane back to `font-size`: ⌘+/⌘- zoom, which new tabs, splits and windows inherit and windows keep when they come back, ends there (⌘0 resets one pane).
- Check for Updates shows what's new in a box of its own that scrolls — the release's notes as text, with bullets, code, bold and links — and a link to the release's page, instead of the raw notes stretching the dialog. The update feed carries a short summary for older versions' dialogs.
- Homebrew: `brew install --cask ziwangprincex/libertty/libertty` (Apple silicon). The cask clears the quarantine flag, so Libertty opens without "Open Anyway", and `zap` removes everything Libertty keeps; Libertty still updates itself.

## 0.3.0

> Move panes and tabs anywhere, coding agents' state on their tabs, Go to Directory, a sidebar that shows only the tabs that are working or waiting for you, focus that follows the mouse, a program's background out to its pane's edges, Ghostty's settings imported, and `+split`, `+send-key` and `+status` for scripts. Programs now ask for the camera, the microphone and other access in the name of Libertty Sessions.

- `window-padding-color` (Ghostty's): `extend` carries the colors of the cells at the grid's edges out to the pane's edges, so a program's background fills its card (after Rex's "Match program backgrounds"); not above or below a prompt, a row with cells in the default background (reverse video too) or powerline glyphs, except in full-screen programs; scrolled part of a row, the rows cut at the edges are carried. `extend-always` carries every edge; `background`, the default, keeps the padding as it was. Snapshots take `--set KEY=VALUE` and `--pixels X,Y;…`.
- The sidebar filters tabs by activity (after Rex): the button at the end of its filter field, the palette or `show_tabs:working|waiting|attention|all` lists only the tabs whose programs are working, waiting for you, or finished or failed; rows come and go as their states change, the name filter narrows further, and the count says how many show ("1/4").
- Go to Directory (File menu, the palette, `go_to_directory`): the palette's new Folders lists where panes are and where this Mac's shells have been lately; a path typed with / or ~ lists the folders it leads to; Return opens a new tab there (after Rex).
- `focus-follows-mouse` (Ghostty's): the pane under the pointer gets the keyboard, from one terminal pane to another, without a click (after Rex).
- `libertty +import-ghostty [--from FILE] [--dry-run] [--yes]` brings Ghostty's settings over (after Rex's "Migrate from Ghostty"): its config files and what they include, the settings Libertty knows and doesn't set itself (Libertty's own stay), the first font-family. It lists what it adds, what it leaves out and why, asks first and keeps the old config.
- `libertty +send-key ID KEY...` presses keys in a session — `ctrl+c`, `enter`, `escape`, `up`, `shift+tab`, `alt+f` — encoded by liberttyd for the program's modes (cursor keys, the kitty keyboard protocol), as typing them would (after Rex's `send-key`). `+send` still types text as-is.
- A program reading a password (sudo, ssh, `read -s`: its terminal takes a line without echoing it) shows as waiting for you — the tab's mark, a notification while you're elsewhere, the Dock badge — as a program reporting it (OSC 7501) would (after Rex's "Waiting for a password"). liberttyd looks a moment after output or typing; `+events` reports `input-mode`.
- A program that fails at once (non-zero within `abnormal-command-exit-runtime`, 250 ms by default, as in Ghostty) leaves its pane open with what it said and its exit status; a key closes it (after Rex). `wait-after-command = true` (Ghostty's) keeps every pane whose program ends; `libertty +split --keep-open` keeps one.
- `libertty +split [ID] [--right|--left|--down|--up] [--ratio PERCENT] [--cwd DIR] [--no-focus] [-e COMMAND]`: a pane beside the one showing session ID (this pane's by default), as ⌘D makes it; it prints the new session's ID. `libertty +move-pane [ID] --new-tab | --tab N | --new-window` moves one. Both work with `--host`. The libertty skill tells agents about them (a dev server beside the agent).
- Move a pane (after Rex): to a tab of its own, into another tab's split (a pane alone in its tab takes the tab along), or to a window of its own; move a tab to a new window. Drag a tab out of every window for a window of its own, or onto another window's tabs to move it there — a window's only tab too, and its window closes. Programs run on through every move. Window menu, palette, context menus and keybind actions.
- Coding agents (after Rex): `libertty +agent-setup` installs Claude Code hooks and a skill (it shows what it changes and asks first; `--remove` undoes it). In Libertty, Claude Code's tab then says whether it's working, waiting for your approval or done — notifications and the Dock badge follow — and Claude is told which pane it runs in and that you may be looking elsewhere, and names its session after its task (`agent-session-names`).
- `libertty +status STATE [--message TEXT] …`: any script reports what it's doing to its terminal (OSC 7501).
- `libertty +rename-session [ID] NAME`: a session's name, kept by liberttyd (through updates too); its tab goes by it, `+list-sessions` and `+events` (`label`) show it.
- Program states (OSC 7501) get your attention the way you choose, state by state (after Rex): `program-status-indicator` (what a tab and the window's subtitle show), `program-status-notify` (notifications and the pane's lit edge), `program-status-dock-badge` (what the Dock badge counts) and `program-status-sound` (e.g. `blocked:Ping,error:Basso`). The defaults keep things as they were.
- Programs in Libertty that ask for the camera, the microphone, contacts and the like now ask in liberttyd's name ("Libertty Sessions"), with a line saying why. They used to ask in the name of whoever started liberttyd — Libertty, gone once it quits, or another terminal — and with no text. Full Disk Access for your sessions is now granted to liberttyd (README ▸ Install). On a host reached over ssh, liberttyd keeps sshd's permissions as before. Programs that were already running when liberttyd was updated keep the old arrangement until they exit.

## 0.2.0

- Workspace blocks (after Tern), all beside the terminal or in tabs, all Libertty's own code or MIT/OFL parts: the **editor** (CodeMirror 6; encodings kept, a changed file never overwritten unseen, `+open --wait` for git's commit message), the **Git client** (stage by file or hunk, commit, history with its graph, branches, fetch/pull/push, stashes; conflicts shown with "use ours / theirs"), the **browser** (an address bar or a search, downloads and the history of a page; `+browser` for scripts), the **task manager** (every process, marked by the terminal it runs in, Quit — only your own, never liberttyd), the **canvas** (Excalidraw: `.excalidraw` files, saved as drawn, exported as PNG or SVG), the **profiler** (`sample` on a terminal's process, shown in speedscope), the **board** (a kanban kept as Markdown in BOARD.md), the **SQLite browser** (read-only until allowed, paging, sorting, queries, cell edits), **plugins** (JavaScript in the config folder's `plugins/`, off until turned on, each in its own context and thread), **notebooks** (`.ipynb` cells in your own `jupyter server`, outputs saved back, the kernel stopped when its tab closes) and **screen** (a display or a window through ScreenCaptureKit).
- A file a block edits opens in it: `.excalidraw`, `BOARD.md` (and `*.board.md`), `.ipynb`, a SQLite database, a profile; ⌘S and closing ask the page for what it hasn't written, and Edit as Text / Edit as JSON opens the file in the editor instead.
- Park a pane (its program keeps running, off the layout, back with Unpark), Float Pane (a pane as a card in the window's corner, draggable, expanded or put away), and named workspaces per window (⌘⇧1…9, the palette, the sidebar).
- The palette's commands act on the window they were opened over, even with a document in front.
- `jupyter =` and `new_canvas` / `open_profiler` / `open_board` / `open_plugins` / `open_screen` keybinds and menu items.

- The window follows Tern's design: one surface (the toolbar, sidebar and gaps share the frame's color, panes are rounded cards with a 6 pt gap, the focused split has an accent line along its top), Geist for the interface text, a slimmer toolbar, a tab filter at the sidebar's foot, and a command palette with scope chips (All / Panes / Commands / Sessions / Themes — Tab cycles them), sections, icon tiles, keycaps, a footer of hints, and the window dimmed behind it.
- `pane-headers = never | split | always`: a header on each pane with its program (or folder), where it is, its grid size, and — on the focused pane — buttons to float, zoom and close it. A click focuses the pane, a double-click zooms it.
- `tab-bar = sidebar | top`: with `top` the tabs run along the window's top (a folder shows by its last part), the selected one on a faint card; click, double-click to rename in place, drag to reorder, middle-click or × to close, right-click for the menu. The sidebar then keeps the files.
- `libertty +wait ID --until exit|prompt|idle=MS --timeout S` (124 on timeout), `+capture --ansi|--html`, and `+events [--filter KIND,…]` — a stream of session-started, prompt, command-started, command-finished, directory and session-ended events as JSON lines (after Tern).
- Fixed: on a Mac without the Command Line Tools, Libertty asked to install them ("requires Xcode") at launch and at every prompt: the file tree's Git marks ran /usr/bin/git, which is only Apple's stub there. Libertty now runs it only when the developer tools behind it are installed, else another git on the PATH, else none — the Git features then say git isn't installed.
- Fixed: the full test run replaced the build/Libertty.app you were using; it builds its own copy now, and `scripts/bundle.sh` swaps the app in atomically.
- Tabs name themselves by what runs in them and where — "Vim  …/c/proj", "SSH  devbox" (GoRex). A title a shell sets at its prompt ("zsh", "~/src", "me@mac: ~/src") gives way to the folder; a program's own title ("main.rs (~/src) - NVIM") is kept.
- Go to Pane (⌘P): type a program, a folder or a tab's name to jump to any pane of any window — the Quick Terminal's, document tabs and documents beside terminals included (GoRex). The palette says "No matches" instead of shrinking away, and its commands act on the window it was opened over.
- Rename a tab in place: double-click it in the sidebar, or ⇧⌘R. Return keeps the name, Esc goes back, an empty name returns to the automatic one; other tabs keep updating while you type, and a tab opening or the sidebar folding away keeps what you typed (GoRex; Finder's way). The tab's context menu adds Reset Name, Duplicate, Move Up/Down and Close Other Tabs.
- Split panes show a name tag on hover: what runs there, and where. Clicks on it reach the pane.
- Restart Shell in Pane (File menu, palette): a fresh shell in the same place and folder. If it can't start, the old one stays.
- Split dividers show a grip under the pointer.
- liberttyd keeps each Mac's window layout too (GoRex: the server holds the layout), so windows come back even if the layout file is lost. Connect to Host brings back the windows that host's sessions were last shown in — from this Mac or another — and any session there that no window shows, as a tab; a session another window shows isn't opened twice, and a Mac's own windows never go to another (not with `window-save-state = never`). Each pane's text size comes back with it.
- Fixed: ⌘T opened the new tab in your home folder instead of the folder of the pane you were in.
- Fixed: tabs of a host's windows were all named "Libertty": the folder a host's shell reports is that host's, and it was checked against this Mac's disk. Host panes now know their folder — for their names, for new tabs and splits there, and for Restart.
- Fixed: a host session closed while its link was still being made could leave its shell running on the host.
- Rebuilding the app (`scripts/bundle.sh`) swaps the new bundle in whole, in one step: a Libertty running from it never finds its fonts, terminfo or shell integration half there. The test suite builds a bundle of its own and leaves `build/Libertty.app` alone.
- A pane whose link to this Mac's liberttyd dropped says so while it reconnects.
- A window that stops reading — a hung app, a link to a host that stalled — no longer holds anything up. liberttyd used to write each window's output in turn and wait on one that didn't read, for up to 10 s per write, stalling the program, every other window and typing; now each window has its own queue and writer (GoRex's), and one that falls more than 8 MB behind skips ahead: liberttyd sends it the session as it is then instead of the backlog (tmux redraws a client that fell behind the same way). Meanwhile liberttyd answers the program's terminal queries for it, so nothing waits on a window that can't see them (`--slow-client-probe`).
- Fixed: the screen liberttyd repaints after a resize settles (for full-screen programs) was its binary snapshot sent as output, so the window printed it as text; it's VT now, which every window paints.
- Closing a pane — or a pane's program ending — moves the focus only if that pane had it, and then back to the pane you were in before, not to a neighbor (GoRex).
- A tab you're not on shows a small accent dot while its program prints, and a ring when something finished or rang the bell there since you last looked; focusing the pane clears it (GoRex's marks, without their colors). The pane's own activity dot no longer lights for the shell echoing what you type.
- Equalize Splits gives three panes in a row a third each, not 50/25/25; closing a pane behind a zoomed one keeps the zoom.
- The only tab has no × (it would close the window); the ⌘9 hint marks the last tab, which is what ⌘9 selects.
- With Reduce Motion on, the sidebar and inspector appear and go without sliding.
- The Inspector has a Git panel: the branch, staged and unstaged files with stage / unstage / discard, a commit box, the recent commits, and a click on any file for its diff beside the terminal (a new file's against nothing). It works from any folder of the repository, says what git said when it refuses (a commit message stays for another try), and refreshes at each prompt (after ELYTerminal, through the git command line, without taking git's index lock).
- Each tab shows what its panes are running — a glyph per pane, the focused one in front (Rex's stacked tiles). Behind a runtime or a wrapper the program is found by what it started or runs, so Claude Code shows as itself — tclaude, npx and `node …/claude-code/cli.js` alike — not as Node; a pane sitting at its prompt shows nothing.
- A pane whose program is printing shows a dot in its corner, which fades once the program has been quiet for a moment (GoRex's).
- The toolbar carries this Mac's name; clicking it shows the model, chip, memory, system and which liberttyd the window talks to.
- Fixed: the Inspector never listed a pane's processes or the ports they listen on (unless the shell had four children or more): macOS's child-process call counts pids, and they were read as bytes.
- Fixed: the file tree lost its Git colors on a path through a symlink (/tmp, a project folder linked from elsewhere) and in any folder below the repository's root.
- Fixed: resizing a window whose session runs a full-screen program (vim, lazygit, htop) through liberttyd could leave its view misaligned: the program's in-flight output, drawn for the old size, is parsed by the window at the new one and the copies drift, and such programs repaint only what they think changed. Once a resize settles, liberttyd now repaints every window from its own copy (GoRex's fix; shells reflow alike and are left alone).
- The sidebar's file tree colors changed files by Git's marks (modified orange, new green, deleted red) and refreshes at each prompt, so a command that changed files anywhere shows up right away (after ELYTerminal).
- Fixed: keys typed with only Shift (@, #, %, capitals…) reached kitty-protocol programs (Claude Code among them) as CSI u escape codes carrying the unshifted key, so tclaude typed "2" for Shift+2. Per the kitty keyboard protocol, shift+key stays plain text outside report-all mode; that's what Libertty sends now (`--kitty-key-probe`).
- Sessions live in liberttyd: quitting, a crash or an update leaves programs running, and the next launch restores windows, tabs, splits, screens and scrollback. `libertty +list-sessions / +new-session / +send / +capture / +attach / +wait / +focus / +kill-session`.
- ⌘-click links and `file:line:col` paths; Markdown and source files open in a tab or beside the terminal.
- Command palette (⌘⇧P), tab overview (⌘⇧\), Quick Terminal, notifications and an inbox, status badges and halos.
- kitty graphics, OSC 52 clipboard, programming ligatures, VoiceOver, selection autoscroll / extend / rectangle.
- TERM=xterm-ghostty with its terminfo; ssh falls back to xterm-256color.
- Scrollback now keeps what `scrollback-limit` says (10 MB by default, compressed when idle).
- Check for Updates, with signed updates.
- Undo Close (⌘Z within `undo-timeout`), an overlay scrollbar, cursor blink, `bell-features`, broadcast input, rich-text copy, Export Text As…, Copy Output of Last Command.
- Remote hosts: File ▸ Connect to Host… (`libertty +connect`), sessions on another machine through your ssh, surviving dropped links and relaunches; `--host` for the session commands.
- Web Access: this Mac's panes in a browser or on a phone, behind a secret link (`web-access`).
- Smooth trackpad scrolling, Picture in Picture, kitty Unicode placeholders and images kept across relaunch, Powerline/branch/braille drawn from the grid.
- Panes for images, PDFs, web pages and diffs (`libertty +diff`).

## 0.1.0

- First build: libghostty-vt, Metal renderer, splits, tabs in a sidebar, Ghostty-style config and keybinds, Markdown documents.
