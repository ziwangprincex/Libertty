# Developing Libertty

How the code is laid out, how it's tested, how a bug gets fixed and how a
release goes out. The README covers building and using it.

## Layout

| Path | What |
|---|---|
| `Sources/LiberttyApp/` | The app, as a library. `TerminalWindowController` is split by responsibility into `TerminalWindowController+*.swift` (tabs, panes, moving, documents, sidebar, sessions, workspaces, window, pane headers). |
| `Sources/LiberttyApp/Probes/` | The UI probe, benches, traces, snapshots and every `--…-probe`: compiled only with `LIBERTTY_PROBES` (debug builds), one probe a file. |
| `Sources/Libertty/` | The executable: `Launch.run()`. |
| `Sources/LiberttyCore/`, `Sources/liberttyd/` | What the app and the daemon share; the daemon. |
| `tests/LiberttyTests/` | Unit tests (swift-testing). |
| `tests/` | The headless suite (`run.sh`), its fixtures, and the checks run by hand. |
| `assets/icons/` | Libertty's feature icons, drawn in the Kubai Icons style: the Settings pages and the palette's tools, in `src/icons.js`. `node assets/icons/scripts/build.mjs` writes `Resources/icons/*.png` (needs Chrome); `node assets/icons/scripts/check.mjs` renders them for review, `index.html` shows them all. The engine (`src/engine.js`, the scripts) is Kubai087's, under `assets/icons/LICENSE`. The app icon is the pixel sprite in `assets/icon/build-app-icon.mjs` (`node assets/icon/build-app-icon.mjs [--preview FILE]` writes its icns, PNGs, SVG and favicon). |

## Tests, from fastest to slowest

| What | Runs | Covers |
|---|---|---|
| `swift test` | well under a second | Pure logic: config keys, colors and palettes, agent setup's file edits, keys and actions, the split tree, the wire protocol. |
| `zsh tests/run.sh` | about 4 minutes | Everything headless: renderer snapshots by pixel, sessions and liberttyd, the CLI, Web Access, and the UI probe's scripts (`tests/fixtures/*.txt`) driving the real app off screen. Checks run 4 at a time (`LIBERTTY_TEST_JOBS`, `LIBERTTY_TEST_UI_JOBS`), each with its own liberttyd, data folder and empty config; the benches run last, alone. A UI probe's expectation is asked again for up to 3 s before it fails (`LIBERTTY_PROBE_PATIENCE`): a loaded machine is slow, not wrong. |
| `tests/screen.sh` | 40 s, takes the screen | What the window server shows (ScreenCaptureKit, this process's windows only): scale changes the off-screen probe can't see. |
| `tests/screen-check.sh` | 30 s, takes the screen | A built app on the real screen, driven from outside (its config, its menus) through Rex's layouts, the Settings window and the Theme Customizer: one contact sheet to look at, and checks (on the stage, inside the screen's visible part, no gap beside the sidebar, every pane its header). Works with Stage Manager. Needs Screen Recording and Accessibility for the terminal. `release.sh` runs it. |
| `tests/linux.sh` | a few minutes, needs Docker | liberttyd on real Linux (aarch64, x86_64; bash and fish) through the remote probe. |
| `tests/update-test.sh` | a few minutes | The updater, offline: a signed update installs, a forged one doesn't. |

CI (`.github/workflows/ci.yml`) runs the unit tests and the suite on a Mac and
builds liberttyd for Linux with Swift's static Linux SDK, starting it on
x86_64 and aarch64 runners; the binaries are the run's artifact. The Mac
job takes libghostty-vt and SwiftPM's `.build` from earlier runs (cached by
Ghostty's commit, Zig's version and Xcode's build): it rebuilds only the
sources whose contents changed since.

## Fixing a bug

1. **Reproduce it as a failing test first**, at the lowest level that shows
   it: a unit test; else a snapshot's pixels (`--snapshot … --pixels`); else
   a UI probe script; else the screen probe or the Linux check. Run it and
   see it fail for the reason the bug report gives.
2. **Fix the cause**, not the one trigger that was seen. Ask what else
   reaches the same state.
3. **See the test pass**, then run `swift test` and `tests/run.sh`.
4. **Commit the test with the fix.** If it couldn't be reproduced, say so in
   the commit message and the changelog, and how the fix was checked instead.

The text-size glitch took 0.3.5, 0.3.6 and 0.3.7: the first two each removed
one trigger (the sidebar's button, AppKit's contents gravity) without a test
that reproduced what the user saw; the cause (a drawable larger than its
view, mapped onto it by the window server) was found from their screen
recording. The screen probe exists since, though it hasn't reproduced that
one on this Mac.

## Never touch the user's Libertty

A Libertty run by hand reaches the user's liberttyd unless it's told
otherwise — and a different build takes over its sessions. Probes and
benches get a private liberttyd by themselves; anything else run from a
build (a preview instance, `build/Libertty.app`) needs all of:

```sh
open -n build/Libertty.app --env LIBERTTY_DAEMON_SOCKET=$DIR/d.sock --env LIBERTTY_DAEMON_LOG=$DIR/d.log \
  --env LIBERTTY_DATA_DIR=$DIR --env LIBERTTY_STATE_FILE=$DIR/windows.json --env XDG_CONFIG_HOME=$DIR/config
```

(the socket and log: its sessions; the data folder and state file: recent
folders, block data and the window layout; the config folder: a copy of the
user's, so settings tried there stay there). A release build stops at a
probe's flag rather than starting the app. If a takeover happens anyway, the
installed liberttyd takes the sessions back:
`/Applications/Libertty.app/Contents/MacOS/liberttyd --takeover`.

## Releasing

1. A `## VERSION` section in `docs/CHANGELOG.md`, its first line a `>` summary.
2. Push; wait for CI's two Linux jobs (`linux-liberttyd`,
   `linux-liberttyd-arm`) to pass on the commit, about five minutes. The mac
   job needn't be done: step 4 runs its unit tests and suite here again.
3. `scripts/fetch-linux-liberttyd.sh` (it takes a run whose Linux jobs
   passed, and checks the binaries were built from this commit's daemon
   sources), and commit `Resources/remote` if it changed (the daemon's
   sources changed since the binaries were built).
4. `scripts/release.sh VERSION`: refuses a Linux liberttyd that isn't this
   commit's, runs the unit tests and the suite, builds, signs and stages,
   then shows the staged app on the real screen (`tests/screen-check.sh`,
   half a minute): **look at `build/release-screens/VERSION/contact.png`**.
   0.4.0 went out checked off screen only, and the screen showed four
   things wrong within the hour.
5. Commit the version (`Libertty VERSION`) and push.
6. `scripts/release.sh VERSION --publish` (no retest: no code changed since
   step 4; it wants step 4's screen check passed), then check the release's
   zip, the feed and the cask agree.
7. By hand, when what changed calls for it: `tests/screen.sh` (rendering,
   windows), `tests/linux.sh` (the daemon, remote hosts), and whatever the
   changelog says was checked only with a stand-in (Codex, Tailscale).
