#!/bin/zsh
# Build libghostty-vt (static) from the pinned Ghostty checkout in vendor/ghostty.
# Ghostty requires Zig 0.17.x exactly (build.zig.zon minimum_zig_version).
# The xcframework path needs full Xcode; we only link the static archive.
set -euo pipefail
ROOT=${0:A:h:h}
GHOSTTY=$ROOT/vendor/ghostty
ZIG=${ZIG:-$(brew --prefix zig)/bin/zig}

cd $GHOSTTY
echo "ghostty $(git rev-parse --short HEAD), zig $($ZIG version)"
$ZIG build -Demit-lib-vt=true -Demit-xcframework=false -Doptimize=ReleaseFast
ls -la zig-out/lib
