#!/bin/zsh
# Bundle the canvas block's page (frontend/canvas/main.jsx + Excalidraw and React,
# MIT) into blocks/canvas/lib/, with Excalidraw's fonts (OFL; Comic Shanns
# MIT) and the packages' licenses. The packages (pinned by
# frontend/canvas/package-lock.json) are fetched into a scratch folder, never the repo.
#   scripts/build-canvas.sh
set -euo pipefail
ROOT=${0:A:h:h}
WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT
cp $ROOT/frontend/canvas/package.json $ROOT/frontend/canvas/package-lock.json $ROOT/frontend/canvas/main.jsx $WORK/
( cd $WORK && npm ci --ignore-scripts --no-audit --no-fund --silent )
OUT=$ROOT/blocks/canvas/lib
rm -rf $OUT
mkdir -p $OUT
$WORK/node_modules/.bin/esbuild $WORK/main.jsx --bundle --minify --format=iife --target=safari16 --jsx=automatic --conditions=production \
  --define:process.env.NODE_ENV='"production"' --define:import.meta.env='{"PROD":true,"DEV":false,"MODE":"production"}' \
  --loader:.woff2=file --legal-comments=none --log-level=warning --outfile=$OUT/canvas.js
cp -R $WORK/node_modules/@excalidraw/excalidraw/dist/prod/fonts $OUT/fonts
{
  for pkg in $WORK/node_modules/@excalidraw/* $WORK/node_modules/react $WORK/node_modules/react-dom $WORK/node_modules/scheduler; do
    [[ -d $pkg ]] || continue
    name=${pkg#$WORK/node_modules/}
    lics=( $pkg/LICENSE*(N) )
    lic=${lics[1]:-}
    version=$(python3 -I -c 'import json,sys; print(json.load(open(sys.argv[1]))["version"])' $pkg/package.json)
    print "== $name $version =="
    if [[ -n $lic ]]; then cat $lic; else python3 -I -c 'import json,sys; print("License:", json.load(open(sys.argv[1])).get("license"))' $pkg/package.json; fi
    print
  done
  print "== Excalidraw's fonts (lib/fonts) =="
  print "Excalifont, Virgil, Xiaolai, Nunito, Lilita One, Cascadia Code, Liberation Sans and Assistant: SIL Open Font License 1.1. Comic Shanns: MIT."
} > $OUT/LICENSES.txt
print "canvas: $(wc -c < $OUT/canvas.js) bytes js, $(du -sh $OUT/fonts | cut -f1) fonts"
