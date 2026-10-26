#!/bin/zsh
# liberttyd on a real Linux (File ▸ Connect to Host… to a Linux machine):
# Libertty --remote-probe against a Docker container, for each architecture
# the bundle ships (Resources/remote/liberttyd-linux-*), with
# tests/fixtures/docker-ssh standing in for ssh — with bash as the login
# shell there, and with fish (Libertty's fish integration, which no Mac here
# has). Needs Docker running; pulls alpine (a few MB) and adds bash and fish
# to it; the containers go when it's done.
# Not in tests/run.sh: it needs Docker and the network.
#   tests/linux.sh [aarch64 x86_64]
set -u
ROOT=${0:A:h:h}
cd $ROOT
DOCKER=${DOCKER:-$(command -v docker || echo /Applications/Docker.app/Contents/Resources/bin/docker)}
# Docker Desktop's credential helper sits beside its docker.
export PATH=${DOCKER:h}:$PATH
$DOCKER info > /dev/null 2>&1 || { echo "linux: skipped — Docker isn't running"; exit 0; }
mkdir -p $ROOT/build
swift build > $ROOT/build/test-build.log 2>&1 || { grep -E "error:" $ROOT/build/test-build.log; exit 1; }
LIBERTTY=$(swift build --show-bin-path)/Libertty
failures=0
archs=(${@:-aarch64 x86_64})
(( $# == 0 )) && archs=(aarch64 x86_64)
runs=()
for arch in $archs; do runs+=($arch:bash); done
runs+=(${archs[1]}:fish)
for run in $runs; do
  arch=${run%%:*} shell=${run##*:}
  platform=linux/${${arch/x86_64/amd64}/aarch64/arm64}
  name=libertty-linux-test-$arch-$$
  echo "== $arch ($platform), $shell"
  if ! $DOCKER run -d --rm --platform $platform --name $name alpine:3 sleep 600 > /dev/null; then
    echo "FAIL  linux $arch: no container"; (( failures++ )); continue
  fi
  $DOCKER exec $name sh -c "apk add --no-cache bash fish > /dev/null && adduser -D -s \$(command -v $shell) tester" ||
    { echo "FAIL  linux $arch: couldn't set the container up"; $DOCKER rm -f $name > /dev/null; (( failures++ )); continue; }
  PRIVATE=$(mktemp -d)
  if env LIBERTTY_SSH=$ROOT/tests/fixtures/docker-ssh DOCKER=$DOCKER LINUX_CONTAINER=$name FAKE_SSH_DOWN=$PRIVATE/down \
      FAKE_SSH_KILL="$DOCKER exec $name pkill -f 'liberttyd --bridge'" LINUX_SHELL=$($DOCKER exec $name sh -c "command -v $shell") \
      LIBERTTY_DAEMON_SOCKET=$PRIVATE/d.sock LIBERTTY_DAEMON_LOG=$PRIVATE/d.log LIBERTTY_DATA_DIR=$PRIVATE \
      $LIBERTTY --remote-probe linux-$arch | tee $PRIVATE/out.log | grep -E "^host:|: false|remote-probe"; then
    grep -q "remote-probe: all passed" $PRIVATE/out.log && echo "ok    linux $arch $shell" || { echo "FAIL  linux $arch $shell"; (( failures++ )); }
  else
    echo "FAIL  linux $arch $shell"; (( failures++ ))
  fi
  $DOCKER rm -f $name > /dev/null
done
(( failures == 0 )) && echo "linux: all passed"
