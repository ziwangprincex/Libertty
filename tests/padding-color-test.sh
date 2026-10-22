#!/bin/zsh
# window-padding-color in snapshots' pixels: the padding in the background
# color, or the colors of the cells at the grid's edges carried out (extend,
# with its exceptions; extend-always). Prints "padding-color: all passed".
#   tests/padding-color-test.sh LIBERTTY_BINARY OUTDIR
set -u
L=$1 OUT=$2
fails=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; (( fails++ )); }
# 20×4 cells: 20 px of padding at the sides, 12 above, 16 below, 16×35 px cells.
# Points: above the grid at the left, in the first row, left of the third,
# in it, right of it, below the grid at the right, in the last row, below it at the left.
POINTS='2,2;30,29;2,99;30,99;355,99;355,165;100,134;2,165'
colors() {  # MODE COMMAND → the points' colors, space-separated
  $L --snapshot $OUT/padding-$1-$3.png --cols 20 --rows 4 --set window-padding-color=$1 --pixels $POINTS -- "$2" \
    | awk '/^pixel/ { printf "%s ", $3 }'
}
plain='printf "\033[?25l\033[44m\033[2K\033[0m\nplain\n\033[41m    \033[0m\n\033[42m\033[2K\033[0m"; sleep 0.2'
# Background: every padding point is the background, like the plain row's.
c=(${(s: :)$(colors background $plain a)})
[[ $c[1] == $c[3] && $c[3] == $c[5] && $c[6] == $c[1] && $c[8] == $c[1] && $c[2] != $c[1] ]] \
  && ok "background: the padding is the background" || bad "background: $c"
# Extend: blue up from the first row, red left of the third (not right: its
# last cells are the background's), green down and to the right of the last.
c=(${(s: :)$(colors extend $plain a)})
[[ $c[1] == $c[2] && $c[3] == $c[4] && $c[5] != $c[4] && $c[6] == $c[7] && $c[8] == $c[7] ]] \
  && ok "extend: the edge cells' colors" || bad "extend: $c"
# A row with cells in the background, or a powerline glyph, keeps the
# padding above or below it; its sides still take the edge cells' colors.
mixed='printf "\033[?25l\033[44m    \033[0m\nplain\n\033[41m    \033[0m\n\033[42m\033[2K\356\202\260\033[0m"; sleep 0.2'
c=(${(s: :)$(colors extend $mixed b)})
[[ $c[1] != $c[2] && $c[6] != $c[7] && $c[3] == $c[4] ]] \
  && ok "extend: not past a row of mixed cells or powerline" || bad "extend, mixed rows: $c"
c=(${(s: :)$(colors extend-always $mixed b)})
[[ $c[1] == $c[2] && $c[6] == $c[7] ]] && ok "extend-always: every edge" || bad "extend-always: $c"
# A full-screen program's edges are carried out as they are.
alt='printf "\033[?1049h\033[?25l\033[H\033[44m    \033[0m"; sleep 0.2'
c=(${(s: :)$(colors extend $alt c)})
[[ $c[1] == $c[2] ]] && ok "extend: a full-screen program's top row" || bad "extend, alternate screen: $c"
(( fails == 0 )) && echo "padding-color: all passed"
