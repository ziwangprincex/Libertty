#!/bin/zsh
# libertty +wait --until / +capture --ansi|--html / +events, against a private
# liberttyd (tests/run.sh sets LIBERTTY_DAEMON_SOCKET): prints
# "cli-wait: all passed" or what failed.
#   tests/cli-wait-test.sh LIBERTTY_BINARY
set -u
L=$1
T=$(mktemp -d)
trap 'rm -rf $T' EXIT
fails=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; (( fails++ )); }
now() { perl -MTime::HiRes=time -e 'printf "%.3f", time'; }
took() { perl -e "printf '%.2f', $(now) - $1"; }

# One session keeps liberttyd up while the listener starts.
KEEP=$($L +new-session --cwd /tmp -e sleep 60)
perl -e 'alarm 60; exec @ARGV' $L +events > $T/events 2>&1 &
EV=$!
sleep 0.5
ID=$($L +new-session --cwd /tmp)

$L +wait $ID --until prompt --timeout 20 && ok "a new shell reaches its prompt" || bad "first prompt"
s=$(now); $L +wait $ID --until prompt --timeout 5
[[ $? == 0 && $(took $s) < 0.5 ]] && ok "at the prompt already: at once" || bad "already at the prompt"

$L +send $ID 'sleep 1; echo one\n'
s=$(now); $L +wait $ID --until prompt --timeout 10; r=$?; d=$(took $s)
(( r == 0 && d >= 0.8 )) && ok "after +send, the next prompt (${d}s)" || bad "next prompt after +send: exit $r in ${d}s"

$L +send $ID 'for i in 1 2 3; do echo tick; sleep 0.3; done\n'
s=$(now); $L +wait $ID --until idle=600 --timeout 10; r=$?; d=$(took $s)
(( r == 0 && d >= 1.2 )) && ok "quiet for 600 ms (${d}s)" || bad "idle: exit $r in ${d}s"

$L +send $ID 'sleep 4\n'
s=$(now); $L +wait $ID --until prompt --timeout 1; r=$?; d=$(took $s)
(( r == 124 && d < 2 )) && ok "out of time: 124" || bad "timeout: exit $r in ${d}s"
$L +wait $ID --until prompt --timeout 10

# An absurd quiet time is clamped, not trusted: the daemon must live (and keep this session).
$L +wait $ID --until idle=9000000000000000 --timeout 1 > /dev/null 2>&1
$L +list-sessions 2>/dev/null | grep -q "$ID" && ok "a huge idle= leaves liberttyd running" || bad "liberttyd died on a huge idle="

$L +send $ID 'printf "\\033[31mRED\\033[0m\\n"\n'
$L +wait $ID --until prompt --timeout 5
$L +capture $ID --ansi | grep -q $'\e\\[' && ok "capture --ansi keeps the colors" || bad "capture --ansi"
$L +capture $ID --html > $T/page.html
grep -q '<!doctype html>' $T/page.html && grep -q 'rgb(' $T/page.html && ok "capture --html is a page with colors" \
  || bad "capture --html"
$L +capture $ID --html --ansi > /dev/null 2>&1; [[ $? == 2 ]] && ok "--html and --ansi together: refused" || bad "both formats"

( $L +wait $ID --timeout 10; echo $? > $T/exit ) &
sleep 0.3
$L +send $ID 'exit 7\n'
sleep 1
[[ $(cat $T/exit 2>/dev/null) == 7 ]] && ok "+wait: the program's exit status" || bad "exit status: $(cat $T/exit 2>/dev/null)"

$L +kill-session $KEEP
sleep 0.5
kill $EV 2>/dev/null
for kind in session-started prompt command-started command-finished directory session-ended; do
  grep -q "\"event\":\"$kind\"" $T/events && ok "event $kind" || bad "no $kind event"
done
grep -q '"command":"sleep 1; echo one"' $T/events && ok "command-started says what ran" || bad "command line in events"

(( fails == 0 )) && echo "cli-wait: all passed" || echo "cli-wait: $fails failed"
