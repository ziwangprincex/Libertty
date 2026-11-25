#!/bin/zsh
# libertty +daemon, +clients, +completions/+complete, the exit statuses,
# +send --enter and remote-control, against a private liberttyd (tests/run.sh
# sets LIBERTTY_DAEMON_SOCKET and LIBERTTY_DAEMON_LOG): prints
# "cli-admin: all passed" or what failed.
#   tests/cli-admin-test.sh LIBERTTY_BINARY

# Never the user's own liberttyd: run alone, a different build would take
# their sessions over. tests/run.sh sets a private one.
[[ -n ${LIBERTTY_DAEMON_SOCKET:-} && -n ${LIBERTTY_DATA_DIR:-} ]] \
  || { echo "set a private LIBERTTY_DAEMON_SOCKET and LIBERTTY_DATA_DIR (tests/run.sh does)"; exit 2; }
set -u
L=$1
T=$(mktemp -d)
trap 'rm -rf $T' EXIT
fails=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; (( fails++ )); }
# A value from +daemon status --json.
field() { $L +daemon status --json | python3 -c "import json,sys; print(json.load(sys.stdin).get('$1', ''))"; }

# Nothing running yet.
$L +daemon status > $T/out 2>&1; r=$?
(( r == 4 )) && grep -q "isn't running" $T/out && ok "status without liberttyd: says so, 4" || bad "status without liberttyd: $r $(cat $T/out)"
$L +daemon stop > $T/out 2>&1 && grep -q "isn't running" $T/out && ok "stop without liberttyd: nothing to do" || bad "stop without liberttyd"
$L +capture deadbeef > /dev/null 2>&1; r=$?; (( r == 4 )) && ok "a session command without liberttyd: 4" || bad "unreachable: $r"
$L +wait deadbeef --timeout 2 > /dev/null 2>&1; r=$?; (( r == 4 )) && ok "+wait without liberttyd: 4" || bad "+wait unreachable: $r"

ID=$($L +new-session --cwd /tmp)
$L +wait $ID --until prompt --timeout 20

# No such session: 3.
for c in "+capture nosuch" "+send nosuch hi" "+send-key nosuch enter" "+wait nosuch --timeout 2" "+kill-session nosuch" \
         "+rename-session nosuch name"; do
  $L ${=c} > /dev/null 2>&1; r=$?
  (( r == 3 )) && ok "$c: 3" || bad "$c: $r"
done
$L +nosuch > /dev/null 2>&1; r=$?; (( r == 2 )) && ok "an unknown command: 2" || bad "unknown command: $r"

# +daemon status
$L +daemon status > $T/status
grep -q "sessions  1 (" $T/status && grep -q "^liberttyd [0-9]" $T/status && ok "status: pid, build, sessions" || bad "status: $(cat $T/status)"
log=$(field log)
[[ ${log:A} == ${LIBERTTY_DAEMON_LOG:A} ]] && ok "status: its log is the one it writes" || bad "status log: $log (wanted $LIBERTTY_DAEMON_LOG)"
[[ $(field socket) == $LIBERTTY_DAEMON_SOCKET ]] && ok "status: its socket" || bad "status socket: $(field socket)"
# Which login it runs in: one left behind by an ssh login into this Mac would
# start local panes outside the user's own login, so it says which it is
# (SecuritySession). Whether this run is that login depends on how the suite
# was started, so only the row itself is checked.
grep -q "^  login     " $T/status && ok "status: the login it runs in" || bad "status login: $(cat $T/status)"

# +clients: an +events listener and a +wait waiter, by what they do.
perl -e 'alarm 8; exec @ARGV' $L +events > /dev/null 2>&1 &
EV=$!
perl -e 'alarm 8; exec @ARGV' $L +wait $ID --until idle=60000 > /dev/null 2>&1 &
WT=$!
sleep 1
$L +clients > $T/clients
grep -q "libertty +events.*follows events" $T/clients && grep -q "libertty +wait.*waits on $ID" $T/clients \
  && ok "+clients: who follows events, who waits" || bad "+clients: $(cat $T/clients)"
$L +clients --json | python3 -c '
import json, sys
c = json.load(sys.stdin)
assert any(x["listening"] for x in c), c
assert all(x["pid"] > 0 for x in c), c' && ok "+clients --json" || bad "+clients --json"
(( $(field clients) >= 2 )) && ok "status counts them" || bad "status clients: $(field clients)"
kill $EV $WT 2> /dev/null
wait $EV $WT 2> /dev/null

# +daemon logs, and -f following what's added.
$L +daemon logs --lines 3 > $T/logs
(( $(wc -l < $T/logs) <= 3 )) && grep -q "liberttyd\[" $T/logs && ok "logs --lines 3" || bad "logs: $(cat $T/logs)"
perl -e 'alarm 5; exec @ARGV' $L +daemon logs -f --lines 0 > $T/follow 2>&1 &
FL=$!
sleep 1
ID2=$($L +new-session --cwd /tmp -e sleep 30)
sleep 2
grep -q "session $ID2 started" $T/follow && ok "logs -f: what's added" || bad "logs -f: $(cat $T/follow)"
$L +kill-session $ID2
wait $FL 2> /dev/null

# stop: not with sessions, unless --force; --if-idle leaves it be.
sleep 0.5
$L +daemon stop > $T/out 2>&1; r=$?
(( r == 1 )) && grep -q "has 1 session" $T/out && ok "stop refuses with a session" || bad "stop with a session: $r $(cat $T/out)"
$L +daemon stop --if-idle > $T/out 2>&1; r=$?
(( r == 0 )) && grep -q "left running" $T/out && $L +daemon status > /dev/null && ok "stop --if-idle leaves it running" \
  || bad "stop --if-idle: $r $(cat $T/out)"

# restart: another liberttyd, the same session, its shell still the one it was.
$L +send $ID 'export MARK=kept-across\n'
$L +wait $ID --until prompt --timeout 5
old=$(field pid)
$L +daemon restart > $T/out 2>&1; r=$?
new=$(field pid)
(( r == 0 )) && grep -q "1 session kept" $T/out && [[ -n $new && $new != $old ]] && ok "restart: liberttyd $old → $new" \
  || bad "restart: $r $(cat $T/out) ($old → $new)"
$L +send $ID 'echo MARK-IS-$MARK\n'
$L +wait $ID --until prompt --timeout 5
$L +capture $ID | grep -q "MARK-IS-kept-across" && ok "restart: the shell kept running" || bad "restart: the shell's gone"

# restart while windows make sessions: one made mid-handover would end with
# the old liberttyd, so it's refused (the app asks the newer one). Sessions
# enough for the handover to take a moment, then windows that ask for one
# the moment it begins: none they're given is gone after it.
python3 -I - $LIBERTTY_DAEMON_SOCKET $LIBERTTY_DAEMON_LOG $L > $T/made <<'EOF'
import json, os, socket, struct, subprocess, sys, time, uuid
path, log, libertty = sys.argv[1:4]
def window():
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    s.connect(path)
    s.settimeout(20)
    return s
def create(s):
    sid = uuid.uuid4().hex[:8]
    body = json.dumps({"id": sid, "executable": "/bin/sleep", "arguments": ["sleep", "300"], "environment": {},
                       "workingDirectory": "/tmp", "cols": 80, "rows": 24, "widthPx": 0, "heightPx": 0,
                       "scrollback": 1000}).encode()
    s.sendall(struct.pack("<I", len(body) + 1) + bytes([2]) + body)
    return sid
def answer(s):
    try:
        head = s.recv(5, socket.MSG_WAITALL)
        if len(head) < 5: return None, {}
        n = struct.unpack("<I", head[:4])[0] - 1
        body = s.recv(n, socket.MSG_WAITALL) if n else b""
        return head[4], json.loads(body) if head[4] == 105 else {}
    except OSError:
        return None, {}
before = []
for _ in range(60):
    s = window()
    before.append(create(s))
    answer(s)
    s.close()
late = [window() for _ in range(30)]
seen = os.path.getsize(log)
restart = subprocess.Popen([libertty, "+daemon", "restart"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
deadline = time.time() + 15
while time.time() < deadline:
    with open(log, "rb") as f:
        f.seek(seen)
        if b"] handing " in f.read(): break
    time.sleep(0.001)
asked = [create(s) for s in late]
made, refused = [], 0
for s, sid in zip(late, asked):
    kind, result = answer(s)
    if kind == 102: made.append(sid)
    if result.get("error") == "handing over": refused += 1
restart.wait()
print(" ".join(made))
print(refused)
print(" ".join(before))
EOF
made=(${=$(sed -n 1p $T/made)})
refused=$(sed -n 2p $T/made)
listed=(${=$($L +list-sessions --json | python3 -I -c "import json,sys; print(' '.join(s['id'] for s in json.load(sys.stdin)))")})
lost=(${made:|listed})
(( ${#lost} == 0 && ${#made} + refused > 0 )) && ok "restart mid-making: none made is gone (${#made} made, $refused refused)" \
  || bad "restart mid-making: ${#lost} of ${#made} made mid-handover are gone ($refused refused)"
for s in $made ${=$(sed -n 3p $T/made)}; do $L +kill-session $s > /dev/null 2>&1; done

# +send --enter: the text, then Return as its own key.
$L +send $ID --enter 'echo SENT-$((40+2))'
$L +wait $ID --until prompt --timeout 5
$L +capture $ID | grep -q "^SENT-42" && ok "+send --enter" || bad "+send --enter: $($L +capture $ID | tail -3)"

# remote-control = false: reading yes, driving no, and it stays false.
mkdir -p $T/config/libertty
echo "remote-control = false" > $T/config/libertty/config
off() { XDG_CONFIG_HOME=$T/config "$@"; }
off $L +send $ID hi > $T/out 2>&1; r=$?
(( r == 1 )) && grep -q "remote-control" $T/out && ok "remote-control = false: +send refused" || bad "remote-control +send: $r $(cat $T/out)"
off $L +capture $ID > /dev/null && ok "remote-control = false: +capture still reads" || bad "remote-control +capture"
off $L +daemon stop --force > /dev/null 2>&1; r=$?
(( r == 1 )) && $L +daemon status > /dev/null && ok "remote-control = false: +daemon stop refused" || bad "remote-control stop: $r"
off $L +set remote-control=true > /dev/null 2>&1; r1=$?
off $L +unset remote-control > /dev/null 2>&1; r2=$?
(( r1 == 1 && r2 == 1 )) && grep -q "remote-control = false" $T/config/libertty/config \
  && ok "+set and +unset don't turn it back on" || bad "remote-control set/unset: $r1 $r2"
LIBERTTY_SESSION=$ID off $L +rename-session "my task" && ok "remote-control = false: an agent names its own session" \
  || bad "remote-control: own rename"

# Completion: what +complete says, and each shell's script running it.
mkdir -p $T/bin
printf '#!/bin/sh\nexec %s "$@"\n' $L > $T/bin/libertty
chmod +x $T/bin/libertty
$L +complete zsh -- +da | grep -q $'^+daemon\t' && ok "+complete: a command, with what it does" || bad "+complete command"
$L +complete bash -- +capture "" | grep -qx $ID && ok "+complete: session IDs" || bad "+complete sessions"
$L +complete zsh -- +set window-theme= | grep -q "^window-theme=dark" && ok "+complete: a setting's values" || bad "+complete values"
zsh -n <($L +completions zsh) && bash -n <($L +completions bash) && ok "the zsh and bash scripts parse" || bad "scripts' syntax"
[[ -n $($L +completions fish) ]] && ok "+completions fish" || bad "+completions fish"
# zsh's function with a compadd that prints what it's given (zsh's scoping lets it see the caller's arrays).
PATH=$T/bin:$PATH zsh -f -c "
  compadd() { print -rl -- \"\${values[@]}\"; }
  _files() { print FILES; }
  words=(libertty +daemon ''); CURRENT=3
  source <(libertty +completions zsh)
" > $T/zsh
grep -qx restart $T/zsh && grep -qx status $T/zsh && ok "zsh: _libertty completes +daemon's words" || bad "zsh function: $(cat $T/zsh)"
PATH=$T/bin:$PATH zsh -f -c "
  compadd() { print -rl -- \"\${values[@]}\"; }
  _files() { print FILES; }
  words=(libertty +open ''); CURRENT=3
  source <(libertty +completions zsh)
" > $T/zsh
grep -qx FILES $T/zsh && ok "zsh: files where a file goes" || bad "zsh files: $(cat $T/zsh)"
# bash's, as readline would call it: the word after = is all bash replaces
# (macOS's bash 3.2 can't source <(…)).
PATH=$T/bin:$PATH bash --norc --noprofile -c '
  eval "$(libertty +completions bash)"
  COMP_LINE="libertty +set window-theme="; COMP_POINT=${#COMP_LINE}
  COMP_WORDS=(libertty +set window-theme =); COMP_CWORD=3
  _libertty_complete; printf "%s\n" "${COMPREPLY[@]}"
  echo ---
  COMP_LINE="libertty +action new_split:ri"; COMP_POINT=${#COMP_LINE}
  COMP_WORDS=(libertty +action new_split : ri); COMP_CWORD=4
  _libertty_complete; printf "%s\n" "${COMPREPLY[@]}"
' > $T/bash
grep -qx "=dark" $T/bash && grep -qx "right" $T/bash && ! grep -qx "=light-x" $T/bash && ok "bash: completes past = and :" \
  || bad "bash: $(cat $T/bash)"

# Libertty's shells load it by themselves: zsh for the compinit in .zshrc
# (its folder last on fpath), bash unless something completes libertty already.
# (What they print first, the OSC 7 folder report, is cut off.)
ROOT=${0:A:h:h}
mkdir -p $T/home $T/home2
asked() { local r; r=$("$@" 2> /dev/null); print -r -- "${r##*$'\a'}"; }
zshrc() { PATH=$T/bin:$PATH HOME=$1 ZDOTDIR=$ROOT/Resources/shell-integration/zsh zsh -i -c 'print -r -- ${_comps[libertty]-none}'; }
bashrc() { PATH=$2 HOME=$1 bash --rcfile $ROOT/Resources/shell-integration/bash/libertty.bash -i -c 'complete -p libertty'; }
print 'autoload -Uz compinit; compinit -u -d $HOME/.zcompdump' > $T/home/.zshrc
r=$(asked zshrc $T/home)
[[ $r == _libertty ]] && ok "zsh integration: libertty completes" || bad "zsh integration: $r"
print 'autoload -Uz compinit; compinit -u -d $HOME/.zcompdump; _mine() { :; }; compdef _mine libertty' > $T/home2/.zshrc
r=$(asked zshrc $T/home2)
[[ $r == _mine ]] && ok "zsh integration: yours wins" || bad "zsh integration, the user's own: $r"
r=$(asked bashrc $T/home $T/bin:/usr/bin:/bin)
[[ $r == *_libertty_complete* ]] && ok "bash integration: libertty completes" || bad "bash integration: $r"
print '_mine() { :; }; complete -F _mine libertty' > $T/home2/.bashrc
r=$(asked bashrc $T/home2 $T/bin:/usr/bin:/bin)
[[ $r == *_mine* ]] && ok "bash integration: yours wins" || bad "bash integration, the user's own: $r"
r=$(asked bashrc $T/home /usr/bin:/bin)
[[ -z $r ]] && ok "bash integration: none without libertty (a remote host)" || bad "bash without libertty: $r"

$L +kill-session $ID
(( fails == 0 )) && echo "cli-admin: all passed" || echo "cli-admin: $fails failed"
