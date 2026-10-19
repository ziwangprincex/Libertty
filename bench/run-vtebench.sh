#!/bin/zsh
# Run vtebench inside each terminal, one at a time.
# Each terminal opens a window, runs the benchmarks, writes results/<name>.dat, then closes.
#
#   ./run-vtebench.sh                 # all terminals
#   ./run-vtebench.sh kitty libertty     # just these
#   MAX_SECS=10 ./run-vtebench.sh     # longer runs (default 5s per benchmark)
set -u
cd "${0:A:h}"

BENCH=$PWD/vtebench
VTEBENCH=$BENCH/target/release/vtebench
RESULTS=$PWD/results
COLS=120 ROWS=40
MAX_SECS=${MAX_SECS:-5}
# Bytes per sample. vtebench times samples in whole milliseconds, so larger
# samples (8 MiB ≈ 50–150 ms) keep quantization error around 1–2%.
MIN_BYTES=${MIN_BYTES:-8388608}
LIBERTTY=${0:A:h:h}/build/Libertty.app/Contents/MacOS/Libertty

[[ -x $VTEBENCH ]] || { echo "build vtebench first: git submodule update --init vtebench && cd vtebench && git apply ../vtebench.patch && cargo build --release"; exit 1; }
mkdir -p $RESULTS

# The command every terminal runs, as a script so no terminal's own quoting matters.
# vtebench's stdout must stay the terminal: that output IS the benchmark.
# Results go to the .dat file (--silent stops the summary scrolling past);
# only stderr is captured.
write_job() {
  local name=$1 job=$RESULTS/$1.job.sh
  cat > $job <<EOF
#!/bin/sh
stty size > '$RESULTS/$name.size'
'$VTEBENCH' --silent -b '$BENCH/benchmarks' --min-bytes $MIN_BYTES --dat '$RESULTS/$name.dat' --max-secs $MAX_SECS 2> '$RESULTS/$name.log'
touch '$RESULTS/$name.done'
EOF
  chmod +x $job
  print -r -- $job
}

launch() {
  local name=$1 job=$(write_job $1)
  case $name in
    kitty)   /Applications/kitty.app/Contents/MacOS/kitty --single-instance=no \
               -o initial_window_width=${COLS}c -o initial_window_height=${ROWS}c \
               -o remember_window_size=no $job > /dev/null 2>&1 &! ;;
    ghostty) open -na /Applications/Ghostty.app --args \
               --window-width=$COLS --window-height=$ROWS --command=$job --wait-after-command=false ;;
    otty)    /Applications/Otty.app/Contents/MacOS/otty-cli open --quiet --command "$job" ;;
    tern)    /Applications/Tern.app/Contents/MacOS/tern -e $job > /dev/null 2>&1 &! ;;  # stays up after the job
    libertty)   $LIBERTTY --cols $COLS --rows $ROWS -e $job > /dev/null 2>&1 &! ;;
    # The everyday path: the shell in liberttyd, output relayed to the window.
    libertty-persist) $LIBERTTY --persist --cols $COLS --rows $ROWS -e $job > /dev/null 2>&1 &! ;;
    *)       echo "unknown terminal $name"; return 1 ;;
  esac
}

bundle_id() {
  case $1 in
    kitty) echo net.kovidgoyal.kitty ;; ghostty) echo com.mitchellh.ghostty ;;
    otty) echo io.appmakes.otty ;; tern) echo so.stencil.tern ;; libertty|libertty-persist) echo dev.libertty.terminal ;;
  esac
}

run_one() {
  local name=$1
  rm -f $RESULTS/$name.{dat,log,size,done}
  echo "== $name: launching"
  launch $name || return
  # A window parked in Stage Manager's strip may not draw; bring it forward
  # so every terminal pays for rendering what it receives.
  sleep 1
  osascript -e "tell application id \"$(bundle_id $name)\" to activate" 2>/dev/null
  # 12 benchmarks × MAX_SECS each, plus warmup; give generous headroom.
  local waited=0 limit=$(( MAX_SECS * 30 + 120 ))
  until [[ -e $RESULTS/$name.done ]]; do
    sleep 2; (( waited += 2 ))
    (( waited > limit )) && { echo "   timed out after ${limit}s"; return 1; }
  done
  echo "   done in ${waited}s, grid (rows cols): $(cat $RESULTS/$name.size 2>/dev/null)"
  # Sample sizes at this terminal's grid, for throughput in report.py.
  read r c < $RESULTS/$name.size
  script -q /dev/null ./payload-sizes.sh $c $r $MIN_BYTES < /dev/null | tr -d '\r\010' | sed 's/^\^D//' \
    | grep -E '^[a-z_]+ [0-9]+$' > $RESULTS/$name.bytes
}

for t in ${@:-libertty kitty ghostty otty tern}; do
  run_one $t
  sleep 3   # let the window close before the next terminal starts
done

echo "results in $RESULTS"
