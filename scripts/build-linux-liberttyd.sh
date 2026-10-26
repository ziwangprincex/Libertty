#!/bin/zsh
# liberttyd for Linux hosts (File ▸ Connect to Host…): static musl binaries
# for x86_64 and aarch64, into Resources/remote/ (scripts/bundle.sh ships
# them; Libertty installs the right one on a host the first time it connects).
#
# Needs Zig 0.16 (as for the Mac build), Swift's static Linux SDK and the
# swift.org toolchain of the same version (the Command Line Tools' swift
# can't use swift.org SDKs). Both install without root:
#   swift sdk install https://download.swift.org/swift-6.4.1-release/static-sdk/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE_static-linux-0.1.0.artifactbundle.tar.gz \
#     --checksum cef5592d7430ed3c5ae1ddda479849c6f5252bd94a5723db1559f984caf38a7c
#   curl -LO https://download.swift.org/swift-6.4.1-release/xcode/swift-6.4.1-RELEASE/swift-6.4.1-RELEASE-osx.pkg
#   installer -pkg swift-6.4.1-RELEASE-osx.pkg -target CurrentUserHomeDirectory
set -euo pipefail
ROOT=${0:A:h:h}
ZIG=${ZIG:-zig}
TOOLCHAIN=~/Library/Developer/Toolchains/swift-6.4.1-RELEASE.xctoolchain
[[ -x $TOOLCHAIN/usr/bin/swift ]] || TOOLCHAIN=/Library/Developer/Toolchains/swift-6.4.1-RELEASE.xctoolchain
SWIFT=${SWIFT:-$TOOLCHAIN/usr/bin/swift}
if [[ ! -x $SWIFT ]]; then
  echo "build-linux-liberttyd: no swift.org 6.4.1 toolchain (see the top of this script)" >&2
  exit 1
fi
mkdir -p $ROOT/Resources/remote
for arch in ${=ARCHS:-x86_64 aarch64}; do  # ${=…}: zsh splits it into words
  echo "== $arch"
  # libghostty-vt for that target (its own prefix: the Mac library stays as it is).
  (cd $ROOT/vendor/ghostty && $ZIG build -Demit-lib-vt=true -Demit-xcframework=false -Doptimize=ReleaseFast \
    -Dtarget=$arch-linux-musl --prefix $ROOT/build/linux/$arch)
  SCRATCH=$ROOT/build/linux/swiftpm-$arch
  export LIBERTTY_VT_LIBRARY=$ROOT/build/linux/$arch/lib/libghostty-vt.a
  $SWIFT build -c release --product liberttyd --swift-sdk $arch-swift-linux-musl --scratch-path $SCRATCH \
    --static-swift-stdlib -Xlinker -s
  BIN=$($SWIFT build -c release --product liberttyd --swift-sdk $arch-swift-linux-musl --scratch-path $SCRATCH --show-bin-path)
  cp $BIN/liberttyd $ROOT/Resources/remote/liberttyd-linux-$arch
  ls -la $ROOT/Resources/remote/liberttyd-linux-$arch
done
# What they're built from (scripts/release.sh checks it): this commit's
# daemon sources — uncommitted changes would make it a lie.
if git -C $ROOT diff --quiet HEAD -- Sources/LiberttyCore Sources/liberttyd Sources/CPty Sources/CGhosttyVt; then
  $ROOT/scripts/daemon-fingerprint.sh > $ROOT/Resources/remote/liberttyd-linux.source
else
  echo "build-linux-liberttyd: the daemon's sources have uncommitted changes: no liberttyd-linux.source written" >&2
  rm -f $ROOT/Resources/remote/liberttyd-linux.source
fi
