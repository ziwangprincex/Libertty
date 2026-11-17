#!/bin/zsh
# libertty +ports and the `ports` event: liberttyd finds what a session's
# programs listen on by itself, names the program by its script, and says so
# when it goes. Against a private liberttyd (tests/run.sh sets
# LIBERTTY_DAEMON_SOCKET); prints "ports: all passed" or what failed.
#   tests/ports-test.sh LIBERTTY_BINARY
set -u
L=$1
T=$(mktemp -d)
trap 'rm -rf $T' EXIT
fails=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; (( fails++ )); }
# Until the file holds the pattern, or the seconds run out.
await() {  # await SECONDS FILE PATTERN
  local left=$(( $1 * 10 ))
  while (( left-- > 0 )); do
    grep -qE -- "$3" $2 2> /dev/null && return 0
    sleep 0.1
  done
  return 1
}

PORT=$(python3 -c 'import socket; s = socket.socket(); s.bind(("127.0.0.1", 0)); print(s.getsockname()[1]); s.close()')
ID=$($L +new-session --cwd /tmp)
$L +wait $ID --until prompt --timeout 20

$L +ports $ID | grep -q "nothing listening" && ok "a shell at its prompt listens to nothing" || bad "idle session: $($L +ports $ID)"

# The events come on liberttyd's own cadence: nobody asks for a scan here.
perl -e 'alarm 60; exec @ARGV' $L +events --filter ports > $T/events 2>&1 &
sleep 0.5
$L +send $ID "python3 -m http.server $PORT --bind 127.0.0.1\n"
await 30 $T/events "\"port\":$PORT" && ok "a server's port, told as an event" || bad "no ports event in 30s: $(cat $T/events)"
grep -q '"label":"http.server"' $T/events && ok "the script names it, not python3" || bad "label: $(cat $T/events)"

$L +ports $ID > $T/table
grep -qE "^$PORT +127\.0\.0\.1 +[0-9]+ +http\.server$" $T/table && ok "+ports: port, address, pid, label" || bad "+ports: $(cat $T/table)"
grep -q "PORT   ADDRESS" $T/table && ok "+ports has a header" || bad "+ports header: $(cat $T/table)"
$L +ports | grep -q "^SESSION" && ok "+ports without a session says which" || bad "+ports (every session): $($L +ports)"
$L +ports $ID --json | grep -q "\"port\" : $PORT" && ok "+ports --json" || bad "+ports --json: $($L +ports $ID --json)"

# It goes when the server does.
$L +send-key $ID ctrl+c
await 30 $T/events "\"ports\":\\[\\]" && ok "the port goes when the server does" || bad "no empty ports event in 30s: $(cat $T/events)"
$L +ports $ID | grep -q "nothing listening" && ok "+ports after it ended" || bad "+ports after the kill: $($L +ports $ID)"

$L +ports nosuch > /dev/null 2>&1; [[ $? == 3 ]] && ok "no such session: 3" || bad "+ports nosuch: $?"
$L +ports --wrong > /dev/null 2>&1; [[ $? == 2 ]] && ok "an unknown flag: 2" || bad "+ports --wrong: $?"

$L +kill-session $ID
(( fails == 0 )) && echo "ports: all passed" || echo "ports: $fails failed"
