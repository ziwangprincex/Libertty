#!/bin/zsh
# Build an optimized Libertty.app and wrap it in a disk image:
#   scripts/package.sh            → build/Libertty-<version>.dmg
# Ad-hoc signed (no Developer ID): on another Mac, the first launch needs
# System Settings ▸ Privacy & Security ▸ Open Anyway (right-click ▸ Open before
# macOS 15), or `xattr -dr com.apple.quarantine /Applications/Libertty.app`.
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
APP=$ROOT/build/Libertty.app
LIBERTTY_APP=$APP scripts/bundle.sh release
VERSION=$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $APP/Contents/Info.plist)
STAGE=$(mktemp -d)
trap 'rm -rf $STAGE' EXIT
cp -R $APP $STAGE/
ln -s /Applications $STAGE/Applications
DMG=$ROOT/build/Libertty-$VERSION.dmg
rm -f $DMG
hdiutil create -volname "Libertty $VERSION" -srcfolder $STAGE -fs APFS -format ULFO -quiet $DMG
echo $DMG
