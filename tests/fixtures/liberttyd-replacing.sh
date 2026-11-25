#!/bin/sh
# Stands in for a liberttyd being replaced (tests/fixtures/liberttyd-replacing.txt):
# the probe's own liberttyd goes, then for 1.5 s its socket is there with
# nothing listening and its lock is held — as between an older liberttyd and
# the newer one taking its sessions over — and then a new liberttyd serves.
# Returns at once; the rest happens in the background.
S=$LIBERTTY_DAEMON_SOCKET
pid=$(lsof -t "$S" 2> /dev/null | head -1)
[ -n "$pid" ] || { echo "no liberttyd on $S"; exit 1; }
liberttyd=$(lsof -a -p "$pid" -d txt -Fn 2> /dev/null | sed -n "s/^n//p" | head -1)  # its executable
kill -TERM "$pid"
while kill -0 "$pid" 2> /dev/null; do sleep 0.05; done
python3 -I - "$S" "$liberttyd" << 'EOF'
import fcntl, os, socket, sys, time
path, liberttyd = sys.argv[1], sys.argv[2]
lock = os.open(path + ".lock", os.O_RDWR | os.O_CREAT, 0o600)
fcntl.flock(lock, fcntl.LOCK_EX)
# A socket file nobody listens on: connecting is refused.
s = socket.socket(socket.AF_UNIX)
s.bind(path)
s.close()
if os.fork() == 0:
    os.setsid()
    time.sleep(1.5)
    os.close(lock)
    os.execv(liberttyd, ["liberttyd"])
EOF
