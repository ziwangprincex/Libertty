#!/bin/zsh
# Bundle the editor block's page (frontend/editor/main.js + CodeMirror 6, MIT) into
# vendor/codemirror/editor.js, with the packages' licenses beside it. The
# packages (pinned by frontend/editor/package-lock.json) are fetched into a scratch
# folder of their own, never the repo.
#   scripts/build-editor.sh
set -euo pipefail
ROOT=${0:A:h:h}
WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT
cp $ROOT/frontend/editor/package.json $ROOT/frontend/editor/package-lock.json $ROOT/frontend/editor/main.js $WORK/
# Exactly the locked versions, and no package's install scripts.
( cd $WORK && npm ci --ignore-scripts --no-audit --no-fund --silent )
OUT=$ROOT/vendor/codemirror
mkdir -p $OUT
$WORK/node_modules/.bin/esbuild $WORK/main.js --bundle --minify --format=iife --target=safari16 \
  --legal-comments=none --outfile=$OUT/editor.js
cp $ROOT/frontend/editor/index.html $OUT/index.html
# Every bundled package's license, for THIRD-PARTY-NOTICES.
{
  for pkg in $WORK/node_modules/@codemirror/* $WORK/node_modules/@lezer/* $WORK/node_modules/@replit/* \
             $WORK/node_modules/style-mod $WORK/node_modules/w3c-keyname $WORK/node_modules/crelt; do
    [[ -d $pkg ]] || continue
    name=${pkg#$WORK/node_modules/}
    lic=$(ls $pkg/LICENSE* 2>/dev/null | head -1 || true)
    [[ -n $lic ]] || continue
    version=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' $pkg/package.json)
    print "== $name $version =="
    cat $lic
    print
  done
} > $OUT/LICENSES.txt
print "editor: $(wc -c < $OUT/editor.js) bytes, $(grep -c '^== ' $OUT/LICENSES.txt) licenses"
