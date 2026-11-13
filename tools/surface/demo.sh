#!/bin/sh
# Libertty's surface protocol from a shell script, with `libertty +surface`
# (docs/surface-protocol.md): a progress card that fills, then a choice
# whose answer the script reads back.
#   sh tools/surface/demo.sh
set -e
if ! libertty +surface query > /dev/null 2>&1; then
  echo "This terminal doesn't draw surfaces (Libertty with surfaces = true does)."
  exit 1
fi

# A card in the output, four rows tall; the same id again updates it in place.
libertty +surface show build --rows 4 --title Build \
  '[{"type":"text","text":"Building…","style":"title"},{"type":"progress","value":0,"label":"0 of 5 steps"}]'
for i in 1 2 3 4 5; do
  sleep 0.4
  libertty +surface show build --rows 4 --title Build --update \
    "[{\"type\":\"text\",\"text\":\"Building…\",\"style\":\"title\"},{\"type\":\"progress\",\"value\":$(echo "$i / 5" | bc -l),\"label\":\"$i of 5 steps\"}]"
done

# A choice: buttons, and the click read back (as JSON) by the same script.
libertty +surface show ask --rows 3 --title "Next" \
  '[{"type":"text","text":"Build done. Ship it?"},{"type":"buttons","items":[{"id":"ship","label":"Ship","style":"primary"},{"id":"later","label":"Later"}]}]'
event=$(libertty +surface read --timeout 60) || { echo "no answer"; exit 0; }
case $event in
  *'"item":"ship"'*) echo "shipping" ;;
  *) echo "later then" ;;
esac
