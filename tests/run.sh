#!/bin/zsh
# Headless checks: nothing opens a window or takes focus.
#   tests/run.sh            # debug build
#   tests/run.sh release
# Writes snapshots to build/test-output/ (look at them after renderer changes)
# and fails on any check that doesn't hold.
set -u
ROOT=${0:A:h:h}
cd $ROOT
CONFIG=${1:-debug}
# The probes are in debug builds; a release run builds them in (apart from
# the release that ships: a scratch path of its own).
BUILD=(-c $CONFIG)
[[ $CONFIG == release ]] && BUILD+=(-Xswiftc -DLIBERTTY_PROBES --scratch-path $ROOT/.build-probes)
# liberttyd embeds its Info.plist at link time, a file SwiftPM doesn't watch.
[[ ! $ROOT/Sources/liberttyd/Info.plist -nt $(swift build $BUILD --show-bin-path)/liberttyd ]] || touch $ROOT/Sources/liberttyd/main.swift
# A failed build must stop here: an old binary wouldn't know the probe flags.
swift build $BUILD > $ROOT/build/test-build.log 2>&1 || { grep -E "error:" $ROOT/build/test-build.log; exit 1; }
BIN=$(swift build $BUILD --show-bin-path)
LIBERTTY=$BIN/Libertty
OUT=$ROOT/build/test-output
mkdir -p $OUT
# A private liberttyd, so tests never touch the user's sessions.
PRIVATE=$(mktemp -d)
export LIBERTTY_DAEMON_SOCKET=$PRIVATE/liberttyd.sock LIBERTTY_DAEMON_LOG=$PRIVATE/liberttyd.log
# What blocks make (drawings, profiles, plugin storage) goes here too.
export LIBERTTY_DATA_DIR=$PRIVATE
failures=0

# The first run of a freshly built binary waits for the system to check it
# (seen: over half a minute). Once, here, so no test pays for it.
mkdir -p $PRIVATE/warm
LIBERTTY_DAEMON_SOCKET=$PRIVATE/warm/d.sock LIBERTTY_DAEMON_LOG=$PRIVATE/warm/d.log $BIN/liberttyd > /dev/null 2>&1 &
warm=$!
for i in {1..600}; do [[ -S $PRIVATE/warm/d.sock ]] && break; sleep 0.1; done
kill $warm 2> /dev/null
wait $warm 2> /dev/null

# Nothing may hang the suite: every command gets two minutes.
limit() { perl -e 'alarm shift; exec @ARGV or die "$ARGV[0]: $!\n"' 120 "$@"; }

check() {  # check NAME COMMAND... : passes if COMMAND succeeds
  local name=$1; shift
  if limit "$@" > $OUT/$name.log 2>&1; then
    echo "ok    $name"
  else
    echo "FAIL  $name (see $OUT/$name.log)"
    (( failures++ ))
  fi
}

expect() {  # expect NAME PATTERN COMMAND... : passes if the output matches PATTERN
  local name=$1 pattern=$2; shift 2
  limit "$@" > $OUT/$name.log 2>&1
  if grep -qE -- "$pattern" $OUT/$name.log; then
    echo "ok    $name"
  else
    echo "FAIL  $name: no /$pattern/ (see $OUT/$name.log)"
    (( failures++ ))
  fi
}

# Rendering (look at the PNGs)
check snapshot-showcase $LIBERTTY --snapshot $OUT/showcase.png --cols 90 --rows 15 -- sh $ROOT/tests/fixtures/showcase.sh
check snapshot-boxes $LIBERTTY --snapshot $OUT/boxes.png --cols 80 --rows 30 -- sh $ROOT/tests/fixtures/boxes.sh
check snapshot-kitty $LIBERTTY --snapshot $OUT/kitty.png --cols 60 --rows 14 -- python3 $ROOT/tests/fixtures/kitty-image.py
check snapshot-kitty-placeholder $LIBERTTY --snapshot $OUT/kitty-placeholder.png --cols 50 --rows 8 -- python3 $ROOT/tests/fixtures/kitty-placeholder.py
# The block cursor on a wide (CJK) character covers both its cells, the character legible in it.
check snapshot-cursor-wide $LIBERTTY --snapshot $OUT/cursor-wide.png --cols 20 --rows 3 -- 'printf "\033[2 q中文测试\033[1;4H"; sleep 1'
# Underline styles (curly, dotted, dashed, double) in their own colors (SGR 58): Neovim's diagnostics.
check snapshot-underlines $LIBERTTY --snapshot $OUT/underlines.png --cols 40 --rows 4 -- 'printf "\033[4:3m\033[58:2::255:0:0mcurly red\033[0m  \033[4:4m\033[58;5;3mdotted\033[0m\n\033[4:5mdashed\033[0m  \033[4mplain\033[0m  \033[4:2m\033[58:2::0:160:255mdouble\033[0m\n"; sleep 1'
check snapshot-sprites $LIBERTTY --snapshot $OUT/sprites.png --cols 64 --rows 6 -- sh $ROOT/tests/fixtures/sprites.sh
check snapshot-ligatures $LIBERTTY --snapshot $OUT/ligatures.png --cols 64 --rows 4 -- 'printf "a -> b => c != d === e !== f <= g |> h <!-- -->\nplain words (just text)\n"'
expect padding-color 'padding-color: all passed' zsh $ROOT/tests/padding-color-test.sh $LIBERTTY $OUT
expect text-render 'text-render: all passed' zsh $ROOT/tests/text-render-test.sh $LIBERTTY $OUT
# Smooth scrolling half a row into the history: the row below the viewport peeks in.
check snapshot-smooth-scroll $LIBERTTY --snapshot $OUT/smooth-scroll.png --cols 40 --rows 6 --scroll-up 10 --offset 50 -- \
  'i=1; while [ $i -le 40 ]; do printf "\033[3%dmline %02d\033[0m \033[4%dm bg %02d \033[0m\n" $((i % 7 + 1)) $i $((i % 7 + 1)) $i; i=$((i+1)); done'

# Documents and settings
expect markdown '<table>' $LIBERTTY +render-markdown $ROOT/tests/fixtures/markdown.md
# Two files, each once, with their counts.
expect diff-render '^(.*main\.swift.*\+4</span> <span class="del">−3.*notes\.md.*\+1</span> <span class="del">−0)' $LIBERTTY +render-diff $ROOT/tests/fixtures/sample.diff
# A removed `-- comment` (SQL, Lua) is a removed line, not a file; format-patch's `-- ` trailer is no change.
expect diff-render-dashes '^(.*q\.sql.*\+0</span> <span class="del">−1.*z\.txt.*\+1</span> <span class="del">−0)' $LIBERTTY +render-diff $ROOT/tests/fixtures/sql-comment.patch
# A merge's combined diff (`@@@`, a column per parent): every line, read by its first character.
expect diff-render-merge 'f\.txt.*\+4</span> <span class="del">−0.*&gt;&gt;&gt;&gt;&gt;&gt;&gt; other' $LIBERTTY +render-diff $ROOT/tests/fixtures/merge.diff
# A format-patch series: each commit's header before its files, no `-- ` trailer as a change (a binary or renamed file last too).
expect diff-render-series-sql 'q\.sql</span><span class="stat"><span class="add">\+0</span> <span class="del">−1<' $LIBERTTY +render-diff $ROOT/tests/fixtures/series.patch
expect diff-render-series-bin 'zz\.bin</span><span class="stat"><span class="add">\+0</span> <span class="del">−0<' $LIBERTTY +render-diff $ROOT/tests/fixtures/series.patch
expect diff-render-series-rename 'zz-new\.txt</span><span class="stat"><span class="add">\+0</span> <span class="del">−0<' $LIBERTTY +render-diff $ROOT/tests/fixtures/series.patch
expect config-validates 'ok$' $LIBERTTY +validate-config --config-file /dev/null
expect config-get 'false|true' $LIBERTTY +get window-vsync
expect ligature-config 'all 8 right' $LIBERTTY --ligature-config-probe
# Check for Updates: a release's long notes in a box that scrolls (look at the PNGs).
expect update-notes 'notes box: 440x300' $LIBERTTY --update-notes-probe $ROOT/tests/fixtures/appcast.json $OUT/update-notes.png

# Links, selection, shell integration
expect links-url 'text https://example.com/a_\(b\) 0:4-28' $LIBERTTY --link-probe 'printf "see https://example.com/a_(b), ok.\n"'
expect links-osc8 'osc8 https://libertty.dev/docs' $LIBERTTY --link-probe 'printf "\033]8;;https://libertty.dev/docs\033\\\\here\033]8;;\033\\\\\n"'
# Chinese punctuation ends a URL; a URL's own Chinese doesn't.
expect links-cjk-punct 'text https://github.com/foo/bar 0:' $LIBERTTY --link-probe 'printf "详见 https://github.com/foo/bar，然后运行\n"'
expect links-cjk-quote 'text https://github.com/foo/bar 0:' $LIBERTTY --link-probe 'printf "访问“https://github.com/foo/bar”获取\n"'
expect links-kana 'text https://ja.wikipedia.org/wiki/佐々木小次郎 0:' $LIBERTTY --link-probe 'printf "https://ja.wikipedia.org/wiki/佐々木小次郎 です\n"'
expect links-cjk-path 'text https://zh.wikipedia.org/wiki/中文 0:' $LIBERTTY --link-probe 'printf "看 https://zh.wikipedia.org/wiki/中文。\n"'
expect links-path 'CLI.swift line 42 col 7' $LIBERTTY --link-probe 'printf "Sources/Libertty/App/CLI.swift:42:7: error\n"'
expect selection-autoscroll 'drag up \+ 3 ticks: line2' $LIBERTTY --selection-probe
expect selection-extend 'shift-click extend: line28 \| line29 \| line' $LIBERTTY --selection-probe
expect zsh-command-finished 'finished: printf .* exit=1' $LIBERTTY --command-probe zsh
expect bash-command-finished 'finished: sleep 0.3; echo .a;b. >/dev/null exit=0' $LIBERTTY --command-probe bash

# Last command's output (OSC 133 marks) and the scrollbar model
expect output-zsh '^\[out one' $LIBERTTY --output-probe zsh
expect output-bash '^out three\]' $LIBERTTY --output-probe bash
expect output-silent-zsh '^after a silent command: nothing$' $LIBERTTY --output-probe zsh
expect output-silent-bash '^after a silent command: nothing$' $LIBERTTY --output-probe bash
expect scrollbar 'scrolled to 200: total 401 offset 200 length 10' $LIBERTTY --scrollbar-probe

# Git: without developer tools /usr/bin/git is Apple's stub, which asks to install
# them; Libertty must find another git (Homebrew's, say) or do without. Here: an
# empty DEVELOPER_DIR. Every call then works or says git isn't installed — the
# stub would answer "xcrun: error: invalid DEVELOPER_DIR path".
expect git-found '^root: /' $LIBERTTY --git-probe
mkdir -p $PRIVATE/no-developer-tools
check git-without-tools sh -c 'out=$(env DEVELOPER_DIR=$1 PATH=/usr/bin:/bin "$0" --git-probe) && echo "$out" &&
  echo "$out" | grep -q "^git: " && ! echo "$out" | grep -qx "git: /usr/bin/git" &&
  [ $(echo "$out" | grep -cE "^(status|diff): (ok|git isn.t installed .*)$") = 2 ]' \
  $LIBERTTY $PRIVATE/no-developer-tools

# TERM and the ssh fallback (needs the bundle's compiled terminfo). The
# suite builds its own bundle, never build/Libertty.app: that may be the
# Libertty you're using. One older than this build is rebuilt: an old one
# may not know the probe flags, and would open a window instead.
TESTAPP=$ROOT/build/test.noindex/Libertty.app  # .noindex: Spotlight doesn't list it as another Libertty
APPBIN=$TESTAPP/Contents/MacOS/Libertty
if [[ ! -x $APPBIN || $APPBIN -ot $LIBERTTY ]]; then
  if ! LIBERTTY_PROBES=1 LIBERTTY_APP=$TESTAPP scripts/bundle.sh $CONFIG > $OUT/bundle.log 2>&1; then
    echo "FAIL  bundle (see $OUT/bundle.log)"
    (( failures++ ))
  fi
fi
if [[ -d $TESTAPP/Contents/Resources/terminfo && ! $APPBIN -ot $LIBERTTY ]]; then
  expect term-ghostty 'T=xterm-ghostty C=256' $APPBIN --shell-probe zsh 'echo "T=$TERM C=$(tput colors)"'
  expect ssh-env-zsh 'ssh is a shell function' $APPBIN --shell-probe zsh 'type ssh'
  expect ssh-env-bash 'ssh is a function' $APPBIN --shell-probe bash 'type ssh'
  # The app runs shells itself without session persistence: it carries the texts too.
  expect app-privacy-texts 'A program running in Libertty wants to use the camera' \
    plutil -extract NSCameraUsageDescription raw $TESTAPP/Contents/Info.plist
fi

# A remote host: tests/fixtures/fake-ssh stands in for ssh and runs the
# "remote" side here, with its own home, liberttyd and terminfo under $PRIVATE.
expect remote-host 'remote-probe: all passed' env LIBERTTY_SSH=$ROOT/tests/fixtures/fake-ssh \
  FAKE_SSH_HOME=$PRIVATE/remote-home FAKE_SSH_SOCKET=$PRIVATE/remote/liberttyd.sock FAKE_SSH_LOG=$PRIVATE/remote.log \
  FAKE_SSH_TERMINFO=$PRIVATE/remote-home/terminfo FAKE_SSH_DOWN=$PRIVATE/remote-down $LIBERTTY --remote-probe liberttytest

# Web Access: the page, its secret, a pane's screen and typing, over a
# real WebSocket on a private port (this Mac only).
expect web-access 'web-probe: all passed' env LIBERTTY_WEB_PORT=$(( 17000 + RANDOM % 900 )) \
  LIBERTTY_TAILSCALE=$ROOT/tests/fixtures/fake-tailscale FAKE_TAILSCALE_LOG=$PRIVATE/tailscale.log $LIBERTTY --web-probe

# Sessions (liberttyd)
ID=$($LIBERTTY +new-session -e 'printf "persisted\n"; sleep 30')
sleep 0.5
expect session-list "$ID" $LIBERTTY +list-sessions
expect session-capture 'persisted' $LIBERTTY +capture $ID
# A session's program asks for the camera, microphone, … in liberttyd's name
# (which carries the texts), not in the name of whoever started liberttyd —
# here, the terminal running these tests.
SHELLPID=$($LIBERTTY +list-sessions --json | python3 -I -c "import json, sys; print(next(s['pid'] for s in json.load(sys.stdin) if s['id'] == '$ID'))")
expect privacy-responsible '^responsible: .*/liberttyd$' $LIBERTTY --responsible-probe ${SHELLPID:-0}
expect privacy-texts 'A program running in Libertty wants to use the microphone' \
  launchctl plist __TEXT,__info_plist $BIN/liberttyd
$LIBERTTY +kill-session $ID > /dev/null
WAITID=$($LIBERTTY +new-session -e 'sleep 0.3; exit 4')
$LIBERTTY +wait $WAITID > /dev/null 2>&1
if [[ $? == 4 ]]; then echo "ok    session-wait-status"; else echo "FAIL  session-wait-status"; (( failures++ )); fi

# ⌘K clears liberttyd's copy too (or the history would come back on reattach)
expect clear-reaches-liberttyd 'before ⌘K: 50, after: [0-2], window: [0-2]$' $LIBERTTY --clear-probe
expect clear-mid-sequence 'mid-sequence: liberttyd intact, window intact' $LIBERTTY --clear-probe
expect kitty-reattach 'images kept' $LIBERTTY --kitty-reattach-probe $ROOT/tests/fixtures/kitty-image.py
expect kitty-reattach-placeholder 'images kept' $LIBERTTY --kitty-reattach-probe $ROOT/tests/fixtures/kitty-placeholder.py
# Shift+2 must reach the program as "@", not "2", in legacy and kitty
# disambiguate modes (tclaude turned CSI u into the bare digit).
expect kitty-key 'kitty-key: all passed' $LIBERTTY --kitty-key-probe
# After a resize of an alternate-screen session, liberttyd re-sends its
# screen (GoRex's race: a window's copy and the daemon's drift apart).
expect resize-resync 'resize-resync: all passed' $LIBERTTY --resize-resync-probe
# A window that stops reading holds up nobody: not the program, not the
# other windows, not typing; it skips ahead with a snapshot (or is hung up).
expect slow-client 'slow-client: all passed' $LIBERTTY --slow-client-probe
# The UI itself: real AppKit key events at a real window, off screen and
# never focused (the only check that goes through TerminalView's keyboard).
expect ui-probe 'ui-probe: all passed' $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/ui-probe.txt)" $OUT
# The Git panel's buttons, in a scratch repository.
REPO=$PRIVATE/repo
mkdir -p $REPO/Sources
( cd $REPO && git init -q -b main && git config user.email t@example.com && git config user.name t \
  && printf 'a\n' > Sources/a.swift && git add -A && git commit -qm init \
  && printf 'b\n' >> Sources/a.swift && printf 'n\n' > Sources/new.swift )
expect git-panel 'ui-probe: all passed' $LIBERTTY --ui-probe "$(sed "s|@REPO@|$REPO|g" $ROOT/tests/fixtures/git-panel.txt)" $OUT
# GoRex's GUI ideas: tab labels, restart in place, zoom shown, Go to Pane,
# the palette's "No matches", rename in place.
mkdir -p $PRIVATE/gui/deep/a/b/c/proj $PRIVATE/gui/elsewhere/here
expect gorex-gui 'ui-probe: all passed' $LIBERTTY --ui-probe "$(sed "s|@DIR@|$PRIVATE/gui|g" $ROOT/tests/fixtures/gorex-gui.txt)" $OUT
# Program states (OSC 7501): the tab, notifications, the Dock badge and sounds,
# with the default settings and with each one set apart.
mkdir -p $PRIVATE/empty-config
expect program-status 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/program-status.txt)" $OUT
mkdir -p $PRIVATE/status-config/libertty
print 'program-status-indicator = blocked,error\nprogram-status-notify = error\nprogram-status-dock-badge = blocked,done\nprogram-status-sound = blocked:Ping,done' \
  > $PRIVATE/status-config/libertty/config
expect program-status-settings 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/status-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/program-status-settings.txt)" $OUT
print 'program-status-notify = blocked,bogus\nprogram-status-sound = done:NoSuchSound' > $PRIVATE/status-bad.conf
expect program-status-config 'unknown state “bogus”' $LIBERTTY +validate-config --config-file $PRIVATE/status-bad.conf
expect program-status-sound-config 'no sound named “NoSuchSound”' $LIBERTTY +validate-config --config-file $PRIVATE/status-bad.conf
# Coding agents: Claude Code's hook as it runs it, +status, and a session's
# name on its tab (in liberttyd: --persist).
expect agent 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/agent.txt)" $OUT --persist
# +agent-setup in a Claude Code folder of the test's own: its hooks and skill
# go in once, others' hooks stay, --remove takes only Libertty's away.
AGENT=$PRIVATE/claude
mkdir -p $AGENT
print '{"hooks":{"Stop":[{"hooks":[{"type":"command","command":"say done"}]}]},"model":"opus"}' > $AGENT/settings.json
check agent-setup sh -c '"$0" +agent-setup --claude-dir "$1" --yes && "$0" +agent-setup --claude-dir "$1" --yes | grep -q "nothing to do" &&
  [ "$(grep -c "agent-hook claude" "$1/settings.json")" = 6 ] && grep -q "say done" "$1/settings.json" && [ -f "$1/skills/libertty/SKILL.md" ] &&
  "$0" +agent-setup --claude-dir "$1" --remove --yes && ! grep -q agent-hook "$1/settings.json" &&
  grep -q "say done" "$1/settings.json" && grep -q opus "$1/settings.json" && [ ! -d "$1/skills/libertty" ]' $LIBERTTY $AGENT
# +agent-setup for Codex: notify goes in before config.toml's first table,
# once; a notify of someone else's is left alone; --remove leaves the file as it was.
CODEX=$PRIVATE/codex
mkdir -p $CODEX
print 'model = "gpt-5-codex"\n\n[tui]\nnotifications = true' > $CODEX/config.toml
cp $CODEX/config.toml $PRIVATE/codex-original.toml
check agent-setup-codex sh -c '"$0" +agent-setup --agent codex --codex-dir "$1" --yes &&
  "$0" +agent-setup --agent codex --codex-dir "$1" --yes | grep -q "nothing to do" &&
  [ "$(grep -c "agent-hook codex notify" "$1/config.toml")" = 1 ] && [ -f "$1/skills/libertty/SKILL.md" ] &&
  awk "/^notify/ { n = NR } /^\[tui\]/ { t = NR } END { exit !(n && t && n < t) }" "$1/config.toml" &&
  "$0" +agent-setup --agent codex --codex-dir "$1" --remove --yes && cmp -s "$1/config.toml" "$2" && [ ! -d "$1/skills/libertty" ] &&
  echo "notify = [\"say\", \"done\"]" > "$1/config.toml" && ! "$0" +agent-setup --agent codex --codex-dir "$1" --yes &&
  grep -q "say" "$1/config.toml" && ! grep -q agent-hook "$1/config.toml"' $LIBERTTY $CODEX $PRIVATE/codex-original.toml
# Moving panes and tabs: to a new tab, another tab, a new window, and a
# window's tab to another window (the windows it opens stay off screen).
expect move 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed "s|@N@|$RANDOM|g" $ROOT/tests/fixtures/move.txt)" $OUT
# +split and +move-pane: panes arranged by session ID from a pane's shell.
expect split-cli 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/split-cli.txt)" $OUT --persist
# libertty +swap-pane, +resize-pane, +move-pane --beside.
expect arrange-cli 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/arrange-cli.txt)" $OUT --persist
# A program that fails at once keeps its pane (a key closes it); --keep-open.
expect keep-open 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/keep-open.txt)" $OUT --persist
# A program reading a password shows as waiting for you: through liberttyd and on a pty of the app's own.
expect password 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/password.txt)" $OUT --persist
expect password-local 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/password.txt)" $OUT
# focus-follows-mouse: on, the pane under the pointer gets the keyboard; off (the default), it doesn't.
mkdir -p $PRIVATE/ffm-config/libertty
print 'focus-follows-mouse = true' > $PRIVATE/ffm-config/libertty/config
expect focus-follows-mouse 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/ffm-config \
  $LIBERTTY --ui-probe "$(sed 's/@FIRST@/1/' $ROOT/tests/fixtures/focus-follows-mouse.txt)" $OUT
expect focus-follows-mouse-off 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed 's/@FIRST@/2/' $ROOT/tests/fixtures/focus-follows-mouse.txt)" $OUT
# Go to Directory: the palette's Folders, a typed path, where shells have been.
mkdir -p $PRIVATE/folders
expect go-to-directory 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed "s|@DIR@|$PRIVATE/folders|g" $ROOT/tests/fixtures/go-to-directory.txt)" $OUT
# Config changes reach the panes: written in place or replaced, a theme's
# file, light/dark, Reload Configuration (back to font-size after ⌘+).
mkdir -p $PRIVATE/reload-config/libertty/themes
printf 'font-size = 14\ntheme = probe-theme\n' > $PRIVATE/reload-config/libertty/config
printf 'background = #112233\n' > $PRIVATE/reload-config/libertty/themes/probe-theme
expect config-reload 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/reload-config \
  $LIBERTTY --ui-probe "$(sed "s|@CFG@|$PRIVATE/reload-config/libertty|g" $ROOT/tests/fixtures/config-reload.txt)" $OUT
# Settings from the palette, tried out live and kept or put back (a config of its own).
mkdir -p $PRIVATE/picker-config/libertty/themes
printf 'font-size = 14\ntheme = probe-theme\n' > $PRIVATE/picker-config/libertty/config
printf 'background = #112233\n' > $PRIVATE/picker-config/libertty/themes/probe-theme
expect settings-picker 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/picker-config \
  $LIBERTTY --ui-probe "$(sed "s|@CFG@|$PRIVATE/picker-config/libertty|g" $ROOT/tests/fixtures/settings-picker.txt)" $OUT
# Libertty ▸ Theme Editor: colors tried in every window, Cancel, Save and Use (a config of its own).
mkdir -p $PRIVATE/theme-config/libertty/themes
printf 'theme = probe-theme\n' > $PRIVATE/theme-config/libertty/config
printf 'background = #112233\n' > $PRIVATE/theme-config/libertty/themes/probe-theme
expect theme-editor 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/theme-config \
  $LIBERTTY --ui-probe "$(sed "s|@CFG@|$PRIVATE/theme-config/libertty|g" $ROOT/tests/fixtures/theme-editor.txt)" $OUT
# Panes rearranged by a drag's drop, Split Best Fit; split-autobalance evening them out.
expect arrange 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/arrange.txt)" $OUT
mkdir -p $PRIVATE/balance-config/libertty
printf 'split-autobalance = true\nconfirm-close = false\n' > $PRIVATE/balance-config/libertty/config
expect autobalance 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/balance-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/autobalance.txt)" $OUT
# pane-style, accent-color, pane-glass from the config (a folder of its own).
mkdir -p $PRIVATE/looks-config/libertty/themes
: > $PRIVATE/looks-config/libertty/config
printf 'background = #15171c\ncursor-color = #f2b45a\n' > $PRIVATE/looks-config/libertty/themes/probe-theme
expect looks 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/looks-config \
  $LIBERTTY --ui-probe "$(sed "s|@CFG@|$PRIVATE/looks-config/libertty|g" $ROOT/tests/fixtures/looks.txt)" $OUT
expect column-fit 'column-fit: all passed' $LIBERTTY --column-fit-probe
# The sidebar and inspector come and go around the terminal: it stays put, its grid unchanged.
expect sidebar-toggle 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/sidebar-toggle.txt)" $OUT
# The sidebar's activity filter.
expect sidebar-activity 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/sidebar-activity.txt)" $OUT
# Tabs along the top (tab-bar = top), in a config of its own.
mkdir -p $PRIVATE/strip/top-a $PRIVATE/strip/top-b $PRIVATE/strip-config/libertty
print 'tab-bar = top' > $PRIVATE/strip-config/libertty/config
expect tab-strip 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/strip-config \
  $LIBERTTY --ui-probe "$(sed "s|@DIR@|$PRIVATE/strip|g" $ROOT/tests/fixtures/tab-strip.txt)" $OUT
# The editor block: open, type, save, changes on disk, line ends, unsaved-close, --wait.
ED=$PRIVATE/editor
mkdir -p $ED
printf 'print("hello")\n' > $ED/hello.py
printf 'first\nsecond\nthird\nfourth\n' > $ED/lines.txt
printf 'one\r\ntwo\r\n' > $ED/crlf.txt
printf '# Notes\n\nSome *text*.\n' > $ED/notes.md
printf '\n# Please enter the commit message\n' > $ED/COMMIT_EDITMSG
printf 'caf\351\n' > $ED/latin1.txt
printf '\377\376h\000i\000' > $ED/utf16.txt
printf '\357\273\277hi\n' > $ED/bom.txt
printf 'target\n' > $ED/target.txt
ln -s target.txt $ED/linked.txt
printf 'start\n' > $ED/wq.txt
{ print '[Far](#far-below) [Café](#café)\n'; for i in {1..200}; print "line $i\n"; print '## Far below\n\n## Café\n'; for i in {1..60}; print "more $i\n" } > $ED/toc.md
expect editor 'ui-probe: all passed' $LIBERTTY --ui-probe "$(sed "s|@DIR@|$ED|g" $ROOT/tests/fixtures/editor.txt)" $OUT
# The Git block: stage a hunk, commit, history, a branch, a stash — through its page.
GB=$PRIVATE/gitblock
mkdir -p $GB
( cd $GB && git init -q -b main && git config user.email t@example.com && git config user.name t \
  && git config diff.noprefix true \
  && printf 'struct App {\n    let name = "x"\n}\n' > app.swift && git add -A && git commit -qm First \
  && printf 'struct App {\n    let name = "x"\n    let size = 1\n}\n' > app.swift && git commit -qam Second \
  && printf 'struct App {\n    let name = "x"\n    let size = 1\n    let answer = 42\n}\n' > app.swift && printf 'new\n' > notes.txt )
expect git-block 'ui-probe: all passed' $LIBERTTY --ui-probe "$(sed "s|@REPO@|$GB|g" $ROOT/tests/fixtures/git-block.txt)" $OUT
# The Tasks block: its own sleep found under the terminal, read, and quit.
expect tasks 'ui-probe: all passed' $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/tasks.txt)" $OUT
# The canvas block: a drawing from its file, saved as drawn, following the disk; a new one.
CV=$PRIVATE/canvas
mkdir -p $CV
cp $ROOT/tests/fixtures/sketch.excalidraw $CV/
expect canvas 'ui-probe: all passed' $LIBERTTY --ui-probe "$(sed -e "s|@DIR@|$CV|g" -e "s|@DATA@|$PRIVATE|g" $ROOT/tests/fixtures/canvas.txt)" $OUT
# The profiler: a busy loop recorded with sample, shown in speedscope, kept.
expect profiler 'ui-probe: all passed' $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/profiler.txt)" $OUT
pkill -f "while True: sum(i \* i for i in range(9999))" 2> /dev/null
# The board: BOARD.md as columns; a card added, moved, checked; followed; as text; *.board.md.
BD=$PRIVATE/board
mkdir -p $BD
expect board 'ui-probe: all passed' $LIBERTTY --ui-probe "$(sed "s|@DIR@|$BD|g" $ROOT/tests/fixtures/board.txt)" $OUT
# The SQLite block: tables, pages, sorting, structure, queries, read-only, an edited cell.
SQ=$PRIVATE/sqlite
mkdir -p $SQ
python3 -I $ROOT/tests/fixtures/make-sqlite.py $SQ/app.db
expect sqlite 'ui-probe: all passed' $LIBERTTY --ui-probe "$(sed "s|@DIR@|$SQ|g" $ROOT/tests/fixtures/sqlite.txt)" $OUT
# Plugins: found off, turned on, a palette command, a finished command heard, storage, a broken one, reload on save.
mkdir -p $PRIVATE/plugin-config/libertty
cp -R $ROOT/tests/fixtures/plugins $PRIVATE/plugin-config/libertty/plugins
expect plugins 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/plugin-config $LIBERTTY --ui-probe \
  "$(sed -e "s|@DATA@|$PRIVATE|g" -e "s|@CONFIG@|$PRIVATE/plugin-config|g" $ROOT/tests/fixtures/plugins.txt)" $OUT
# The notebook block, in a jupyter of this run's (LIBERTTY_TEST_JUPYTER, the
# one in build/jupyter, or the PATH's); skipped where there's none.
JUPYTER=${LIBERTTY_TEST_JUPYTER:-}
[[ -z $JUPYTER && -x $ROOT/build/jupyter/bin/jupyter ]] && JUPYTER=$ROOT/build/jupyter/bin/jupyter
[[ -z $JUPYTER ]] && JUPYTER=$(command -v jupyter || true)
if [[ -n $JUPYTER ]] && $JUPYTER server --version > /dev/null 2>&1; then
  NB=$PRIVATE/notebook
  mkdir -p $NB $PRIVATE/notebook-config/libertty
  python3 -I $ROOT/tests/fixtures/make-notebook.py $NB/probe.ipynb
  print "jupyter = $JUPYTER" > $PRIVATE/notebook-config/libertty/config
  expect notebook 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/notebook-config $LIBERTTY --ui-probe \
    "$(sed "s|@DIR@|$NB|g" $ROOT/tests/fixtures/notebook.txt)" $OUT
else
  echo "skip  notebook (no jupyter server: pip install jupyter_server ipykernel, or LIBERTTY_TEST_JUPYTER=…)"
fi
# The screen block, on Libertty's own windows only (never a display or another app's).
expect screen 'ui-probe: all passed' $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/screen.txt)" $OUT
# The browser block, against a local server (python's), read and driven as +browser does.
PORT=$(python3 -I -c 'import socket; s=socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1])')
python3 -I -m http.server $PORT --bind 127.0.0.1 --directory $ROOT/tests/fixtures/site > /dev/null 2>&1 &
SITE_PID=$!
sleep 0.5
expect browser 'ui-probe: all passed' $LIBERTTY --ui-probe "$(sed "s|@SITE@|http://127.0.0.1:$PORT|g" $ROOT/tests/fixtures/browser.txt)" $OUT
mkdir -p $PRIVATE/browser-config/libertty
print 'browser-automation = true' > $PRIVATE/browser-config/libertty/config
expect browser-automation 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/browser-config $LIBERTTY --ui-probe \
  "$(sed -e "s|@SITE@|http://127.0.0.1:$PORT|g" -e "s|@HOST@|127.0.0.1:$PORT|g" -e "s|@OUT@|$OUT|g" $ROOT/tests/fixtures/browser-automation.txt)" $OUT
kill $SITE_PID 2>/dev/null
# Park Pane / Unpark Pane.
expect park 'ui-probe: all passed' $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/park.txt)" $OUT
# Workspaces: named sets of tabs in a window.
expect workspaces 'ui-probe: all passed' $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/workspaces.txt)" $OUT
# Panes: zoomed navigation, Redo of a close, two siblings ending at once.
expect splits 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/splits.txt)" $OUT
# Float Pane: a live card in the split's corner.
expect float 'ui-probe: all passed' $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/float.txt)" $OUT
# liberttyd keeps the window layout the app gives it, across a takeover.
expect layout-store 'layout-store: all passed' $LIBERTTY --layout-store-probe
# +wait --until prompt|idle, +capture --ansi|--html, +events (Tern's wait / capture / events).
expect cli-wait 'cli-wait: all passed' zsh $ROOT/tests/cli-wait-test.sh $LIBERTTY
expect send-key 'send-key: all passed' zsh $ROOT/tests/send-key-test.sh $LIBERTTY
expect import-ghostty 'import-ghostty: all passed' zsh $ROOT/tests/import-ghostty-test.sh $LIBERTTY

# Big paste: every byte arrives, through a full pty (EAGAIN) and through liberttyd
expect paste-local 'read 2000000 ' $LIBERTTY --paste-probe
expect paste-liberttyd 'read 2000000 ' $LIBERTTY --paste-probe --persist

# Throughput, end to end (no window), both paths
expect throughput-local 'local pty: [0-9]+ MB/s' $LIBERTTY --session-bench $ROOT/bench/payloads/dense_cells.bin --mb 100
expect throughput-liberttyd 'via liberttyd: [0-9]+ MB/s' $LIBERTTY --session-bench $ROOT/bench/payloads/dense_cells.bin --mb 100 --persist
grep -hE 'MB/s' $OUT/throughput-*.log | sed 's/^/      /'

(( failures == 0 )) && echo "all passed" || echo "$failures failed"
exit $(( failures > 0 ))
