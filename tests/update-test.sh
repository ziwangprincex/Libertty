#!/bin/zsh
# End-to-end check of signed updates, offline: builds a "next version" zip,
# serves it through a file:// feed, and has a copy of the current app
#   1. report it (+update --check),
#   2. refuse a tampered zip (correct SHA-256, wrong signature),
#   3. install the genuine one and come up as the new version,
#   4. do the same from Check for Updates… and its Install and Restart
#      (a UI probe answers the dialog).
# Its bundles are its own: build/Libertty.app (perhaps the Libertty you're
# using) is left alone.
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
KEY=${LIBERTTY_UPDATE_KEY:-$HOME/.config/libertty-release/update.key}
[[ build/sign-update -nt scripts/sign-update.swift ]] || swiftc -O scripts/sign-update.swift -o build/sign-update
T=$(mktemp -d)
trap 'rm -rf $T' EXIT
LIBERTTY_VERSION=99.0.0 LIBERTTY_APP=$T/next/Libertty.app scripts/bundle.sh release > /dev/null 2>&1
ditto -c -k --sequesterRsrc --keepParent $T/next/Libertty.app $T/next.zip
LIBERTTY_APP=$T/Libertty.app scripts/bundle.sh release > /dev/null 2>&1
feed() {  # feed ZIP: write the feed for ZIP, signed with the release key
  python3 - $T/appcast.json "file://$1" $(shasum -a 256 $1 | cut -d' ' -f1) $(build/sign-update $KEY $T/next.zip) $(stat -f%z $1) <<'PY'
import json, sys
out, url, sha, sig, size = sys.argv[1:]
json.dump({"version": "99.0.0", "url": url, "sha256": sha, "signature": sig, "size": int(size), "notes": "test"}, open(out, "w"))
PY
}
APP=$T/Libertty.app/Contents/MacOS/Libertty
set +e  # from here, failures are results
export LIBERTTY_UPDATE_FEED=file://$T/appcast.json
fails=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; (( fails++ )); }

feed $T/next.zip
$APP +update --check > /dev/null; [[ $? == 10 ]] && ok "check finds 99.0.0" || bad "check"

cp $T/next.zip $T/tampered.zip
printf 'X' | dd of=$T/tampered.zip bs=1 seek=5000 conv=notrunc 2>/dev/null
feed $T/tampered.zip
$APP +update > /dev/null 2>&1 && bad "tampered zip installed" || ok "tampered zip refused"

feed $T/next.zip
$APP +update > /dev/null && ok "genuine zip installed" || bad "install"
[[ $(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' $T/Libertty.app/Contents/Info.plist) == 99.0.0 ]] \
  && ok "app is now 99.0.0" || bad "version after install"
codesign -v $T/Libertty.app && ok "code signature intact" || bad "code signature"

# The dialog's way, in another copy of the current app.
LIBERTTY_PROBES=1 LIBERTTY_APP=$T/gui/Libertty.app scripts/bundle.sh release > /dev/null 2>&1
out=$($T/gui/Libertty.app/Contents/MacOS/Libertty --ui-probe $'update:install\nexpect-app-version:99.0.0' $T/probe 2>&1)
[[ $out == *"ok    ui-probe app is 99.0.0"* ]] && ok "Check for Updates, Install and Restart installs it" \
  || bad "the dialog's install: $(print -r -- $out | grep -v '^(no LIBERTTY')"
(( fails == 0 )) && echo "all passed"
exit $(( fails > 0 ))
