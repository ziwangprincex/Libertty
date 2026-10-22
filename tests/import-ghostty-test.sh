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
(( fails == 0 )) && echo "import-ghostty: all passed"
