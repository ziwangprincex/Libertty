#!/bin/zsh
# Vendor speedscope's release build (MIT; https://github.com/jlfwong/speedscope)
# into blocks/profile/lib/ for the profile block's viewer. npm checks the
# tarball against the registry's integrity hash; nothing is run from it.
#   scripts/build-speedscope.sh
set -euo pipefail
ROOT=${0:A:h:h}
VERSION=1.25.0
WORK=$(mktemp -d)
trap 'rm -rf $WORK' EXIT
( cd $WORK && npm pack speedscope@$VERSION --silent > /dev/null && tar xzf speedscope-$VERSION.tgz )
OUT=$ROOT/blocks/profile/lib
rm -rf $OUT
mkdir -p $OUT
REL=$WORK/package/dist/release
# The app (one script, one stylesheet), its font and wasm; not its favicons or sample profile.
cp $REL/speedscope-*.js $OUT/speedscope.js
cp $REL/speedscope-*.css $OUT/speedscope.css
cp $REL/*.woff2 $REL/*.wasm $REL/source-code-pro.LICENSE.md $OUT/
# The stylesheet and script name their hashed neighbours: keep those names (copied as they are).
{ print "== speedscope $VERSION =="; cat $WORK/package/LICENSE; print; print "== Source Code Pro (its font) =="; cat $REL/source-code-pro.LICENSE.md; } > $OUT/LICENSES.txt
print "speedscope $VERSION: $(wc -c < $OUT/speedscope.js) bytes"
