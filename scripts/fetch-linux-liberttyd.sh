#!/bin/zsh
# The Linux liberttyd binaries CI built from this commit (.github/workflows/ci.yml),
# into Resources/remote — instead of building them here (that needs the
# swift.org toolchain and Swift's static Linux SDK). The commit must be
# pushed and its CI run done.
#   scripts/fetch-linux-liberttyd.sh [COMMIT]
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
COMMIT=$(git rev-parse ${1:-HEAD})
RUN=$(gh run list --workflow ci.yml --commit $COMMIT --json databaseId,conclusion,status \
  -q 'map(select(.status == "completed" and .conclusion == "success")) | first | .databaseId // empty')
[[ -n $RUN ]] || { echo "no successful CI run for $COMMIT yet (gh run list --workflow ci.yml)"; exit 1; }
TMP=$(mktemp -d)
gh run download $RUN -n liberttyd-linux -D $TMP
want=$(scripts/daemon-fingerprint.sh $COMMIT)
[[ $(cat $TMP/liberttyd-linux.source) == $want ]] || { echo "the artifact was built from other sources ($(cat $TMP/liberttyd-linux.source), not $want)"; exit 1; }
for f in liberttyd-linux-x86_64 liberttyd-linux-aarch64 liberttyd-linux.source; do cp $TMP/$f Resources/remote/$f; done
chmod +x Resources/remote/liberttyd-linux-*
ls -la Resources/remote
echo "From CI run $RUN. Commit Resources/remote before releasing."
