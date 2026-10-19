#!/bin/sh
# Print "<benchmark> <bytes per sample>" for a grid of $1 cols × $2 rows, the
# way vtebench sizes samples: the generator's output, repeated to >= $3 bytes
# (vtebench --min-bytes, default 1 MiB).
# Run under a pty (the generators query the terminal size via /dev/tty).
cols=$1 rows=$2 min=${3:-1048576}
stty cols "$cols" rows "$rows"
for dir in "$(dirname "$0")"/vtebench/benchmarks/*/; do
  name=$(basename "$dir")
  # stderr must stay the terminal: tput reads the window size through it.
  n=$("$dir/benchmark" 2>/dev/tty | wc -c | tr -d ' ')
  [ "$n" -gt 0 ] || continue
  echo "$name $(( ( (min - 1) / n + 1 ) * n ))"
done
