#!/bin/zsh
# libertty +hosts against tests/fixtures/fake-ssh (a "host" that is a folder
# here, with its own home, liberttyd and terminfo): prints "hosts: all
# passed" or what failed.
#   tests/hosts-test.sh LIBERTTY_BINARY

# Never the user's own liberttyd: run alone, a different build would take
# their sessions over. tests/run.sh sets a private one.
[[ -n ${LIBERTTY_DAEMON_SOCKET:-} && -n ${LIBERTTY_DATA_DIR:-} ]] \
  || { echo "set a private LIBERTTY_DAEMON_SOCKET and LIBERTTY_DATA_DIR (tests/run.sh does)"; exit 2; }
set -u
L=$1
T=$(mktemp -d)
trap 'LIBERTTY_DAEMON_SOCKET=$T/remote/liberttyd.sock $L +daemon stop --force > /dev/null 2>&1; rm -rf $T' EXIT
fails=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; (( fails++ )); }
mkdir -p $T/remote $T/data
mkdir -p $T/config/libertty
export LIBERTTY_SSH=${0:A:h}/fixtures/fake-ssh FAKE_SSH_HOME=$T/remote-home FAKE_SSH_SOCKET=$T/remote/liberttyd.sock \
  FAKE_SSH_LOG=$T/remote.log FAKE_SSH_TERMINFO=$T/remote-home/terminfo LIBERTTY_DATA_DIR=$T/data \
  XDG_CONFIG_HOME=$T/config
# An agent of its own that isn't there, so a failed login never asks the real
# ssh-agent of whoever runs these checks what it holds.
echo "ssh-agent = $T/not-an-agent.sock" > $T/config/libertty/config

[[ -z $($L +hosts) ]] && ok "none kept yet" || bad "list before: $($L +hosts)"
$L +hosts add liberttytest && $L +hosts add devbox && [[ $($L +hosts) == $'liberttytest\ndevbox' ]] \
  && ok "add: in that order" || bad "add: $($L +hosts)"
[[ $($L +hosts add devbox) == *"there already"* ]] && ok "added twice: once" || bad "add twice"
$L +hosts add -oProxyCommand=x > /dev/null 2>&1; [[ $? == 2 ]] && ok "an option isn't a host (2)" || bad "option as host"
$L +hosts check liberttytest > $T/check.txt 2> $T/check.err && grep -q "connected" $T/check.txt \
  && ok "check: connected, set up there" || bad "check: $(cat $T/check.txt $T/check.err)"
[[ -x $T/remote-home/bin/liberttyd ]] && ok "…liberttyd installed there" || bad "nothing installed"
$L +hosts check unreachable > /dev/null 2>&1; [[ $? == 4 ]] && ok "check a host out of reach: 4" || bad "unreachable status"
$L +hosts remove devbox && [[ $($L +hosts) == liberttytest ]] && ok "remove" || bad "remove: $($L +hosts)"
$L +hosts remove devbox > /dev/null 2>&1; [[ $? == 3 ]] && ok "remove what isn't there: 3" || bad "remove missing"

# A failing login says plainly what it is and what fixes it, instead of
# handing ssh's own words over (SSHRecovery / SSHFailure).
cat > $T/maxstartups.txt <<'EOF'
kex_exchange_identification: Connection closed by remote host
Connection closed by 10.0.0.5 port 22
EOF
FAKE_SSH_FAIL=$T/maxstartups.txt $L +hosts check liberttytest > $T/closed.txt 2>&1
grep -q "closed it without saying a word" $T/closed.txt && grep -q "MaxStartups" $T/closed.txt \
  && ok "a host that closes at once: said in words" || bad "closed at once: $(cat $T/closed.txt)"

# Keys refused while the chosen agent isn't the one ssh-add fills: the advice
# names that agent, and never offers to load keys into the macOS agent (B1).
cat > $T/publickey.txt <<'EOF'
me@liberttytest: Permission denied (publickey,keyboard-interactive).
EOF
FAKE_SSH_FAIL=$T/publickey.txt $L +hosts check liberttytest > $T/agent.txt 2>&1
grep -q "not-an-agent.sock" $T/agent.txt && ! grep -q "ssh-add" $T/agent.txt \
  && ok "keys refused: names the agent ssh really asks" || bad "agent advice: $(cat $T/agent.txt)"
# An IdentityAgent in the host's own ssh configuration comes first, and is
# said so, since adding a key anywhere else wouldn't help.
echo "ssh-agent = 1password" > $T/config/libertty/config
FAKE_SSH_FAIL=$T/publickey.txt FAKE_SSH_IDENTITY_AGENT=$T/from-config.sock \
  $L +hosts check liberttytest > $T/config-agent.txt 2>&1
grep -q "from-config.sock" $T/config-agent.txt && grep -q "IdentityAgent" $T/config-agent.txt \
  && ok "~/.ssh/config's agent comes first" || bad "config agent: $(cat $T/config-agent.txt)"

(( fails == 0 )) && echo "hosts: all passed" || echo "hosts: $fails failed"
