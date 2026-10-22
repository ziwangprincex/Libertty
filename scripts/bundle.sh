#!/bin/zsh
# Build Libertty and wrap it in an app bundle at build/Libertty.app (or at
# $LIBERTTY_APP: tests build their own, never the one you may be running).
#   scripts/bundle.sh            # debug
#   scripts/bundle.sh release    # optimized
set -euo pipefail
ROOT=${0:A:h:h}
CONFIG=${1:-debug}
# Absolute, resolved before the cd: a relative $LIBERTTY_APP means where you are.
DEST=${${LIBERTTY_APP:-$ROOT/build/Libertty.app}:a}
cd $ROOT

# Bundled fonts (OFL-1.1): JetBrains Mono patched with Nerd Font symbols, from Ghostty's vendored set.
FONTS=$ROOT/build/fonts
RES=$ROOT/vendor/ghostty/src/font/res
mkdir -p $FONTS
cp $RES/JetBrainsMonoNerdFont-{Regular,Bold,Italic,BoldItalic}.ttf $RES/OFL.txt $FONTS/
# The interface face (OFL-1.1, vercel/geist-font v1.8.1): Tern's choice, and close to SF Pro's metrics.
cp $ROOT/vendor/geist/Geist-{Regular,Medium,SemiBold}.ttf $FONTS/
cp $ROOT/vendor/geist/OFL.txt $FONTS/Geist-OFL.txt

BINDIR=$(swift build -c $CONFIG --show-bin-path)
# liberttyd embeds its Info.plist at link time, a file SwiftPM doesn't watch.
[[ ! $ROOT/Sources/liberttyd/Info.plist -nt $BINDIR/liberttyd ]] || touch $ROOT/Sources/liberttyd/main.swift
swift build -c $CONFIG
BIN=$BINDIR/Libertty

mkdir -p ${DEST:h}
# Built beside it, then swapped in whole: a Libertty running from it never
# finds its fonts, terminfo or shell integration half there.
APP=$(mktemp -d ${DEST:h}/.Libertty-building.XXXXXX)/Libertty.app
# Whatever happens, nothing half-built stays behind (zsh runs the EXIT trap
# on these signals only through an explicit exit).
trap 'rm -rf ${APP:h}' EXIT
trap 'exit 130' INT TERM HUP
mkdir -p $APP/Contents/MacOS $APP/Contents/Resources
cp $BIN $APP/Contents/MacOS/Libertty
# liberttyd keeps sessions alive while the app is closed (Sources/LiberttyCore/DaemonServer.swift).
cp $BINDIR/liberttyd $APP/Contents/MacOS/liberttyd
cp -R $FONTS $APP/Contents/Resources/Fonts
# The editor block's page (CodeMirror 6, MIT; scripts/build-editor.sh) and its packages' licenses.
# The blocks' pages (Libertty's own HTML/JS: Git, …).
cp -R $ROOT/blocks $APP/Contents/Resources/blocks
mkdir -p $APP/Contents/Resources/editor
cp $ROOT/vendor/codemirror/{index.html,editor.js,LICENSES.txt} $APP/Contents/Resources/editor/
cp -R $ROOT/Resources/. $APP/Contents/Resources/
# The logo (assets/icon/: its source, every size, the web favicon).
cp $ROOT/assets/icon/libertty.icns $APP/Contents/Resources/AppIcon.icns
cp $ROOT/assets/icon/favicon.ico $APP/Contents/Resources/favicon.ico
# TERM=xterm-ghostty: compiled here; shells get TERMINFO pointing at it. The
# source stays too: remote hosts compile it with their own tic.
mkdir -p $APP/Contents/Resources/terminfo
tic -x -o $APP/Contents/Resources/terminfo $ROOT/Resources/terminfo-src/ghostty.terminfo

VERSION=${LIBERTTY_VERSION:-0.2.0}
# Update feed and the key updates must be signed with (scripts/release.sh).
source $ROOT/scripts/release.conf
FEED=https://github.com/$REPO/releases/latest/download/appcast.json
PUBKEY=$(cat $ROOT/scripts/update-public-key.txt)
cat > $APP/Contents/Info.plist <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key><string>Libertty</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>LiberttyUpdateFeed</key><string>$FEED</string>
    <key>LiberttyUpdatePublicKey</key><string>$PUBKEY</string>
    <key>NSHumanReadableCopyright</key><string>Libertty. Terminal core: libghostty-vt (MIT). Font: JetBrains Mono Nerd Font (OFL-1.1).</string>
    <key>CFBundleIdentifier</key><string>dev.libertty.terminal</string>
    <key>CFBundleName</key><string>Libertty</string>
    <key>CFBundleDisplayName</key><string>Libertty</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$VERSION</string>
    <key>CFBundleVersion</key><string>$VERSION</string>
    <key>LSMinimumSystemVersion</key><string>14.0</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>NSSupportsAutomaticGraphicsSwitching</key><true/>
    <key>LSApplicationCategoryType</key><string>public.app-category.developer-tools</string>
    <!-- Default terminal (Libertty ▸ Make Libertty the Default Terminal), folders and scripts opened with Libertty. -->
    <key>CFBundleDocumentTypes</key>
    <array>
        <dict>
            <key>CFBundleTypeName</key><string>Terminal scripts</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>CFBundleTypeExtensions</key>
            <array><string>command</string><string>tool</string><string>sh</string><string>zsh</string><string>csh</string><string>pl</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeName</key><string>Folders</string>
            <key>CFBundleTypeRole</key><string>Editor</string>
            <key>LSHandlerRank</key><string>Alternate</string>
            <key>LSItemContentTypes</key><array><string>public.directory</string></array>
        </dict>
        <dict>
            <key>CFBundleTypeRole</key><string>Shell</string>
            <key>LSItemContentTypes</key><array><string>public.unix-executable</string></array>
        </dict>
    </array>
    <!-- Finder ▸ Services ▸ New Libertty Tab/Window Here. -->
    <key>NSServices</key>
    <array>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>New Libertty Tab Here</string></dict>
            <key>NSMessage</key><string>openTab</string>
            <key>NSRequiredContext</key><dict><key>NSTextContent</key><string>FilePath</string></dict>
            <key>NSSendTypes</key><array><string>NSFilenamesPboardType</string><string>public.plain-text</string></array>
        </dict>
        <dict>
            <key>NSMenuItem</key><dict><key>default</key><string>New Libertty Window Here</string></dict>
            <key>NSMessage</key><string>openWindow</string>
            <key>NSRequiredContext</key><dict><key>NSTextContent</key><string>FilePath</string></dict>
            <key>NSSendTypes</key><array><string>NSFilenamesPboardType</string><string>public.plain-text</string></array>
        </dict>
    </array>
</dict>
</plist>
PLIST
# What a program in a terminal tells macOS it wants the camera, microphone, …
# for: the texts liberttyd carries (Sources/liberttyd/Info.plist), here too for
# the shells the app runs itself (session-persistence = false).
python3 - $ROOT/Sources/liberttyd/Info.plist $APP/Contents/Info.plist <<'PY'
import plistlib, sys
source, target = sys.argv[1:]
usage = {k: v for k, v in plistlib.load(open(source, "rb")).items() if k.endswith("UsageDescription")}
with open(target, "rb") as f:
    info = plistlib.load(f)
info.update(usage)
with open(target, "wb") as f:
    plistlib.dump(info, f)
PY

# Ad-hoc sign so the hardened system lets it run and keeps TCC grants stable.
codesign --force --sign - $APP/Contents/MacOS/liberttyd >/dev/null
codesign --force --sign - $APP >/dev/null
# The swap, in one step (renamex_np): the new bundle takes the name and the
# old one the build folder's place, never a moment with neither. A first
# build only claims the name, and fails rather than land inside a bundle
# another build put there meanwhile. (A running copy keeps its open files.)
python3 - $APP $DEST <<'PY'
import ctypes, os, sys
new, dest = (os.fsencode(p) for p in sys.argv[1:])
libc = ctypes.CDLL(None, use_errno=True)
RENAME_SWAP, RENAME_EXCL = 0x2, 0x4
flags = RENAME_SWAP if os.path.lexists(dest) else RENAME_EXCL
if libc.renamex_np(new, dest, flags) != 0:
    sys.exit("bundle.sh: can't put the bundle in place: " + os.strerror(ctypes.get_errno()))
PY
echo $DEST
