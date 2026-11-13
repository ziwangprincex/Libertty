#!/bin/zsh
# Bundle the Markdown documents' diagram renderer (frontend/mermaid/main.js +
# Mermaid, MIT) into vendor/mermaid/mermaid.js, with the bundled packages'
# licenses beside it. The packages (pinned by frontend/mermaid/package-lock.json)
# are fetched into a scratch folder of their own, never the repo. Mermaid's
# ELK layouts (elkjs, EPL-2.0) are left out: `layout: elk` says so instead.
#   scripts/build-mermaid.sh
set -euo pipefail
ROOT=${0:A:h:h}
WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT
cp $ROOT/frontend/mermaid/package.json $ROOT/frontend/mermaid/package-lock.json $ROOT/frontend/mermaid/main.js $WORK/
print 'export default class ELK { constructor() { throw new Error("ELK layouts are not included in Libertty"); } }' > $WORK/elk-stub.js
# Exactly the locked versions, and no package's install scripts.
( cd $WORK && npm ci --ignore-scripts --no-audit --no-fund --silent )
OUT=$ROOT/vendor/mermaid
mkdir -p $OUT
$WORK/node_modules/.bin/esbuild $WORK/main.js --bundle --minify --format=iife --target=safari16 \
  --alias:elkjs/lib/elk.bundled.js=$WORK/elk-stub.js --legal-comments=none --log-level=warning --outfile=$OUT/mermaid.js
if grep -q "Cannot construct an ELK" $OUT/mermaid.js; then print "build-mermaid: elkjs got in" >&2; exit 1; fi
# Every package in the tree, nested ones too (not esbuild, which only builds
# it; not elkjs, left out).
python3 -I - $WORK/node_modules > $OUT/LICENSES.txt <<'PY'
import json, os, sys
root = sys.argv[1]
found = {}
for dirpath, dirnames, filenames in os.walk(root):
    parent = os.path.basename(os.path.dirname(dirpath))
    grand = os.path.basename(os.path.dirname(os.path.dirname(dirpath)))
    # A package: right under node_modules, or under node_modules/@scope.
    if "package.json" not in filenames or not (parent == "node_modules" or (parent.startswith("@") and grand == "node_modules")):
        continue
    meta = json.load(open(os.path.join(dirpath, "package.json")))
    name, version = meta.get("name"), meta.get("version")
    if not name or name in ("esbuild", "elkjs") or name.startswith("@esbuild/") or (name, version) in found:
        continue
    lic = next((f for f in sorted(filenames) if f.upper().startswith(("LICENSE", "LICENCE", "COPYING"))), None)
    found[(name, version)] = open(os.path.join(dirpath, lic), errors="replace").read().strip() if lic else f"License: {meta.get('license')}"
for (name, version), text in sorted(found.items()):
    print(f"== {name} {version} ==\n{text}\n")
PY
print "mermaid: $(wc -c < $OUT/mermaid.js) bytes js, $(grep -c '^== ' $OUT/LICENSES.txt) packages"
