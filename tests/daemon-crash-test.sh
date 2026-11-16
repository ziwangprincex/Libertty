#!/bin/zsh
# liberttyd going away without a word (a crash) doesn't end its sessions: its
# guardian gives them to a new one, the shells never notice. Unless it keeps
# crashing; and a `kill` still ends them as it always did. Against a private
# liberttyd (tests/run.sh sets LIBERTTY_DAEMON_SOCKET and LIBERTTY_DAEMON_LOG):
# prints "daemon-crash: all passed" or what failed.
#   tests/daemon-crash-test.sh LIBERTTY_BINARY
set -u
L=$1
fails=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; (( fails++ )); }
pid() { $L +daemon status --json 2> /dev/null | python3 -I -c "import json,sys; print(json.load(sys.stdin)['pid'])" 2> /dev/null; }
shell() { $L +list-sessions --json | python3 -I -c "import json,sys; print(next(s['pid'] for s in json.load(sys.stdin) if s['id'] == '$1'))"; }
# Until liberttyd answers with another pid than $1 (up to 10 s).
replaced() { local i; for i in {1..100}; do local p=$(pid); [[ -n $p && $p != $1 ]] && return 0; sleep 0.1; done; return 1; }
gone() { local i; for i in {1..100}; do kill -0 $1 2> /dev/null || return 0; sleep 0.1; done; return 1; }

ID=$($L +new-session --cwd /tmp)
$L +wait $ID --until prompt --timeout 20
$L +send $ID 'export MARK=kept-across\n'
$L +wait $ID --until prompt --timeout 5
SH=$(shell $ID)
grep -q "guardian liberttyd\[[0-9]*\] holds" $LIBERTTY_DAEMON_LOG && ok "a guardian holds the session" || bad "no guardian: $(tail -3 $LIBERTTY_DAEMON_LOG)"

# A crash: the same shell, in a new liberttyd.
old=$(pid)
kill -SEGV $old
replaced $old && ok "after a crash, a new liberttyd: $old → $(pid)" || bad "after a crash: no new liberttyd"
kill -0 $SH 2> /dev/null && [[ $(shell $ID) == $SH ]] && ok "the shell lived on" || bad "the shell is gone"
$L +send $ID 'echo MARK-IS-$MARK\n'
$L +wait $ID --until prompt --timeout 10
$L +capture $ID | grep -q "MARK-IS-kept-across" && ok "the shell kept its state" || bad "the shell's state: $($L +capture $ID | tail -3)"

# Crashing again and again (here 3 more times in a minute): it gives up.
for n in 2 3; do
  old=$(pid)
  kill -TRAP $old
  replaced $old || bad "crash $n: no new liberttyd"
done
kill -KILL $(pid)
gone $SH && ok "the 4th crash in a minute: given up, the session ended" || bad "4 crashes: the session lives on"
grep -q "giving up" $LIBERTTY_DAEMON_LOG && ok "the log says why" || bad "nothing in the log"

# kill (SIGTERM) ends liberttyd and its sessions, as it always did.
ID=$($L +new-session --cwd /tmp -e sleep 300)
sleep 0.5
SH=$(shell $ID)
kill -TERM $(pid)
gone $SH && [[ -z $(pid) ]] && ok "SIGTERM: liberttyd and its session ended" || bad "SIGTERM: something lives on"

(( fails == 0 )) && echo "daemon-crash: all passed"
exit $(( fails > 0 ))
