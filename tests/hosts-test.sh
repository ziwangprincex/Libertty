#!/bin/zsh
# libertty +hosts against tests/fixtures/fake-ssh (a "host" that is a folder
# here, with its own home, liberttyd and terminfo): prints "hosts: all
# passed" or what failed.
#   tests/hosts-test.sh LIBERTTY_BINARY
set -u
L=$1
T=$(mktemp -d)
trap 'LIBERTTY_DAEMON_SOCKET=$T/remote/liberttyd.sock $L +daemon stop --force > /dev/null 2>&1; rm -rf $T' EXIT
fails=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; (( fails++ )); }
mkdir -p $T/remote $T/data
export LIBERTTY_SSH=${0:A:h}/fixtures/fake-ssh FAKE_SSH_HOME=$T/remote-home FAKE_SSH_SOCKET=$T/remote/liberttyd.sock \
  FAKE_SSH_LOG=$T/remote.log FAKE_SSH_TERMINFO=$T/remote-home/terminfo LIBERTTY_DATA_DIR=$T/data

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

(( fails == 0 )) && echo "hosts: all passed" || echo "hosts: $fails failed"
