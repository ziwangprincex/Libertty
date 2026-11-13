#!/bin/zsh
# bench/startup.sh [--offscreen] [--persist] [--runs N] [--build debug|release]:
# how long Libertty takes to launch, through its own launch path
# (Libertty --startup-bench), from the process's creation to main, to the app
# having launched, to its window shown, and to the first frame showing the
# shell's prompt. Prints each run and the medians.
#
# On screen by default: a window comes up in front, N times (what you'd see).
# --offscreen keeps it off every screen and out of the Dock, for a Mac in use.
# --persist: the shell in liberttyd (a private one: the first run starts it,
# later runs find it running, as yours would be).
# The shell is zsh with an empty ZDOTDIR, so your own rc files don't count;
# the config is empty. --build release (default) times an optimized build,
# with the probes built in (a scratch path of its own, .build-probes).
set -e
ROOT=${0:A:h:h}
RUNS=10 BUILD=release FLAGS=()
while (( $# )); do
  case $1 in
    --offscreen|--persist) FLAGS+=($1) ;;
    --runs) RUNS=$2; shift ;;
    --build) BUILD=$2; shift ;;
    *) print -u2 "usage: bench/startup.sh [--offscreen] [--persist] [--runs N] [--build debug|release]"; exit 2 ;;
  esac
  shift
done
cd $ROOT
if [[ $BUILD == release ]]; then
  ARGS=(-c release -Xswiftc -DLIBERTTY_PROBES --scratch-path $ROOT/.build-probes)
else
  ARGS=()
fi
swift build $ARGS > /dev/null
BIN=$(swift build $ARGS --show-bin-path)

P=$(mktemp -d /tmp/libertty-startup.XXXXXX)
mkdir -p $P/config $P/zdotdir
trap 'LIBERTTY_DAEMON_SOCKET=$P/d.sock $BIN/Libertty +daemon stop --force > /dev/null 2>&1 || true; rm -rf $P' EXIT
run() {
  env LIBERTTY_DAEMON_SOCKET=$P/d.sock LIBERTTY_DAEMON_LOG=$P/d.log LIBERTTY_DATA_DIR=$P \
    XDG_CONFIG_HOME=$P/config LIBERTTY_SHELL=/bin/zsh ZDOTDIR=$P/zdotdir \
    perl -e 'alarm 30; exec @ARGV' $BIN/Libertty --startup-bench $FLAGS
}
# Once, not counted: the binary and its libraries in the file cache.
run > /dev/null
lines=()
for i in $(seq $RUNS); do
  line=$(run | grep '^startup-bench')
  print -r -- $line
  [[ $line == 'startup-bench:'* ]] && lines+=($line)
done
(( ${#lines} )) || { print -u2 "no run finished"; exit 1; }
print -rl -- $lines | python3 -I -c '
import sys, statistics
stages = {}
for line in sys.stdin:
    words = line.split("(")[0].split()[1:]
    for name, ms in zip(words[0::2], words[1::2]):
        stages.setdefault(name, []).append(float(ms))
print("median (ms):  " + "  ".join(f"{n} {statistics.median(v):.1f}" for n, v in stages.items()))
'
