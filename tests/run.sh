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
mkdir -p $ROOT/build
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

# Checks run side by side, JOBS at a time (LIBERTTY_TEST_JOBS; 1 runs them
# one after another): each with a liberttyd and a data folder of its own,
# and its own copy of the empty config (a probe may write its config). A
# stretch that shares the suite's liberttyd between commands runs with
# SERIAL=1. Results print as each check ends, a summary in order at the end.
JOBS=${LIBERTTY_TEST_JOBS:-4}
SERIAL=0
typeset -a ORDER
mkdir -p $PRIVATE/jobs

# LIBERTTY_TEST_RETRIES (CI: 1): a check that fails runs again, from the
# start, that many times; one that passes so says it, and its first run's
# log stays as NAME.first.log. Locally 0: a failure is a failure.
RETRIES=${LIBERTTY_TEST_RETRIES:-0}

judge() {  # judge NAME PATTERN COMMAND...
  local name=$1 tries=0
  while true; do
    attempt "$@"
    [[ $(cat $PRIVATE/jobs/$name/result) == ok* ]] && break
    (( tries >= RETRIES )) && break
    (( tries++ ))
    cp $OUT/$name.log $OUT/$name.first.log
    rm -rf $PRIVATE/jobs/$name/config $PRIVATE/jobs/$name/d.sock*
  done
  (( tries > 0 )) && [[ $(cat $PRIVATE/jobs/$name/result) == ok* ]] && echo "ok    $name (passed on retry $tries)" > $PRIVATE/jobs/$name/result
  cat $PRIVATE/jobs/$name/result
}

attempt() {  # attempt NAME PATTERN COMMAND... : PATTERN empty = the exit status decides
  local name=$1 pattern=$2; shift 2
  local dir=$PRIVATE/jobs/$name ok=0 a
  mkdir -p $dir
  local -a args=()
  for a in "$@"; do
    if [[ $a == XDG_CONFIG_HOME=$PRIVATE/empty-config ]]; then mkdir -p $dir/config; a=XDG_CONFIG_HOME=$dir/config; fi
    args+=("$a")
  done
  if (( SERIAL )); then
    limit "${args[@]}" > $OUT/$name.log 2>&1
  else
    limit env LIBERTTY_DAEMON_SOCKET=$dir/d.sock LIBERTTY_DAEMON_LOG=$dir/d.log LIBERTTY_DATA_DIR=$dir \
      "${args[@]}" > $OUT/$name.log 2>&1
  fi
  local code=$?
  if [[ -z $pattern ]]; then (( code == 0 )) && ok=1; else grep -qE -- "$pattern" $OUT/$name.log && ok=1; fi
  if (( ok )); then
    echo "ok    $name" > $dir/result
  elif [[ -z $pattern ]]; then
    echo "FAIL  $name (see $OUT/$name.log)" > $dir/result
  else
    echo "FAIL  $name: no /$pattern/ (see $OUT/$name.log)" > $dir/result
  fi
}

# UI probes are timed by the wall clock (a step waits so long, then looks):
# at most UI_JOBS of them at once, the rest of the slots for everything else.
UI_JOBS=${LIBERTTY_TEST_UI_JOBS:-4}
typeset -a UI_PIDS CHECK_PIDS

# Until every check started so far is done (not `wait`: servers the suite
# runs in the background never end).
settle() { local p; for p in $CHECK_PIDS; do wait $p 2> /dev/null; done; CHECK_PIDS=(); }

run() {  # run NAME PATTERN COMMAND...
  ORDER+=($1)
  if (( SERIAL || JOBS <= 1 )); then judge "$@"; return; fi
  local ui=0
  [[ " $* " == *" --ui-probe "* ]] && ui=1
  while true; do
    UI_PIDS=(${UI_PIDS:#}) ; local alive=() p
    for p in $UI_PIDS; do kill -0 $p 2> /dev/null && alive+=($p); done
    UI_PIDS=($alive)
    (( ${#${(f)"$(jobs -r)"}} < JOBS )) && (( ! ui || ${#UI_PIDS} < UI_JOBS )) && break
    sleep 0.05
  done
  judge "$@" &
  CHECK_PIDS+=($!)
  (( ui )) && UI_PIDS+=($!)
}

# Until check NAME has its result: two that can't share the machine (WebKit's
# store is the app's, whichever process opens it).
after() { while [[ ! -e $PRIVATE/jobs/$1/result ]]; do sleep 0.1; done; }

check() { local name=$1; shift; run $name "" "$@"; }  # check NAME COMMAND... : passes if COMMAND succeeds
expect() { run "$@"; }  # expect NAME PATTERN COMMAND... : passes if the output matches PATTERN

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
expect links-path 'CLI.swift line 42 col 7' $LIBERTTY --link-probe 'printf "Sources/LiberttyApp/App/CLI.swift:42:7: error\n"'
# Every link on screen, in order and each once (Quick Look's items): a path's lines are one file; what isn't there isn't one.
expect links-visible 'visible: x \| Package.swift \| docs$' $LIBERTTY --link-probe 'printf "see https://example.com/x and Package.swift:3, Package.swift again\n\033]8;;https://libertty.dev/docs\033\\\\here\033]8;;\033\\\\ nope.txt\n"'
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
  # AppleScript, told to itself (Cocoa reads the dictionary from the bundle's Info.plist).
  mkdir -p $PRIVATE/applescript-dir
  expect applescript 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
    $APPBIN --ui-probe "$(sed "s|@DIR@|$PRIVATE/applescript-dir|g" $ROOT/tests/fixtures/applescript.txt)" $OUT
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

# Sessions (liberttyd): commands one after another on the suite's liberttyd.
SERIAL=1
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
SERIAL=0

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
# Codex's turn: Return in its pane says working, until its notify hook or quiet.
mkdir -p $PRIVATE/codex-bin
expect codex-turn 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed "s|@DIR@|$PRIVATE/codex-bin|g" $ROOT/tests/fixtures/codex-turn.txt)" $OUT
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
# Floating panes: a shell of its own over the split, minimized and back, saved with the layout, ⌘W closing only it.
expect floating-pane 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/floating-pane.txt)" $OUT --persist
# A session in two windows: a pane of another size than its program's says so, and takes it back.
expect sized-elsewhere 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/sized-elsewhere.txt)" $OUT --persist
# Surfaces (OSC 7502, docs/surface-protocol.md): a program draws native UI in its output, hears
# a choice, typing and a click, and its card dims when it ends; through liberttyd too; off, nothing.
mkdir -p $PRIVATE/surfaces $PRIVATE/surfaces-off-config/libertty $PRIVATE/lenses
cp $ROOT/tests/fixtures/surface-probe.py $ROOT/tests/fixtures/surface-flood.py $PRIVATE/surfaces/
print 'surfaces = false' > $PRIVATE/surfaces-off-config/libertty/config
SURFACES=(sed "s|@DIR@|$PRIVATE/surfaces|g; s|@TOOLS@|$ROOT/tools/surface|g")
expect surfaces 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$($SURFACES $ROOT/tests/fixtures/surfaces.txt)" $OUT
expect surfaces-persist 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$($SURFACES $ROOT/tests/fixtures/surfaces-persist.txt)" $OUT --persist
expect surfaces-off 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/surfaces-off-config \
  $LIBERTTY --ui-probe "$($SURFACES $ROOT/tests/fixtures/surfaces-off.txt)" $OUT
expect surface-cli 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/surface-cli.txt)" $OUT
# Command lenses: git status, cc's errors, grep -rn's matches as lists on their command lines.
expect lenses 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed "s|@DIR@|$PRIVATE/lenses|g" $ROOT/tests/fixtures/lenses.txt)" $OUT
# Autocomplete at the prompt: ghost text from history, the keys that take it,
# what's never remembered, the completion list. zsh with an empty ZDOTDIR:
# the integration, none of the user's plugins.
mkdir -p $PRIVATE/empty-zdotdir
expect autocomplete 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  LIBERTTY_SHELL=/bin/zsh ZDOTDIR=$PRIVATE/empty-zdotdir \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/autocomplete.txt)" $OUT
# focus-follows-mouse: on, the pane under the pointer gets the keyboard; off (the default), it doesn't.
mkdir -p $PRIVATE/ffm-config/libertty
print 'focus-follows-mouse = true' > $PRIVATE/ffm-config/libertty/config
expect focus-follows-mouse 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/ffm-config \
  $LIBERTTY --ui-probe "$(sed 's/@FIRST@/1/' $ROOT/tests/fixtures/focus-follows-mouse.txt)" $OUT
expect focus-follows-mouse-off 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed 's/@FIRST@/2/' $ROOT/tests/fixtures/focus-follows-mouse.txt)" $OUT
# bash's integration: a folder changed earlier on the line is the pane's before the program starts.
mkdir -p $PRIVATE/bash-cwd/deep/a/b/c/proj
expect bash-cwd 'ui-probe: all passed' env LIBERTTY_SHELL=/bin/bash XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed "s|@DIR@|$PRIVATE/bash-cwd|g" $ROOT/tests/fixtures/bash-cwd.txt)" $OUT
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
# Libertty ▸ Settings… (⌘,): a control changes one line of the config, in place; a theme, a search.
mkdir -p $PRIVATE/settings-config/libertty
printf '# Settings writes its lines in place: this stays.\nfont-size = 14\ntab-bar = left\n# The end.\n' > $PRIVATE/settings-config/libertty/config
expect settings-window 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/settings-config \
  $LIBERTTY --ui-probe "$(sed "s|@CFG@|$PRIVATE/settings-config/libertty|g" $ROOT/tests/fixtures/settings-window.txt)" $OUT
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
# Jump to the pane that needs you (⌘J).
expect attention 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/attention.txt)" $OUT
# active-border: a border round the focused pane of a split, following focus.
mkdir -p $PRIVATE/border-config/libertty
print 'active-border = true' > $PRIVATE/border-config/libertty/config
expect active-border 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/border-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/active-border.txt)" $OUT
# Activity By State: panes under Waiting for You, Failed, Working, Done.
expect activity-by-state 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/activity-by-state.txt)" $OUT
# Settings ▸ liberttyd ▸ System Permissions: liberttyd reports its own.
expect permissions 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/permissions.txt)" $OUT --persist
# Help ▸ Get Started with Libertty: the welcome guide's four pages.
expect welcome 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/welcome.txt)" $OUT
# Settings ▸ Terminal: the font's faces for regular, bold and italic text.
mkdir -p $PRIVATE/styles-config/libertty
printf 'font-family = Menlo\nfont-style-bold = false\n' > $PRIVATE/styles-config/libertty/config
expect font-styles 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/styles-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/font-styles.txt)" $OUT
# Trackpad gestures: pinch to zoom a pane, swipe for the sidebar.
expect gestures 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/gestures.txt)" $OUT
# Closing where an agent works or waits on you says so by its name.
expect close-warning 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/close-warning.txt)" $OUT
# An agent's state from its screen: a stand-in Codex, built here.
mkdir -p $PRIVATE/agent-screen
cc -o $PRIVATE/agent-screen/codex $ROOT/tests/fixtures/fake-codex.c
expect agent-screen 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed "s|@DIR@|$PRIVATE/agent-screen|g" $ROOT/tests/fixtures/agent-screen.txt)" $OUT --persist
# Prompts for a coding agent: queued ones go one by one as it comes to rest (a
# stand-in "claude", tests/fixtures/fake-agent-queue.c), never while it waits
# for you; the composer sends, queues, keeps drafts, asks before line by line.
mkdir -p $PRIVATE/queue
cc -o $PRIVATE/queue/claude $ROOT/tests/fixtures/fake-agent-queue.c
expect prompt-queue 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed "s|@DIR@|$PRIVATE/queue|g" $ROOT/tests/fixtures/prompt-queue.txt)" $OUT
expect composer 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed "s|@DIR@|$PRIVATE/queue|g" $ROOT/tests/fixtures/composer.txt)" $OUT
expect prompt-queue-cli 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/prompt-queue-cli.txt)" $OUT --persist
# Fork Conversation: the panes run cat, so the agents' fork commands are only shown.
mkdir -p $PRIVATE/fork-config/libertty
print 'command = cat' > $PRIVATE/fork-config/libertty/config
expect fork-conversation 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/fork-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/fork-conversation.txt)" $OUT --persist
# Resume Conversation…: one a hook recorded, picked up in a new tab in its
# folder (no claude on this PATH: only the typed command is looked for).
mkdir -p $PRIVATE/resume/data $PRIVATE/resume/proj
print -r -- '[{"agent":"claude","id":"13b9c2e4-probe","session":"gone","directory":"'$PRIVATE/resume/proj'","name":"fix-login","title":"","started":1,"active":2,"ended":false}]' \
  > $PRIVATE/resume/data/conversations.json
expect resume 'ui-probe: all passed' env LIBERTTY_DATA_DIR=$PRIVATE/resume/data PATH=/usr/bin:/bin LIBERTTY_SHELL=/bin/sh \
  XDG_CONFIG_HOME=$PRIVATE/empty-config $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/resume.txt)" $OUT
# Tabs along the top (tab-bar = top), in a config of its own.
mkdir -p $PRIVATE/strip/top-a $PRIVATE/strip/top-b $PRIVATE/strip-config/libertty
print 'tab-bar = top' > $PRIVATE/strip-config/libertty/config
expect tab-strip 'ui-probe: all passed' env LIBERTTY_SHELL=/bin/zsh XDG_CONFIG_HOME=$PRIVATE/strip-config \
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
# Last Turn: an agent's turn's changes alone, kept or reverted hunk by hunk.
LT=$PRIVATE/last-turn
mkdir -p $LT
( cd $LT && git init -q -b main && git config user.email t@example.com && git config user.name t \
  && printf 'one\n' > app.txt && printf 'two\n' > other.txt && printf 'one\ntwo\nthree\nfour\nfive\nsix\n' > list.txt \
  && git add -A && git commit -qm First \
  && printf 'before the turn\n' >> other.txt )
expect last-turn 'ui-probe: all passed' $LIBERTTY --ui-probe "$(sed "s|@REPO@|$LT|g" $ROOT/tests/fixtures/last-turn.txt)" $OUT
# language = zh-Hans: the palette and Settings in Chinese, the config in its own words.
mkdir -p $PRIVATE/zh-config/libertty
print 'language = zh-Hans' > $PRIVATE/zh-config/libertty/config
expect chinese 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/zh-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/chinese.txt)" $OUT
# Toggle Dark Mode: the other appearance, one line of the config.
# (A config file there already: a first write would add the template too.)
mkdir -p $PRIVATE/appearance-config/libertty
: > $PRIVATE/appearance-config/libertty/config
expect appearance-toggle 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/appearance-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/appearance-toggle.txt)" $OUT
# ⌘ over an image's path: the picture beside it.
mkdir -p $PRIVATE/peek
sips -s format png -z 60 90 /System/Library/CoreServices/CoreTypes.bundle/Contents/Resources/GenericDocumentIcon.icns \
  --out $PRIVATE/peek/shot.png > /dev/null 2>&1
print hi > $PRIVATE/peek/notes.txt
expect image-peek 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed "s|@DIR@|$PRIVATE/peek|g" $ROOT/tests/fixtures/image-peek.txt)" $OUT
# Quick Look (⌘Y, ⇧⌘-click): what the panel would list.
mkdir -p $PRIVATE/quick-look/sub
print hi > $PRIVATE/quick-look/notes.txt
print png > $PRIVATE/quick-look/shot.png
print 'see shot.png, notes.txt:3 and https://example.com/a\nagain shot.png, ./sub and missing.txt' > $PRIVATE/quick-look/list
expect quick-look 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed "s|@DIR@|$PRIVATE/quick-look|g" $ROOT/tests/fixtures/quick-look.txt)" $OUT
# Sidebar rows' second line and the header's branch.
SR=$PRIVATE/sidebar-rows
mkdir -p $SR
( cd $SR && git init -q -b main && git config user.email t@example.com && git config user.name t \
  && printf 'one\n' > a.txt && git add -A && git commit -qm First && printf 'two\n' >> a.txt )
expect sidebar-rows 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed "s|@REPO@|$SR|g" $ROOT/tests/fixtures/sidebar-rows.txt)" $OUT
# A diff document: files fold, all at once too, side by side once wide.
expect diff-document 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed "s|@ROOT@|$ROOT|g" $ROOT/tests/fixtures/diff-document.txt)" $OUT
# Mermaid fences in a Markdown document: drawn, or saying why not.
mkdir -p $PRIVATE/mermaid
cp $ROOT/tests/fixtures/diagrams.md $PRIVATE/mermaid/
expect mermaid 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed "s|@DIR@|$PRIVATE/mermaid|g" $ROOT/tests/fixtures/mermaid.txt)" $OUT
# The file tree's changes to files, undone; files dropped in from "the Finder".
mkdir -p $PRIVATE/file-tree/top/src $PRIVATE/file-tree/finder
print one > $PRIVATE/file-tree/top/a.txt
print png > $PRIVATE/file-tree/finder/pic.png
expect file-tree 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed -e "s|@DIR@|$PRIVATE/file-tree/top|g" -e "s|@FINDER@|$PRIVATE/file-tree/finder|g" $ROOT/tests/fixtures/file-tree.txt)" $OUT
# The Git block's changed files in their folders.
GT=$PRIVATE/git-tree
mkdir -p $GT
( cd $GT && git init -q -b main && git config user.email t@example.com && git config user.name t \
  && mkdir -p src/ui src/core && printf 'a\n' > src/ui/view.swift && printf 'b\n' > src/core/model.swift \
  && printf 'c\n' > README.md && git add -A && git commit -qm First \
  && printf 'a2\n' >> src/ui/view.swift && printf 'b2\n' >> src/core/model.swift && printf 'c2\n' >> README.md )
expect git-tree 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed "s|@REPO@|$GT|g" $ROOT/tests/fixtures/git-tree.txt)" $OUT
# Tabs and sessions in a worktree of their own, made and removed.
WT=$PRIVATE/worktree
mkdir -p $WT
( cd $WT && git init -q -b main && git config user.email t@example.com && git config user.name t \
  && printf 'one\n' > a.txt && git add -A && git commit -qm First )
expect worktree 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(sed "s|@REPO@|$WT|g" $ROOT/tests/fixtures/worktree.txt)" $OUT
# The Tasks block: its own sleep found under the terminal, read, and quit.
expect tasks 'ui-probe: all passed' $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/tasks.txt)" $OUT
# The canvas block: a drawing from its file, saved as drawn, following the disk; a new one.
CV=$PRIVATE/canvas
mkdir -p $CV
cp $ROOT/tests/fixtures/sketch.excalidraw $CV/
expect canvas 'ui-probe: all passed' $LIBERTTY --ui-probe "$(sed -e "s|@DIR@|$CV|g" -e "s|@DATA@|$PRIVATE/jobs/canvas|g" $ROOT/tests/fixtures/canvas.txt)" $OUT
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
  "$(sed -e "s|@DATA@|$PRIVATE/jobs/plugins|g" -e "s|@CONFIG@|$PRIVATE/plugin-config|g" $ROOT/tests/fixtures/plugins.txt)" $OUT
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
# Not `python3 -m http.server`: binding, it looks up its address's host
# name, which took a fresh CI Mac 30 s (the page waited on it, and failed).
python3 -I -c 'import functools, http.server, socketserver, sys
class Server(http.server.ThreadingHTTPServer):
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = self.server_address[:2]
handler = functools.partial(http.server.SimpleHTTPRequestHandler, directory=sys.argv[2])
Server(("127.0.0.1", int(sys.argv[1])), handler).serve_forever()' $PORT $ROOT/tests/fixtures/site > /dev/null 2>&1 &
SITE_PID=$!
# Up before a page asks it (a slow start is the server's, not the browser's).
for i in {1..100}; do curl -sf -o /dev/null --max-time 1 http://127.0.0.1:$PORT/index.html && break; sleep 0.1; done
expect browser 'ui-probe: all passed' $LIBERTTY --ui-probe "$(sed "s|@SITE@|http://127.0.0.1:$PORT|g" $ROOT/tests/fixtures/browser.txt)" $OUT
mkdir -p $PRIVATE/browser-config/libertty
print 'browser-automation = true' > $PRIVATE/browser-config/libertty/config
settle
SERIAL=1
expect browser-automation 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/browser-config $LIBERTTY --ui-probe \
  "$(sed -e "s|@SITE@|http://127.0.0.1:$PORT|g" -e "s|@HOST@|127.0.0.1:$PORT|g" -e "s|@OUT@|$OUT|g" $ROOT/tests/fixtures/browser-automation.txt)" $OUT --persist
SERIAL=0
kill $SITE_PID 2>/dev/null
# Park Pane / Unpark Pane.
expect park 'ui-probe: all passed' $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/park.txt)" $OUT
# Workspaces: named sets of tabs in a window.
expect workspaces 'ui-probe: all passed' $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/workspaces.txt)" $OUT
# Panes: zoomed navigation, Redo of a close, two siblings ending at once.
expect splits 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/splits.txt)" $OUT
# The system is told where the cursor is after it moves (output, a split, the window dragged):
# its input-source indicator stayed where the pane took the keyboard.
expect caret 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/caret.txt)" $OUT
# A pane's header shows Close; the other buttons come in with the pointer.
expect pane-header 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/pane-header.txt)" $OUT
# Float Pane: a live card in the split's corner.
expect float 'ui-probe: all passed' $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/float.txt)" $OUT
# Key sequences: a prefix key waits for the next key, and goes to the program if that isn't one of its own.
mkdir -p $PRIVATE/sequence-config/libertty
print -r -- 'keybind = ctrl+b>v=new_split:right
keybind = ctrl+b>ctrl+b=text:\x02
keybind = cmd+k>cmd+u=new_split:down' > $PRIVATE/sequence-config/libertty/config
expect key-sequence 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/sequence-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/key-sequence.txt)" $OUT
# Which-key hints: after a sequence's first key, the keys that can follow and what they do.
mkdir -p $PRIVATE/key-hints-config/libertty
print -r -- 'keybind = ctrl+b>v=new_split:right
keybind = ctrl+b>c=new_tab' > $PRIVATE/key-hints-config/libertty/config
expect key-hints 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/key-hints-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/key-hints.txt)" $OUT
# Copy mode: a cursor of its own through the screen and the scrollback, selecting and copying; no key reaches the program.
expect copy-mode 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/copy-mode.txt)" $OUT
# Hint mode: labels on the links, paths, hashes and addresses on screen; a label opens or copies one.
expect hints 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/hints.txt)" $OUT
# cursor-click-to-move: a click in the command being typed moves the shell's cursor there (wide characters too).
expect click-to-move 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/click-to-move.txt)" $OUT
# The tags over a pane (a link's address, a headerless split's name) read on their ground, light or dark.
mkdir -p $PRIVATE/tags-config/libertty
print -r -- 'pane-headers = never' > $PRIVATE/tags-config/libertty/config
expect pane-tags 'ui-probe: all passed' env XDG_CONFIG_HOME=$PRIVATE/tags-config \
  $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/pane-tags.txt)" $OUT
# liberttyd keeps the window layout the app gives it, across a takeover.
expect layout-store 'layout-store: all passed' $LIBERTTY --layout-store-probe
# +wait --until prompt|idle, +capture --ansi|--html, +events (Tern's wait / capture / events).
expect cli-wait 'cli-wait: all passed' zsh $ROOT/tests/cli-wait-test.sh $LIBERTTY
# +daemon, +clients, completion, exit statuses, remote-control (a config of its own: it reads remote-control).
expect cli-admin 'cli-admin: all passed' env XDG_CONFIG_HOME=$PRIVATE/empty-config zsh $ROOT/tests/cli-admin-test.sh $LIBERTTY
# libertty +hosts: the hosts you keep, and check connecting to one (fake-ssh).
expect hosts 'hosts: all passed' zsh $ROOT/tests/hosts-test.sh $LIBERTTY
# libertty +terminfo: xterm-ghostty's terminfo on a host you ssh to (a stand-in ssh), and the ssh that keeps it.
expect terminfo 'terminfo: all passed' zsh $ROOT/tests/terminfo-test.sh $LIBERTTY
expect send-key 'send-key: all passed' zsh $ROOT/tests/send-key-test.sh $LIBERTTY
expect import-ghostty 'import-ghostty: all passed' zsh $ROOT/tests/import-ghostty-test.sh $LIBERTTY

# The benches last, alone (everything else done): they take every core
# they get, starving whatever runs beside them, and their numbers mean
# something only on a quiet machine.
settle
SERIAL=1

# A stuck window holds nobody up: timed against the same flood alone, so
# with the benches, on a quiet machine (beside other checks the two floods
# ran under different loads, and CI's three cores made it flaky).
expect slow-client 'slow-client: all passed' $LIBERTTY --slow-client-probe

# Big paste: every byte arrives, through a full pty (EAGAIN) and through liberttyd
expect paste-local 'read 2000000 ' $LIBERTTY --paste-probe
expect paste-liberttyd 'read 2000000 ' $LIBERTTY --paste-probe --persist

# Throughput, end to end (no window), both paths
expect throughput-local 'local pty: [0-9]+ MB/s' $LIBERTTY --session-bench $ROOT/bench/payloads/dense_cells.bin --mb 100
expect throughput-liberttyd 'via liberttyd: [0-9]+ MB/s' $LIBERTTY --session-bench $ROOT/bench/payloads/dense_cells.bin --mb 100 --persist
settle
grep -hE 'MB/s' $OUT/throughput-*.log | sed 's/^/      /'

# Every check's result, in the suite's order.
for name in $ORDER; do
  result=$(cat $PRIVATE/jobs/$name/result 2>/dev/null || echo "FAIL  $name: didn't finish")
  [[ $result == ok* ]] || { (( failures++ )); echo "$result"; }
done
retried=$(cat $PRIVATE/jobs/*/result 2>/dev/null | grep -c "passed on retry")
(( retried )) && echo "$retried passed only on a retry:" && grep -h "passed on retry" $PRIVATE/jobs/*/result
echo "${#ORDER} checks"
(( failures == 0 )) && echo "all passed" || echo "$failures failed"
exit $(( failures > 0 ))
