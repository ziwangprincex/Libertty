#!/bin/sh
# Renderer showcase for `Libertty --snapshot`: one line per feature.
e=$(printf '\033')
printf '%s[1mLibertty%s[0m renderer check  %s[2m(faint)%s[0m\r\n' "$e" "$e" "$e" "$e"
printf 'styles: %s[1mbold%s[0m %s[3mitalic%s[0m %s[1;3mbold-italic%s[0m %s[4munderline%s[0m %s[4:2mdouble%s[0m %s[9mstrike%s[0m %s[7minverse%s[0m\r\n' \
  "$e" "$e" "$e" "$e" "$e" "$e" "$e" "$e" "$e" "$e" "$e" "$e" "$e" "$e"
printf 'ansi16: '
for c in 30 31 32 33 34 35 36 37 90 91 92 93 94 95 96 97; do printf '%s[%sm██%s[0m' "$e" "$c" "$e"; done
printf '\r\n256:    '
for c in 16 52 88 124 160 196 202 208 214 220 226 190 154 118 82 46 47 48 49 50 51 45 39 33 27 21 57 93 129 165 201 199; do
  printf '%s[48;5;%sm  %s[0m' "$e" "$c" "$e"
done
printf '\r\ntruecolor: '
i=0
while [ $i -lt 48 ]; do
  r=$((255 - i * 5)); g=$((i * 5)); b=$((128 + i * 2))
  printf '%s[48;2;%s;%s;%sm %s[0m' "$e" "$r" "$g" "$b" "$e"
  i=$((i + 1))
done
printf '\r\n中文: 你好，世界！终端渲染测试  日本語: こんにちは  한국어: 안녕하세요\r\n'
printf 'emoji: 👍 👍🏽 🚀 🎉 👨‍👩‍👧 🇨🇳  symbols: → ⇒ ≠ ≤ ∞ λ ✓ ✗\r\n'
printf 'box: ┌──┬──┐ ╭──╮ ▁▂▃▄▅▆▇█  braille: ⣿⣶⣤⣀\r\n'
printf '     └──┴──┘ ╰──╯ ░▒▓█\r\n'
printf 'code: fn main() { let x = 42; println!("{x}"); } // -> != ==\r\n'
# Nerd Font / Powerline glyphs as UTF-8 octal escapes:  U+F179  U+E0B0  U+F07C  U+F418  U+E0B6/E0B4
printf 'nerd: %s[48;5;208;30m \357\205\271 prince %s[48;5;214;38;5;208m\356\202\260%s[30m \357\201\274 ~ %s[0;38;5;214m\356\202\260%s[0m \357\220\230 main \356\202\266\356\202\264\r\n' "$e" "$e" "$e" "$e" "$e"
# OSC 7501 program status (rendered in window chrome, not the grid)
printf '%s]7501;state=working:app=cargo:msg=QnVpbGRpbmc=%s\\' "$e" "$e"
printf 'cursor below:\r\n'
