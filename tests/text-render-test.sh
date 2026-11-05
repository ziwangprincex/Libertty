#!/bin/zsh
# minimum-contrast, adjust-cell-height and -width, palette-generate, cursor-text and
# selection-foreground in snapshots' pixels: dark text on the dark
# background comes out white once a contrast is asked for, box drawing keeps
# its color; the cells grow by the pixels or the percentage; the 256 colors'
# cube runs from the theme's background to its text color; the text under
# the cursor, and selected text, take their colors.
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
# adjust-cell-width: the columns grow by the pixels or the percentage, the rows don't.
width() {  # ADJUST → the snapshot's width in pixels (10 columns, 40 px of padding)
  $L --snapshot $OUT/cell-width-${1:-none}.png --cols 10 --rows 2 --font-size 13 --set window-padding-x=10 \
    --set adjust-cell-width=$1 -- "printf '\033[?25lHello'; sleep 0.2" > /dev/null
  sips -g pixelWidth $OUT/cell-width-${1:-none}.png | awk '/pixelWidth/ { print $2 }'
}
wbase=$(width "") wplus=$(width 2) wless=$(width -2)
(( wplus == wbase + 20 )) && ok "adjust-cell-width 2: 2 px more a column" || bad "adjust-cell-width 2: $wbase → $wplus"
(( wless == wbase - 20 )) && ok "adjust-cell-width -2: 2 px less a column" || bad "adjust-cell-width -2: $wbase → $wless"
# palette-generate: color 231 (the cube's far corner) is the theme's text
# color, 16 its background, instead of xterm's white and black.
cube() {  # GENERATE INDEX → the color of a cell in palette INDEX
  $L --snapshot $OUT/palette-$1-$2.png --cols 10 --rows 2 --font-size 13 --set window-padding-x=10 \
    --set window-padding-y=6 --set palette-generate=$1 --pixels 28,29 -- "printf '\033[?25l\033[48;5;$2m    '; sleep 0.2" \
    | awk '/^pixel/ { print $3 }'
}
[[ $(cube false 231) == "#ffffff" && $(cube false 16) == "#000000" ]] && ok "palette-generate off: xterm's cube" || bad "palette-generate off: $(cube false 231) $(cube false 16)"
[[ $(cube true 231) == "#e6e6e6" && $(cube true 16) == "#1c1c1e" ]] && ok "palette-generate: the cube from the theme's colors" || bad "palette-generate: $(cube true 231) $(cube true 16)"
# cursor-text: the character under a block cursor in that color, instead
# of the background's.
under() {  # CURSOR_TEXT → the first cell's pixels, a steady block cursor on it
  local name=${1#\#} extra=()
  [[ -n $1 ]] && extra=(--set cursor-text=$1)
  $L --snapshot $OUT/cursor-text-${name:-none}.png --cols 10 --rows 2 --font-size 13 --set window-padding-x=10 \
    --set window-padding-y=6 $extra --pixels ${points#;} -- "printf '\033[2 q########\r'; sleep 0.2" \
    | awk '/^pixel/ { print $3 }'
}
[[ $(under '#ff0000') == *'#ff0000'* ]] && ok "cursor-text: the character under the cursor in its color" || bad "cursor-text: no #ff0000 under the cursor"
[[ $(under '') != *'#ff0000'* && $(under '') == *'#1c1c1e'* ]] && ok "cursor-text unset: the background's color" || bad "cursor-text unset: not the background"
# selection-foreground: selected text in that color, instead of its own.
selected() {  # SELECTION_FOREGROUND → the first cell's pixels, everything selected
  local name=${1#\#} extra=()
  [[ -n $1 ]] && extra=(--set selection-foreground=$1)
  $L --snapshot $OUT/selection-foreground-${name:-none}.png --cols 10 --rows 2 --font-size 13 --set window-padding-x=10 \
    --set window-padding-y=6 $extra --select-all --pixels ${points#;} -- "printf '\033[?25l########'; sleep 0.2" \
    | awk '/^pixel/ { print $3 }'
}
[[ $(selected '#00ff00') == *'#00ff00'* ]] && ok "selection-foreground: selected text in its color" || bad "selection-foreground: no #00ff00 in the selection"
[[ $(selected '') != *'#00ff00'* ]] && ok "selection-foreground unset: selected text keeps its color" || bad "selection-foreground unset: changed"
(( fails == 0 )) && echo "text-render: all passed"
