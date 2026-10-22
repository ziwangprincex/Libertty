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
# A failed build must stop here: an old binary wouldn't know the probe flags.
swift build -c $CONFIG > $ROOT/build/test-build.log 2>&1 || { grep -E "error:" $ROOT/build/test-build.log; exit 1; }
BIN=$(swift build -c $CONFIG --show-bin-path)
LIBERTTY=$BIN/Libertty
OUT=$ROOT/build/test-output
mkdir -p $OUT
# A private liberttyd, so tests never touch the user's sessions.
PRIVATE=$(mktemp -d)
export LIBERTTY_DAEMON_SOCKET=$PRIVATE/liberttyd.sock LIBERTTY_DAEMON_LOG=$PRIVATE/liberttyd.log
# What blocks make (drawings, profiles, plugin storage) goes here too.
export LIBERTTY_DATA_DIR=$PRIVATE
failures=0

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
check snapshot-sprites $LIBERTTY --snapshot $OUT/sprites.png --cols 64 --rows 6 -- sh $ROOT/tests/fixtures/sprites.sh
check snapshot-ligatures $LIBERTTY --snapshot $OUT/ligatures.png --cols 64 --rows 4 -- 'printf "a -> b => c != d === e !== f <= g |> h <!-- -->\nplain words (just text)\n"'
# Smooth scrolling half a row into the history: the row below the viewport peeks in.
check snapshot-smooth-scroll $LIBERTTY --snapshot $OUT/smooth-scroll.png --cols 40 --rows 6 --scroll-up 10 --offset 50 -- \
  'i=1; while [ $i -le 40 ]; do printf "\033[3%dmline %02d\033[0m \033[4%dm bg %02d \033[0m\n" $((i % 7 + 1)) $i $((i % 7 + 1)) $i; i=$((i+1)); done'

# Documents and settings
expect markdown '<table>' $LIBERTTY +render-markdown $ROOT/tests/fixtures/markdown.md
# Two files, each once, with their counts.
expect diff-render '^(.*main\.swift.*\+4</span> <span class="del">−3.*notes\.md.*\+1</span> <span class="del">−0)' $LIBERTTY +render-diff $ROOT/tests/fixtures/sample.diff
expect config-validates 'ok$' $LIBERTTY +validate-config --config-file /dev/null
expect config-get 'false|true' $LIBERTTY +get window-vsync
expect ligature-config 'all 8 right' $LIBERTTY --ligature-config-probe

# Links, selection, shell integration
expect links-url 'text https://example.com/a_\(b\) 0:4-28' $LIBERTTY --link-probe 'printf "see https://example.com/a_(b), ok.\n"'
expect links-osc8 'osc8 https://libertty.dev/docs' $LIBERTTY --link-probe 'printf "\033]8;;https://libertty.dev/docs\033\\\\here\033]8;;\033\\\\\n"'
expect links-path 'CLI.swift line 42 col 7' $LIBERTTY --link-probe 'printf "Sources/Libertty/App/CLI.swift:42:7: error\n"'
expect selection-autoscroll 'drag up \+ 3 ticks: line2' $LIBERTTY --selection-probe
expect selection-extend 'shift-click extend: line28 \| line29 \| line' $LIBERTTY --selection-probe
expect zsh-command-finished 'finished: printf .* exit=1' $LIBERTTY --command-probe zsh
expect bash-command-finished 'finished: sleep 0.3; echo .a;b. >/dev/null exit=0' $LIBERTTY --command-probe bash

# Last command's output (OSC 133 marks) and the scrollbar model
expect output-zsh '^\[out one' $LIBERTTY --output-probe zsh
expect output-bash '^out three\]' $LIBERTTY --output-probe bash
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
  if ! LIBERTTY_APP=$TESTAPP scripts/bundle.sh $CONFIG > $OUT/bundle.log 2>&1; then
    echo "FAIL  bundle (see $OUT/bundle.log)"
    (( failures++ ))
  fi
fi
if [[ -d $TESTAPP/Contents/Resources/terminfo && ! $APPBIN -ot $LIBERTTY ]]; then
  expect term-ghostty 'T=xterm-ghostty C=256' $APPBIN --shell-probe zsh 'echo "T=$TERM C=$(tput colors)"'
  expect ssh-env-zsh 'ssh is a shell function' $APPBIN --shell-probe zsh 'type ssh'
  expect ssh-env-bash 'ssh is a function' $APPBIN --shell-probe bash 'type ssh'
fi

# A remote host: tests/fixtures/fake-ssh stands in for ssh and runs the
# "remote" side here, with its own home, liberttyd and terminfo under $PRIVATE.
expect remote-host 'remote-probe: all passed' env LIBERTTY_SSH=$ROOT/tests/fixtures/fake-ssh \
  FAKE_SSH_HOME=$PRIVATE/remote-home FAKE_SSH_SOCKET=$PRIVATE/remote/liberttyd.sock FAKE_SSH_LOG=$PRIVATE/remote.log \
  FAKE_SSH_TERMINFO=$PRIVATE/remote-home/terminfo FAKE_SSH_DOWN=$PRIVATE/remote-down $LIBERTTY --remote-probe liberttytest

# Web Access: the page, its secret, a pane's screen and typing, over a
# real WebSocket on a private port (this Mac only).
expect web-access 'web-probe: all passed' env LIBERTTY_WEB_PORT=$(( 17000 + RANDOM % 900 )) $LIBERTTY --web-probe

# Sessions (liberttyd)
ID=$($LIBERTTY +new-session -e 'printf "persisted\n"; sleep 30')
sleep 0.5
expect session-list "$ID" $LIBERTTY +list-sessions
expect session-capture 'persisted' $LIBERTTY +capture $ID
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
expect editor 'ui-probe: all passed' $LIBERTTY --ui-probe "$(sed "s|@DIR@|$ED|g" $ROOT/tests/fixtures/editor.txt)" $OUT
# The Git block: stage a hunk, commit, history, a branch, a stash — through its page.
GB=$PRIVATE/gitblock
mkdir -p $GB
( cd $GB && git init -q -b main && git config user.email t@example.com && git config user.name t \
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
# Float Pane: a live card in the split's corner.
expect float 'ui-probe: all passed' $LIBERTTY --ui-probe "$(cat $ROOT/tests/fixtures/float.txt)" $OUT
# liberttyd keeps the window layout the app gives it, across a takeover.
expect layout-store 'layout-store: all passed' $LIBERTTY --layout-store-probe
# +wait --until prompt|idle, +capture --ansi|--html, +events (Tern's wait / capture / events).
expect cli-wait 'cli-wait: all passed' zsh $ROOT/tests/cli-wait-test.sh $LIBERTTY

# Big paste: every byte arrives, through a full pty (EAGAIN) and through liberttyd
expect paste-local 'read 2000000 ' $LIBERTTY --paste-probe
expect paste-liberttyd 'read 2000000 ' $LIBERTTY --paste-probe --persist

# Throughput, end to end (no window), both paths
expect throughput-local 'local pty: [0-9]+ MB/s' $LIBERTTY --session-bench $ROOT/bench/payloads/dense_cells.bin --mb 100
expect throughput-liberttyd 'via liberttyd: [0-9]+ MB/s' $LIBERTTY --session-bench $ROOT/bench/payloads/dense_cells.bin --mb 100 --persist
grep -hE 'MB/s' $OUT/throughput-*.log | sed 's/^/      /'

(( failures == 0 )) && echo "all passed" || echo "$failures failed"
exit $(( failures > 0 ))
