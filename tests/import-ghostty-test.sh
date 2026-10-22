#!/bin/zsh
# libertty +import-ghostty from a Ghostty config of its own (with an include),
# into a Libertty config of its own: prints "import-ghostty: all passed".
#   tests/import-ghostty-test.sh LIBERTTY_BINARY
set -u
L=$1
T=$(mktemp -d)
trap 'rm -rf $T' EXIT
fails=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; (( fails++ )); }
mkdir -p $T/ghostty $T/cfg/libertty
print -r -- '# Ghostty
font-family = "JetBrains Mono"
font-family = Symbols Nerd Font
font-size = 15
keybind = cmd+shift+k=clear_screen
macos-titlebar-style = tabs
cursor-style = blink-dance
background-opacity = 0.9
config-file = extra.conf' > $T/ghostty/config.ghostty
print -r -- 'window-padding-x = 12
palette = 1=#ff0000' > $T/ghostty/extra.conf
print -r -- 'font-size = 13
keybind = cmd+shift+k=clear_screen' > $T/cfg/libertty/config
export XDG_CONFIG_HOME=$T/cfg
out=$($L +import-ghostty --from $T/ghostty/config.ghostty --yes)
f=$T/cfg/libertty/config
grep -qx 'font-family = "JetBrains Mono"' $f && ok "the first font-family" || bad "font-family: $(grep font-family $f)"
grep -q 'Symbols Nerd Font' $f && bad "a fallback font came over" || ok "fallback fonts stay out"
[[ $(grep -c '^font-size' $f) == 1 ]] && grep -qx 'font-size = 13' $f && ok "Libertty's own font-size kept" || bad "font-size"
grep -qx 'window-padding-x = 12' $f && grep -qx 'palette = 1=#ff0000' $f && ok "the included file's settings" || bad "include"
[[ $(grep -c 'cmd+shift+k' $f) == 1 ]] && ok "a keybind already there isn't doubled" || bad "keybind doubled"
grep -q 'macos-titlebar-style\|blink-dance' $f && bad "unknown or refused settings written" || ok "unknown and refused settings left out"
[[ $out == *"macos-titlebar-style"* && $out == *"blink-dance"* ]] && ok "and listed" || bad "not listed: $out"
ls $T/cfg/libertty/config.before-ghostty-import-* > /dev/null 2>&1 && ok "the old config kept" || bad "no backup"
$L +validate-config > /dev/null && ok "the result validates" || bad "invalid result"
[[ $($L +import-ghostty --from $T/ghostty/config.ghostty --yes) == *"Nothing to add."* ]] && ok "again: nothing to add" || bad "not idempotent"

# Ghostty's way with resets, includes and CRLF lines; what would wipe or
# override Libertty's own stays out.
mkdir -p $T/g2 $T/cfg2/libertty
print -r -- 'font-family = Menlo
font-family = ""
font-family = "Fira Code"
config-file = theme.conf
background = #111111
keybind = clear
keybind = cmd+shift+j=clear_screen
keybind = cmd+shift+u=scroll_to_top
palette = 2=#00ff00
palette = 3=#0000ff
font-feature =' | perl -pe 's/\n/\r\n/' > $T/g2/config
print -r -- 'background = #222222' > $T/g2/theme.conf
print -r -- 'keybind = cmd+shift+j=new_tab
palette = 2=#abcdef' > $T/cfg2/libertty/config
export XDG_CONFIG_HOME=$T/cfg2
out=$($L +import-ghostty --from $T/g2/config --yes)
f=$T/cfg2/libertty/config
grep -qx 'font-family = "Fira Code"' $f && ok "the first font-family after a reset" || bad "font-family after reset: $(grep font-family $f)"
grep -qx 'background = #222222' $f && ok "an included file read after its includer" || bad "include order: $(grep '^background' $f)"
grep -q '^keybind = clear' $f && bad "keybind = clear written" || ok "keybind = clear left out"
[[ $out == *"would clear"* ]] && ok "and said so" || bad "clear not listed: $out"
grep -q '^font-feature' $f && bad "an empty font-feature written" || ok "an empty reset left out"
[[ $(grep -c 'cmd+shift+j' $f) == 1 ]] && grep -qx 'keybind = cmd+shift+j=new_tab' $f && ok "Libertty's own binding of a key kept" \
  || bad "keybind override: $(grep cmd+shift+j $f)"
grep -qx 'keybind = cmd+shift+u=scroll_to_top' $f && ok "a new binding added" || bad "new keybind missing"
[[ $(grep -c '^palette = 2=' $f) == 1 ]] && grep -qx 'palette = 3=#0000ff' $f && ok "Libertty's own palette color kept, others added" \
  || bad "palette: $(grep palette $f)"
$L +validate-config > /dev/null && ok "the result validates" || bad "invalid result"

(( fails == 0 )) && echo "import-ghostty: all passed"
