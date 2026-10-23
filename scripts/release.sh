#!/bin/zsh
# Make a release:
#   scripts/release.sh VERSION            build, sign and stage everything in build/release/VERSION
#   scripts/release.sh VERSION --publish  …and upload it (GitHub release + Homebrew tap)
#   scripts/release.sh VERSION --restage  for a VERSION staged here: its notes, update feed and cask
#                                         again (changelog or script changes), from the same zip
#   scripts/release.sh VERSION --refresh  …and upload them over the published ones
#
# Staged: Libertty-VERSION.zip (what updates install), Libertty-VERSION.dmg,
# appcast.json (the update feed: version, URL, SHA-256, Ed25519 signature,
# notes from docs/CHANGELOG.md), libertty.rb (the Homebrew cask) and
# release.md (the release page's text).
# Where to: scripts/release.conf. Signing key: ~/.config/libertty-release/update.key
# (or $LIBERTTY_UPDATE_KEY); create one with `swift scripts/sign-update.swift --generate`.
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
USAGE="usage: scripts/release.sh VERSION [--publish | --restage | --refresh]"
VERSION=${1:?$USAGE}
MODE=${2:-}
[[ -z $MODE || $MODE == --publish || $MODE == --restage || $MODE == --refresh ]] || { echo $USAGE; exit 2; }
source scripts/release.conf
KEY=${LIBERTTY_UPDATE_KEY:-$HOME/.config/libertty-release/update.key}
# Made when Libertty was called Lumen: the same key, where it was.
[[ -f $KEY || -n ${LIBERTTY_UPDATE_KEY:-} ]] || KEY=$HOME/.config/lumen-release/update.key
[[ -f $KEY ]] || { echo "no signing key at $KEY"; exit 1; }
mkdir -p build
[[ build/sign-update -nt scripts/sign-update.swift ]] || swiftc -O scripts/sign-update.swift -o build/sign-update
[[ $(build/sign-update --public $KEY) == $(cat scripts/update-public-key.txt) ]] \
  || { echo "$KEY doesn't match scripts/update-public-key.txt"; exit 1; }
grep -q "^## $VERSION\$" docs/CHANGELOG.md || { echo "add a '## $VERSION' section to docs/CHANGELOG.md first"; exit 1; }
# The tap's commits are this repository's identity (its own git config), never a global one.
NAME=$(git config --local user.name || true) EMAIL=$(git config --local user.email || true)
[[ -n $NAME && -n $EMAIL ]] || { echo "set this repository's own user.name and user.email (git config --local) first"; exit 1; }

OUT=$ROOT/build/release/$VERSION
ZIP=$OUT/Libertty-$VERSION.zip
if [[ $MODE == --restage || $MODE == --refresh ]]; then
  # The zip as published: its hash and signature mustn't change.
  [[ -f $ZIP ]] || { echo "no $ZIP: $MODE needs the release staged here"; exit 1; }
  if [[ $MODE == --refresh ]]; then
    # The tap holds the newest version's cask; the feed is the newest release's.
    [[ $(gh release view --repo $REPO --json tagName -q .tagName) == v$VERSION ]] \
      || { echo "v$VERSION isn't the latest release: --refresh would point the tap and feed back at it"; exit 1; }
    PUBLISHED=$(gh release view v$VERSION --repo $REPO --json assets -q ".assets[] | select(.name == \"Libertty-$VERSION.zip\") | .digest")
    [[ $PUBLISHED == sha256:$(shasum -a 256 $ZIP | cut -d' ' -f1) ]] \
      || { echo "$ZIP isn't the zip published for v$VERSION ($PUBLISHED): its feed and cask would fail to verify"; exit 1; }
  fi
else
  # The version lives in bundle.sh; set it so every later build agrees.
  sed -i '' "s/^VERSION=.*/VERSION=\${LIBERTTY_VERSION:-$VERSION}/" scripts/bundle.sh
  scripts/package.sh
  rm -rf $OUT
  mkdir -p $OUT
  ditto -c -k --sequesterRsrc --keepParent build/Libertty.app $ZIP
  cp build/Libertty-$VERSION.dmg $OUT/
fi
SHA=$(shasum -a 256 $ZIP | cut -d' ' -f1)
SIZE=$(stat -f%z $ZIP)
SIG=$(build/sign-update $KEY $ZIP)
URL=https://github.com/$REPO/releases/download/v$VERSION/Libertty-$VERSION.zip
PAGE=https://github.com/$REPO/releases/tag/v$VERSION

# Notes: this version's section of the changelog. Its "> " line is the
# summary: what the update dialog of a version older than 0.3.0 shows as is,
# and `+update --check`.
# (A blank line after the summary: Markdown would take the list into the quote.)
awk -v v="## $VERSION" '$0 == v {on=1; next} /^## / {on=0} on' docs/CHANGELOG.md | sed '/^$/d; /^>/G' > $OUT/notes.md
sed -n 's/^> *//p' $OUT/notes.md | tr -d '`' > $OUT/summary.txt
[[ -s $OUT/summary.txt ]] || { echo "add a '> ' summary line to docs/CHANGELOG.md's '## $VERSION' section first"; exit 1; }

python3 - "$OUT/appcast.json" "$VERSION" "$URL" "$SHA" "$SIG" "$SIZE" "$OUT/notes.md" "$OUT/summary.txt" "$PAGE" <<'PY'
import json, sys
out, version, url, sha, sig, size, notes, summary, page = sys.argv[1:]
notes, summary = open(notes).read().strip(), open(summary).read().strip()
json.dump({"version": version, "url": url, "sha256": sha, "signature": sig, "size": int(size),
           "notes": summary + "\n\nAll changes: " + page, "releaseNotes": notes, "releasePage": page,
           "minimumSystemVersion": "14.0"}, open(out, "w"), indent=2)
PY

cat > $OUT/libertty.rb <<RUBY
cask "libertty" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/Libertty-#{version}.zip"
  name "Libertty"
  desc "Native terminal emulator built on libghostty-vt"
  homepage "https://github.com/$REPO"

  livecheck do
    url :url
    strategy :github_latest
  end

  # Libertty updates itself (Libertty ▸ Check for Updates), with signed updates.
  auto_updates true
  depends_on arch: :arm64
  depends_on macos: :sonoma

  app "Libertty.app"
  binary "#{appdir}/Libertty.app/Contents/Resources/bin/libertty"

  # Ad-hoc signed, not notarized: Gatekeeper would refuse to open it (if
  # this can't be done, macOS asks once, as for the DMG).
  postflight_steps do
    run "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "{{appdir}}/Libertty.app"], must_succeed: false
  end

  uninstall quit: "dev.libertty.terminal"

  zap trash: [
    "~/.config/libertty",
    "~/Library/Application Support/Libertty",
    "~/Library/Caches/dev.libertty.terminal",
    "~/Library/HTTPStorages/dev.libertty.terminal",
    "~/Library/Logs/Libertty",
    "~/Library/Preferences/dev.libertty.terminal.plist",
    "~/Library/Saved Application State/dev.libertty.terminal.savedState",
    "~/Library/WebKit/dev.libertty.terminal",
  ]
end
RUBY
ruby -c $OUT/libertty.rb > /dev/null

# The release page: how to install, then the changes.
cat > $OUT/release.md <<MD
## Install

Apple silicon, macOS 14 or later.

- Homebrew: \`brew install --cask ${TAP%%/*}/${${TAP#*/}#homebrew-}/libertty\`
- Or open \`Libertty-$VERSION.dmg\` and drag Libertty to Applications. The app is not notarized: on
  first launch macOS blocks it. Open it once, then choose System Settings ▸ Privacy & Security ▸
  Open Anyway, or run \`xattr -dr com.apple.quarantine /Applications/Libertty.app\`.

Libertty updates itself (Libertty ▸ Check for Updates…); updates are verified with an Ed25519
signature. \`Libertty-$VERSION.zip\` is the same app, what the updater installs.

## Changes

MD
cat $OUT/notes.md >> $OUT/release.md

echo "Staged in $OUT:"
ls -1 $OUT | sed 's/^/  /'

[[ -n $MODE && $MODE != --restage ]] || { echo "Not published (--publish uploads a new release, --refresh this one's notes, feed and cask)."; exit 0; }

# GitHub: the release carries the zip, the DMG and the feed. A fresh
# repository gets a README first (releases need a commit to tag).
if [[ $MODE == --publish ]]; then
  gh repo view $REPO > /dev/null 2>&1 \
    || gh repo create $REPO --public --add-readme --description "Libertty: a fast native macOS terminal (releases)"
  gh release create v$VERSION $ZIP $OUT/Libertty-$VERSION.dmg $OUT/appcast.json \
    --repo $REPO --title "Libertty $VERSION" --notes-file $OUT/release.md
else
  gh release upload v$VERSION $OUT/appcast.json --repo $REPO --clobber
  gh release edit v$VERSION --repo $REPO --notes-file $OUT/release.md > /dev/null
fi

# Homebrew: the tap holds Casks/libertty.rb and its README (scripts/tap-README.md).
gh repo view $TAP > /dev/null 2>&1 \
  || gh repo create $TAP --public --description "Homebrew tap for Libertty"
TAPDIR=$(mktemp -d)
trap 'rm -rf $TAPDIR' EXIT
gh repo clone $TAP $TAPDIR -- --quiet
mkdir -p $TAPDIR/Casks
cp $OUT/libertty.rb $TAPDIR/Casks/libertty.rb
cp scripts/tap-README.md $TAPDIR/README.md
git -C $TAPDIR add Casks/libertty.rb README.md
if git -C $TAPDIR diff --cached --quiet; then
  echo "The tap has this cask already."
else
  MESSAGE="libertty $VERSION"
  [[ $MODE == --refresh ]] && MESSAGE="libertty $VERSION: cask and README refreshed"
  git -C $TAPDIR -c user.name="$NAME" -c user.email="$EMAIL" commit -q -m "$MESSAGE"
  git -C $TAPDIR push -q origin HEAD
fi
echo "Published Libertty $VERSION: brew install --cask ${TAP%%/*}/${${TAP#*/}#homebrew-}/libertty"
