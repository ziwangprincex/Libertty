#!/bin/zsh
# What liberttyd is built from, as one hash: its sources (LiberttyCore,
# liberttyd, CPty, the libghostty-vt headers) as committed, and the Ghostty
# checkout. The Linux binaries carry the hash they were built from
# (Resources/remote/liberttyd-linux.source); scripts/release.sh refuses to
# ship them when it isn't this commit's.
#   scripts/daemon-fingerprint.sh [COMMIT]
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
REV=${1:-HEAD}
{
  for p in Sources/LiberttyCore Sources/liberttyd Sources/CPty Sources/CGhosttyVt; do
    git rev-parse "$REV:$p"
  done
  git rev-parse "$REV:vendor/ghostty"
} | { command -v shasum > /dev/null && shasum -a 256 || sha256sum; } | cut -c1-16
