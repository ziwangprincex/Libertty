#!/bin/zsh
# liberttyd with many windows: it raises its descriptor limit (macOS starts
# a process with 256, some 60 sessions' worth), and one that runs out
# anyway waits for a descriptor instead of exiting with every session.
# Against a private liberttyd (tests/run.sh sets LIBERTTY_DAEMON_SOCKET and
# LIBERTTY_DAEMON_LOG): prints "daemon-limits: all passed" or what failed.
#   tests/daemon-limits-test.sh LIBERTTY_BINARY

# Never the user's own liberttyd: run alone, a different build would take
# their sessions over. tests/run.sh sets a private one.
[[ -n ${LIBERTTY_DAEMON_SOCKET:-} && -n ${LIBERTTY_DATA_DIR:-} ]] \
  || { echo "set a private LIBERTTY_DAEMON_SOCKET and LIBERTTY_DATA_DIR (tests/run.sh does)"; exit 2; }
set -u
L=$1
D=${L:h}/liberttyd
fails=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; (( fails++ )); }
pid() { $L +daemon status --json 2> /dev/null | python3 -I -c "import json,sys; print(json.load(sys.stdin)['pid'])" 2> /dev/null; }
# liberttyd, started here (not by a command) with the descriptor limits given ("-S 64": the soft one).
start() { (ulimit $1 -n $2; exec $D >> $LIBERTTY_DAEMON_LOG 2>&1) & local i; for i in {1..100}; do [[ -n $(pid) ]] && return; sleep 0.1; done; }
# COUNT connections that each say hello, held open HOLD seconds: how many were welcomed.
windows() {
  python3 -I - $LIBERTTY_DAEMON_SOCKET $1 $2 <<'EOF'
import json, socket, struct, sys, time
path, count, hold = sys.argv[1], int(sys.argv[2]), float(sys.argv[3])
hello = json.dumps({"version": 1}).encode()
held = []
for _ in range(count):
    for _ in range(200):
        s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        try:
            s.connect(path)
            break
        except OSError:
            s.close()
            time.sleep(0.01)
    s.sendall(struct.pack("<I", len(hello) + 1) + bytes([1]) + hello)
    held.append(s)
deadline = time.time() + 5
welcomed = 0
for s in held:
    s.settimeout(max(0.05, deadline - time.time()))
    try:
        head = s.recv(5, socket.MSG_WAITALL)
        welcomed += len(head) == 5 and head[4] == 101
    except OSError:
        pass
time.sleep(hold)
print(welcomed)
EOF
}

# A soft limit of 64: raised, so 120 windows all get an answer.
start -S 64
first=$(pid)
n=$(windows 120 0)
(( n == 120 )) && [[ $(pid) == $first ]] && ok "120 windows under a soft limit of 64: all answered" \
  || bad "120 windows under a soft limit of 64: $n answered, liberttyd $first → $(pid)"
$L +daemon stop --force > /dev/null 2>&1

# Out of descriptors for good (40, hard and soft): the windows past it wait,
# and liberttyd stays, its session with it.
start -HS 40
first=$(pid)
ID=$($L +new-session --cwd /tmp -e sleep 300)
n=$(windows 60 1)
(( n > 0 && n < 60 )) && ok "out of descriptors: $n of 60 windows answered" || bad "out of descriptors: $n of 60 answered"
again=$(pid)
[[ -n $again && $again == $first ]] && ok "liberttyd stayed, and answers once they're gone" || bad "liberttyd $first → ${again:-gone}"
$L +list-sessions | grep -q $ID && ok "its session lives on" || bad "the session is gone: $($L +list-sessions)"
grep -q "waiting for a descriptor" $LIBERTTY_DAEMON_LOG && ok "the log says why it waited" || bad "nothing in the log"
$L +daemon stop --force > /dev/null 2>&1

(( fails == 0 )) && echo "daemon-limits: all passed"
exit $(( fails > 0 ))
