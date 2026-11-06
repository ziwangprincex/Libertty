#!/bin/zsh
# The Linux liberttyd binaries CI built from this commit (.github/workflows/ci.yml),
# into Resources/remote — instead of building them here (that needs the
# swift.org toolchain and Swift's static Linux SDK). The commit must be
# pushed and its CI run's two Linux jobs passed (linux-liberttyd built and
# started them, linux-liberttyd-arm started the aarch64 one): about five
# minutes. The mac job needn't be done — release.sh runs its unit tests and
# suite here again.
#   scripts/fetch-linux-liberttyd.sh [COMMIT]
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
COMMIT=$(git rev-parse ${1:-HEAD})
RUN= NEWEST=
for id in $(gh run list --workflow ci.yml --commit $COMMIT --json databaseId -q '.[].databaseId'); do
  [[ -n $NEWEST ]] || NEWEST=$id
  passed=$(gh run view $id --json jobs \
    -q '[.jobs[] | select((.name == "linux-liberttyd" or .name == "linux-liberttyd-arm") and .conclusion == "success")] | length')
  (( passed == 2 )) && { RUN=$id; break }
done
if [[ -z $RUN ]]; then
  echo "no CI run for $COMMIT whose Linux jobs passed yet"
  [[ -n $NEWEST ]] && gh run view $NEWEST --json jobs -q '.jobs[] | "  \(.name): \(.status) \(.conclusion)"'
  exit 1
fi
TMP=$(mktemp -d)
gh run download $RUN -n liberttyd-linux -D $TMP
want=$(scripts/daemon-fingerprint.sh $COMMIT)
[[ $(cat $TMP/liberttyd-linux.source) == $want ]] || { echo "the artifact was built from other sources ($(cat $TMP/liberttyd-linux.source), not $want)"; exit 1; }
for f in liberttyd-linux-x86_64 liberttyd-linux-aarch64 liberttyd-linux.source; do cp $TMP/$f Resources/remote/$f; done
chmod +x Resources/remote/liberttyd-linux-*
ls -la Resources/remote
echo "From CI run $RUN. Commit Resources/remote before releasing."
