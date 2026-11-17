#!/bin/zsh
# libertty +forward: what it takes, what it refuses, its exit statuses and
# its completion. The forwards themselves are the forward probe's (a stand-in
# ssh and a stand-in dev server); nothing here reaches a host or the app.
#   tests/forward-test.sh LIBERTTY_BINARY
set -u
L=$1
T=$(mktemp -d)
trap 'rm -rf $T' EXIT
fails=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; (( fails++ )); }

# usage NAME STATUS ARGS...: the status it exits with, and what it said.
usage() {
  local name=$1 want=$2; shift 2
  $L +forward "$@" > $T/out 2> $T/err
  local got=$?
  if (( got == want )); then ok "$name ($got)"; else bad "$name: $got, not $want: $(head -1 $T/err)"; fi
}

usage "no such thing to do" 2 bogus
usage "open without a target" 2 open
usage "open what isn't a port" 2 open notaport
usage "open a port out of range" 2 open 70000
usage "open a scheme it can't carry" 2 open ftp://localhost:21/
usage "share without a port" 2 share
usage "share what isn't a port" 2 share abc
usage "share port 0" 2 share 0
usage "close without an id" 2 close
usage "ls takes nothing else" 2 ls extra
usage "an option it doesn't know" 2 ls --nope

# (A port, a host:port and a URL are targets it takes: PortForwardTests
# checks which, and the forward probe carries one end to end. Nothing here
# asks the running Libertty, which may not be the one these tests built.)

# remote-control = false: listing reads, making and closing drive.
mkdir -p $T/config/libertty
echo "remote-control = false" > $T/config/libertty/config
refused() {  # refused NAME ARGS...
  local name=$1; shift
  XDG_CONFIG_HOME=$T/config $L +forward "$@" > $T/out 2> $T/err
  local got=$?
  if (( got == 1 )) && grep -q "remote-control" $T/err; then ok "$name"; else bad "$name: $got $(head -1 $T/err)"; fi
}
refused "remote-control = false refuses open" open 5173
refused "…and share" share 3000
refused "…and close" close --all
XDG_CONFIG_HOME=$T/config $L +forward ls > $T/out 2> $T/err
(( $? != 1 )) && ok "…but lists what's forwarded" || bad "ls refused: $(head -1 $T/err)"

# The command line's shape: +help and the shells' completion know it
# (+complete takes the words after `libertty`, as the shells pass them).
$L +help 2>&1 | grep -q -- "+forward open TARGET" && ok "+help has it" || bad "+help"
$L +complete zsh -- +forward '' > $T/zsh 2>&1
for word in open share ls close; do
  grep -q "^$word" $T/zsh && ok "completes $word" || bad "completes $word: $(cat $T/zsh)"
done
$L +complete zsh -- +forward close -- > $T/flags 2>&1
grep -q -- "--all" $T/flags && ok "completes --all" || bad "completes --all: $(cat $T/flags)"
$L +complete zsh -- +forward open -- > $T/open-flags 2>&1
grep -q -- "--browser" $T/open-flags && ok "completes --browser" || bad "completes --browser: $(cat $T/open-flags)"

(( fails == 0 )) && echo "forward: all passed" || echo "forward: $fails failed"
