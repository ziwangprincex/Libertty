<p align="center"><img src="assets/icon/png/libertty-256.png" width="128" alt="Libertty logo"></p>

# Libertty

English | [简体中文](README.zh-CN.md)

Libertty is a terminal emulator for macOS. It uses
[libghostty-vt](https://github.com/ghostty-org/ghostty) for VT parsing and terminal
state, Swift and AppKit for the application, and its own Metal and CoreText renderer.
Shell sessions run in a separate daemon (`liberttyd`) and continue when the app
quits. Alongside terminals, a window can hold documents and tool panels ("blocks"):
an editor, a Git client, a browser, a task manager and others.

## Status

- Version 0.2.0. macOS 14 or later; the build script produces an Apple silicon (arm64) binary.
- Not notarized by Apple. Updates are verified with an Ed25519 signature instead (see
  [Updates and releases](#updates-and-releases)).
- Published on [GitHub Releases](https://github.com/ziwangprincex/Libertty/releases)
  (DMG and zip). No Homebrew cask yet.
- Known gaps: screen sharing works only on the local Mac (not to a remote host); a
  plugin stuck in an endless loop occupies its own thread until Libertty restarts;
  notebooks do not render interactive widgets (ipywidgets).

## Install

1. Download `Libertty-VERSION.dmg` from the
   [latest release](https://github.com/ziwangprincex/Libertty/releases/latest), open it
   and drag Libertty to Applications.
2. The app is not notarized, so macOS blocks the first launch. Open it once, then choose
   System Settings ▸ Privacy & Security ▸ Open Anyway; or run
   `xattr -dr com.apple.quarantine /Applications/Libertty.app` before opening it.
3. Optional: the `libertty` command is on `PATH` in Libertty's shells. To use it
   elsewhere, link it:
   `ln -s /Applications/Libertty.app/Contents/Resources/bin/libertty ~/.local/bin/libertty`.

Xcode and the Command Line Tools are not required. The Git client, the Git panel and
the file tree's Git marks need a `git`: the one from the Command Line Tools
(`xcode-select --install`) or another installation such as Homebrew's. Without one,
they report that git isn't installed and the rest of Libertty works as usual.

Privacy permissions of the programs in Libertty's sessions (camera, microphone, files
and folders, Full Disk Access) belong to Libertty Sessions, the session daemon, and
macOS asks for them in its name. To give your programs Full Disk Access, add
`/Applications/Libertty.app/Contents/MacOS/liberttyd` under System Settings ▸ Privacy &
Security ▸ Full Disk Access (⌘⇧G in the file dialog accepts the path). Libertty is
ad-hoc signed, so macOS may ask again after an update.

## Features

### Terminal

- Rendering through Metal with a glyph atlas. Box drawing, Powerline and braille
  characters are drawn from the cell grid. Kitty graphics protocol, including tmux's
  Unicode placeholders. Programming ligatures (`font-feature = -calt` disables them).
- `TERM=xterm-ghostty` with the bundled terminfo. `ssh` from Libertty's shells sends
  `TERM=xterm-256color` unless `ssh-env = false`.
- Shell integration for zsh and bash (prompt marks, working directory, command
  duration and exit status).
- OSC 8 hyperlinks, OSC 9 / OSC 777 notifications, OSC 9;4 progress, OSC 52 clipboard
  (reading is off by default) and OSC 7501 program status.
- ⌘-click opens URLs and file paths with line and column (`src/a.swift:42:7`).
- Notifications for long-running commands (`notify-on-command-finish`), a
  notification inbox, and a Dock badge for programs waiting for input.
- Program states (OSC 7501: working, waiting for you, done, failed): which of them
  show on tabs, notify, count in the Dock badge or play a sound is set per state
  (`program-status-indicator`, `-notify`, `-dock-badge`, `-sound`).
- A program reading a password (sudo, `ssh` asking here, `read -s`: a line typed without
  echo) shows as waiting for you, as a program reporting it would. Prompts on another
  machine are seen in a host window (Connect to Host), not through a plain `ssh` session;
  prompts drawn by full-screen programs aren't.

### Windows, tabs and panes

- Tabs in a sidebar or along the top (`tab-bar = sidebar | top`); splits; optional
  pane headers (`pane-headers = never | split | always`).
- Park a pane: remove it from the layout while its program keeps running, and restore
  it later.
- Float a pane: show it as a card in a corner of the window.
- A program that fails at once (non-zero within `abnormal-command-exit-runtime`, 250 ms)
  leaves its pane open with its error; a key closes it. `wait-after-command = true` keeps
  every pane whose program ends; `libertty +split --keep-open` keeps one.
- `focus-follows-mouse = true`: the pane under the pointer gets the keyboard, without a click.
- Move a pane: out of its split into a tab of its own, into another tab's split, or
  into a window of its own; move a tab to a new window. Dragging a tab out of every
  window opens it in a window of its own, and dropping it on another window's tabs moves
  it there (Window menu, command palette, context menus; `move_surface_to_new_tab`,
  `move_surface_to_tab:N`, `move_surface_to_new_window`, `move_tab_to_new_window`).
- Workspaces: named groups of tabs within one window (⌘⇧1…9).
- The sidebar lists only the tabs whose programs are working, waiting for you, or
  finished or failed — the button in its filter field, the palette, `show_tabs:working`.
- Command palette (⌘⇧P), go to pane (⌘P), go to directory (File ▸ Go to Directory…: a new
  tab where a pane is, where shells have been, or in a path typed with / or ~), tab overview (⌘⇧\\), Quick Terminal,
  Picture in Picture, broadcast input, undo for closing a pane, tab or window
  (`undo-timeout`).

### Sessions (liberttyd)

Shells run in `liberttyd`, which Libertty starts on demand. Quitting, a crash or an
update leaves programs running; the next launch restores windows, tabs, splits,
screens and scrollback. Closing a pane or window ends its program; ⌥⌘Q ends all
sessions. A new liberttyd build takes over from a running one without ending
sessions. `session-persistence = false` runs shells inside the app instead.

### Remote hosts

File ▸ Connect to Host… (⇧⌘K, or `libertty +connect HOST`) opens a window whose
panes run on another machine over the system's `ssh` (`~/.ssh/config`, keys, agent,
jump hosts). The host gets its own liberttyd, installed under `~/.libertty` without
root, so programs keep running across disconnects. Supported hosts: macOS (Apple
silicon) and Linux (x86_64, aarch64).

### Web access

`web-access = local | network` serves the Mac's panes to a browser: a pane's screen
and keyboard input through the same key encoder. Every page requires a secret token
from the link. `local` listens on localhost only; `network` uses plain HTTP on the
local network. `web-access-input = false` makes it read-only.

### Documents and blocks

Files and tools open in a tab or as a pane beside the terminal.

| Item | Description |
|---|---|
| Documents | Markdown (rendered), source files with highlighting, images, PDF, web pages, `git diff` output |
| Editor | CodeMirror 6; keeps the file's encoding and line endings; detects external changes; Vim keymap (`editor-keymap = vim`); `libertty +open --wait` can serve as `$EDITOR` |
| Git | Stage, unstage and discard by file or hunk; commit and amend; history with a graph; branches; fetch, pull and push; stashes; conflict resolution with ours / theirs |
| Browser | Address bar with search (`browser-search`), downloads to ~/Downloads, `libertty +browser` commands; reading or scripting pages requires `browser-automation = true` in the config file |
| Tasks | All processes with CPU and memory; processes grouped by the terminal they run in; command line, folder and listening ports; Quit and Force Quit for the user's own processes |
| Canvas | Excalidraw drawings stored as `.excalidraw` files, saved automatically, exported as PNG or SVG |
| Profiler | Records a process with macOS `sample` and shows the result in speedscope |
| Board | Kanban board stored as Markdown (`## Column`, `- [ ] card`) in `BOARD.md` or `*.board.md` |
| SQLite | Tables and views, paged rows, sorting, schema, SQL queries; opens read-only until changes are allowed |
| Plugins | JavaScript files in `~/.config/libertty/plugins/`; disabled until enabled; each runs in its own JavaScriptCore context and thread |
| Notebook | `.ipynb` files; code runs in a kernel of the user's own `jupyter server` (`jupyter =` sets its path); outputs are saved to the file |
| Screen | Shows a display or a window of the Mac via ScreenCaptureKit (requires Screen Recording permission) |

File-backed blocks (canvas, board, notebook) write atomically, refuse to overwrite a
file changed elsewhere without confirmation, and reload external changes when they
have no unsaved edits.

### Coding agents

- `libertty +agent-setup` adds hooks to Claude Code's settings (`$CLAUDE_CONFIG_DIR`, else
  `~/.claude`; `--claude-dir` for another) and a skill describing Libertty's command line. It
  lists the changes and asks first; `--remove` takes them out. In Libertty, a Claude Code
  session then shows on its tab whether it is working, waiting for you (approval) or done,
  is told which pane it runs in, and names its session after its task
  (`agent-session-names = false` turns naming off). Outside Libertty the hooks do nothing.
- `libertty +status STATE` reports a program's state to the terminal from any script (OSC 7501).
- `libertty +rename-session [ID] NAME` names a session; its tab and `+list-sessions` show the name.

## Requirements and build

- macOS 14+, Swift 6 (the Command Line Tools are sufficient), Zig 0.16
  (`brew install zig@0.16`).
- Node.js and npm only to rebuild the bundled web pages; their built output is
  already in the repository.

```sh
git submodule update --init vendor/ghostty   # pinned Ghostty checkout
scripts/build-libghostty-vt.sh   # once, or after updating vendor/ghostty
scripts/bundle.sh                # build/Libertty.app (debug); `scripts/bundle.sh release` for an optimized build
open build/Libertty.app
```

Other build scripts:

| Script | Output |
|---|---|
| `scripts/build-editor.sh` | `vendor/codemirror/` from `frontend/editor/` |
| `scripts/build-canvas.sh` | `blocks/canvas/lib/` from `frontend/canvas/` |
| `scripts/build-speedscope.sh` | `blocks/profile/lib/` (speedscope release build) |
| `scripts/build-linux-liberttyd.sh` | static liberttyd binaries for Linux hosts (requirements in the script's header) |
| `scripts/gen-keymap.py` | `Sources/Libertty/Input/KeyMap.swift` from Ghostty's key table |

## Configuration

The config file is `~/.config/libertty/config` in Ghostty's format (`key = value`,
`keybind = cmd+d=new_split:right`, `theme = light:X,dark:Y`, `config-file = ...`).
Libertty ▸ Settings… (⌘,) opens it; changes apply when the file is saved. Errors are
listed in a Configuration Errors window. Ghostty theme files are accepted, from
`~/.config/libertty/themes` and from an installed Ghostty.app.

```sh
libertty +set theme="Tokyo Night" font-size=14
libertty +get theme
libertty +show-config --changes        # --default, --docs
libertty +validate-config
libertty +import-ghostty [--dry-run]    # Ghostty's settings Libertty knows and doesn't set itself
libertty +list-themes ; libertty +list-fonts ; libertty +list-keybinds ; libertty +list-actions
```

`libertty +set` does not change `browser-automation`; that key is set only by editing
the file.

## Command line

`libertty` is on `PATH` in Libertty's shells. `libertty +help` lists every command.

```sh
libertty +action new_split:right                 # run an action in the running app
libertty +new-window --cwd ~/src -e htop
libertty +open [--split] [--edit] [--wait] FILE[:LINE]
libertty +diff [git diff args]
libertty +browser open URL ; libertty +browser text

libertty +list-sessions [--json]
libertty +new-session --cwd ~/src -e make watch
libertty +capture ID [--scrollback] [--ansi | --html]
libertty +send ID 'make test\n'
libertty +send-key ID ctrl+c          # keys, encoded as the program wants: enter, up, shift+tab…
libertty +wait ID --until exit|prompt|idle=MS [--timeout S]
libertty +events [--filter KIND,...]
libertty +attach ID [--window] ; libertty +kill-session ID
libertty +split [ID] [--down] [--ratio 30] [--no-focus] [-e COMMAND]   # a pane beside session ID's; prints its ID
libertty +move-pane [ID] --new-tab | --tab N | --new-window
```

Session commands accept `--host HOST`. `$LIBERTTY_SESSION` holds the current pane's
session ID.

## Tests and diagnostics

`tests/run.sh [release]` runs the headless test suite against a private liberttyd,
config and data folder; it opens no visible window and does not take focus. It covers
renderer snapshots (written to `build/test-output/`), parsing, config, links,
selection, shell integration, sessions, paste, throughput, and UI scripts for the
window features and every block (`tests/fixtures/*.txt`, run with
`Libertty --ui-probe SCRIPT OUTDIR`). The notebook test is skipped when no
`jupyter server` is available (`LIBERTTY_TEST_JUPYTER` selects one).
`tests/update-test.sh` checks the update path offline.

```sh
# A command's final screen as PNG, without a window
build/Libertty.app/Contents/MacOS/Libertty --snapshot out.png --cols 90 --rows 15 -- sh tests/fixtures/showcase.sh
Libertty --latency-trace [--count N]             # key-to-screen latency
Libertty --resize-trace [--divider] [--splits N] # main-thread time per resize step
Libertty --session-bench FILE [--mb N] [--persist]
Libertty --git-probe                             # which git Libertty runs in this folder
```

Benchmarks against other terminals are in `bench/` (`bench/RESULTS.md`).

## Updates and releases

- Libertty ▸ Check for Updates…, or daily (`auto-update = check | download | off`), or
  `libertty +update [--check]`. An update is a zip whose Ed25519 signature must match
  the public key built into the app (`scripts/update-public-key.txt`). Installing
  replaces the bundle and relaunches; sessions continue in liberttyd.
- `scripts/release.sh VERSION` stages the zip, DMG, `appcast.json` and Homebrew cask in
  `build/release/VERSION` from the matching section of `docs/CHANGELOG.md`;
  `--publish` uploads them to the repository and tap in `scripts/release.conf`. The
  signing key is read from `~/.config/libertty-release/update.key` (or
  `$LIBERTTY_UPDATE_KEY`) and is not part of the repository.

## Project layout

| Path | Contents |
|---|---|
| `Sources/Libertty/` | The app: `App` (entry, CLI, probes), `UI`, `Terminal`, `Renderer`, `Document`, `Blocks`, `Config`, `Remote`, `Web`, `Input`, `Design`, `Util` |
| `Sources/LiberttyCore/` | Shared by app and daemon: PTY reader, wire protocol, daemon server, remote PTY |
| `Sources/liberttyd/` | The session daemon's entry point |
| `Sources/CPty/` | C helpers: `openpty` and spawn, Unix sockets, libproc queries |
| `Sources/CGhosttyVt/` | Module map for the libghostty-vt headers |
| `blocks/` | Block pages (HTML, CSS, JavaScript); `blocks/*/lib/` holds bundled third-party builds |
| `frontend/` | npm sources for the bundled pages (`editor`, `canvas`) |
| `vendor/` | Ghostty (pinned checkout), the built CodeMirror bundle, the Geist font |
| `Resources/` | Files shipped in the app: shell integration, terminfo, remote liberttyd binaries, third-party notices |
| `assets/icon/` | App icon, PNG sizes, favicon, SVG and its generator |
| `scripts/` | Build, bundle and release scripts |
| `tests/` | Test suite and fixtures |
| `bench/` | Throughput and latency benchmarks; older runs in `bench/results-archive/` |
| `docs/` | `CHANGELOG.md`, `roadmap.md` |
| `tools/` | `winshot` (captures one window by process ID) |

## Third-party components

libghostty-vt (MIT), JetBrains Mono with Nerd Fonts symbols (OFL-1.1), Geist
(OFL-1.1), CodeMirror 6 (MIT), Excalidraw and React (MIT; Excalidraw's fonts OFL-1.1
and MIT), speedscope (MIT; Source Code Pro, OFL-1.1). Full notices:
`Resources/THIRD-PARTY-NOTICES.txt`; each bundled build has its own `LICENSES.txt`.
