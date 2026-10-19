#!/bin/zsh
# Make a release:
#   scripts/release.sh VERSION            build, sign and stage everything in build/release/VERSION
#   scripts/release.sh VERSION --publish  …and upload it (GitHub release + Homebrew tap)
#
# Staged: Libertty-VERSION.zip (what updates install), Libertty-VERSION.dmg,
# appcast.json (the update feed: version, URL, SHA-256, Ed25519 signature,
# notes from docs/CHANGELOG.md) and libertty.rb (the Homebrew cask).
# Where to: scripts/release.conf. Signing key: ~/.config/libertty-release/update.key
# (or $LIBERTTY_UPDATE_KEY); create one with `swift scripts/sign-update.swift --generate`.
set -euo pipefail
ROOT=${0:A:h:h}
cd $ROOT
VERSION=${1:?usage: scripts/release.sh VERSION [--publish]}
PUBLISH=${2:-}
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

# The version lives in bundle.sh; set it so every later build agrees.
sed -i '' "s/^VERSION=.*/VERSION=\${LIBERTTY_VERSION:-$VERSION}/" scripts/bundle.sh
scripts/package.sh

OUT=$ROOT/build/release/$VERSION
rm -rf $OUT
mkdir -p $OUT
ZIP=$OUT/Libertty-$VERSION.zip
ditto -c -k --sequesterRsrc --keepParent build/Libertty.app $ZIP
cp build/Libertty-$VERSION.dmg $OUT/
SHA=$(shasum -a 256 $ZIP | cut -d' ' -f1)
SIZE=$(stat -f%z $ZIP)
SIG=$(build/sign-update $KEY $ZIP)
# Notes: this version's section of the changelog.
awk -v v="## $VERSION" '$0 == v {on=1; next} /^## / {on=0} on' docs/CHANGELOG.md | sed '/^$/d' > $OUT/notes.md
URL=https://github.com/$REPO/releases/download/v$VERSION/Libertty-$VERSION.zip

python3 - "$OUT/appcast.json" "$VERSION" "$URL" "$SHA" "$SIG" "$SIZE" "$OUT/notes.md" <<'PY'
import json, sys
out, version, url, sha, sig, size, notes = sys.argv[1:]
json.dump({"version": version, "url": url, "sha256": sha, "signature": sig, "size": int(size),
           "notes": open(notes).read().strip(), "minimumSystemVersion": "14.0"}, open(out, "w"), indent=2)
PY

cat > $OUT/libertty.rb <<RUBY
cask "libertty" do
  version "$VERSION"
  sha256 "$SHA"

  url "https://github.com/$REPO/releases/download/v#{version}/Libertty-#{version}.zip"
  name "Libertty"
  desc "Fast native terminal built on libghostty-vt"
  homepage "https://github.com/$REPO"

  # Libertty updates itself (Libertty ▸ Check for Updates), with signed updates.
  auto_updates true
  depends_on macos: ">= :sonoma"

  app "Libertty.app"
  binary "#{appdir}/Libertty.app/Contents/Resources/bin/libertty"

  # Ad-hoc signed, not notarized: Gatekeeper would refuse to open it.
  postflight do
    system_command "/usr/bin/xattr", args: ["-dr", "com.apple.quarantine", "#{appdir}/Libertty.app"]
  end

  uninstall quit: "dev.libertty.terminal"

  zap trash: [
    "~/.config/libertty",
    "~/Library/Application Support/Libertty",
    "~/Library/Caches/dev.libertty.terminal",
    "~/Library/Logs/Libertty",
    "~/Library/Preferences/dev.libertty.terminal.plist",
  ]
end
RUBY
ruby -c $OUT/libertty.rb > /dev/null

echo "Staged in $OUT:"
ls -1 $OUT | sed 's/^/  /'

[[ $PUBLISH == --publish ]] || { echo "Not published (add --publish to upload)."; exit 0; }

# GitHub: the release carries the zip, the DMG and the feed. A fresh
# repository gets a README first (releases need a commit to tag).
gh repo view $REPO > /dev/null 2>&1 \
  || gh repo create $REPO --public --add-readme --description "Libertty: a fast native macOS terminal (releases)"
gh release create v$VERSION $ZIP $OUT/Libertty-$VERSION.dmg $OUT/appcast.json \
  --repo $REPO --title "Libertty $VERSION" --notes-file $OUT/notes.md

# Homebrew: the tap holds Casks/libertty.rb.
gh repo view $TAP > /dev/null 2>&1 \
  || gh repo create $TAP --public --add-readme --description "Homebrew tap for Libertty"
TAPDIR=$(mktemp -d)
gh repo clone $TAP $TAPDIR -- --quiet
mkdir -p $TAPDIR/Casks
cp $OUT/libertty.rb $TAPDIR/Casks/libertty.rb
git -C $TAPDIR add Casks/libertty.rb
git -C $TAPDIR commit -q -m "libertty $VERSION"
git -C $TAPDIR push -q
rm -rf $TAPDIR
echo "Published Libertty $VERSION: brew install --cask ${TAP%%/*}/${${TAP#*/}#homebrew-}/libertty"
