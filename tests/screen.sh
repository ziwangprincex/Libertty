#!/bin/zsh
# The on-screen check (Libertty --screen-probe): a real window for about 40
# seconds, recorded as the window server shows it (ScreenCaptureKit, this
# process's windows only), while it's hidden and brought back, another app's
# window comes and goes, the sidebar folds, it's resized and miniaturized.
# It takes the focus: run it while you're away from the Mac. It isn't in
# tests/run.sh, which never opens a window. Needs Screen Recording permission
# for the terminal running it; without, or with another app kept in front,
# it says so and skips. Frames that fail go to OUTDIR.
#   tests/screen.sh [OUTDIR]
set -u
ROOT=${0:A:h:h}
cd $ROOT
swift build > $ROOT/build/test-build.log 2>&1 || { grep -E "error:" $ROOT/build/test-build.log; exit 1; }
OUT=${1:-$ROOT/build/test-output/screen}
PRIVATE=$(mktemp -d)
mkdir -p $PRIVATE/config
echo "The screen probe takes the screen for about 40 s, starting in 5 s (^C to stop)."
sleep 5
env XDG_CONFIG_HOME=$PRIVATE/config LIBERTTY_DAEMON_SOCKET=$PRIVATE/d.sock LIBERTTY_DAEMON_LOG=$PRIVATE/d.log \
  LIBERTTY_DATA_DIR=$PRIVATE $(swift build --show-bin-path)/Libertty --screen-probe $OUT
