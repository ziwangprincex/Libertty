#!/bin/zsh
# The look on the real screen (tests/screen-check.swift): a built app,
# private, through Rex's layouts and its windows, shot into a contact sheet
# and checked (on the stage, not under the Dock, no gap beside the sidebar,
# every pane its header). It takes the screen for about half a minute.
# scripts/release.sh runs it on what it staged; --publish wants it passed.
#   tests/screen-check.sh [APP] [OUTDIR] [--only NAME,NAME]
set -euo pipefail
ROOT=${0:A:h:h}
APP=${1:-$ROOT/build/Libertty.app}
OUT=${2:-$ROOT/build/test-output/screen-check}
mkdir -p $ROOT/build
TOOL=$ROOT/build/screen-check
[[ $TOOL -nt $ROOT/tests/screen-check.swift ]] || swiftc -O $ROOT/tests/screen-check.swift -o $TOOL
rm -rf $OUT
$TOOL $APP $OUT ${@:3}
