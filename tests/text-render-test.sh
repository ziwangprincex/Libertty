#!/bin/zsh
# minimum-contrast and adjust-cell-height in snapshots' pixels: dark text on
# the dark background comes out white once a contrast is asked for, box
# drawing keeps its color; the cells grow by the pixels or the percentage.
# Prints "text-render: all passed".
#   tests/text-render-test.sh LIBERTTY_BINARY OUTDIR
set -u
L=$1 OUT=$2
fails=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; (( fails++ )); }
# A column of points down the middle of the first cell (16×35 px, 20 px of
# padding at the left, 12 above): its brightest pixel is the text's color.
points=""
for y in {12..46..2}; do points="$points;26,$y;28,$y;30,$y"; done
brightest() {  # NAME CONTRAST TEXT → the brightest of the points
  $L --snapshot $OUT/contrast-$1.png --cols 10 --rows 2 --font-size 13 --set window-padding-x=10 \
    --set window-padding-y=6 --set minimum-contrast=$2 --pixels ${points#;} -- "printf '\033[?25l\033[38;2;40;40;50m$3'; sleep 0.2" \
    | awk '/^pixel/ { print $3 }' | sort | tail -1
}
[[ $(brightest off 1 '########') != "#ffffff" ]] && ok "minimum-contrast 1: dark text stays dark" || bad "minimum-contrast 1 changed the text"
[[ $(brightest on 4.5 '########') == "#ffffff" ]] && ok "minimum-contrast 4.5: dark text on dark is white" || bad "minimum-contrast 4.5: not white"
[[ $(brightest box 4.5 '││││') != "#ffffff" ]] && ok "minimum-contrast: box drawing keeps its color" || bad "minimum-contrast changed box drawing"
height() {  # ADJUST → the snapshot's height in pixels (4 rows, 28 px of padding)
  $L --snapshot $OUT/cell-height-${1:-none}.png --cols 10 --rows 4 --font-size 13 --set window-padding-y=6 \
    --set adjust-cell-height=$1 -- "printf '\033[?25lHello'; sleep 0.2" > /dev/null
  sips -g pixelHeight $OUT/cell-height-${1:-none}.png | awk '/pixelHeight/ { print $2 }'
}
base=$(height "") plus=$(height 10) half=$(height 50%) less=$(height -4)
(( plus == base + 40 )) && ok "adjust-cell-height 10: 10 px more a row" || bad "adjust-cell-height 10: $base → $plus"
cell=$(( (base - 28) / 4 ))
(( half == 28 + 4 * ((cell * 3 + 1) / 2) )) && ok "adjust-cell-height 50%: half again, rounded" || bad "adjust-cell-height 50%: $base → $half"
(( less == base - 16 )) && ok "adjust-cell-height -4: 4 px less a row" || bad "adjust-cell-height -4: $base → $less"
(( fails == 0 )) && echo "text-render: all passed"
