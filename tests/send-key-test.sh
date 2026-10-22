#!/bin/zsh
# libertty +send-key against a private liberttyd (tests/run.sh sets
# LIBERTTY_DAEMON_SOCKET): the bytes each key sends, in both cursor key
# modes, and ctrl+c interrupting a program. Prints "send-key: all passed".
#   tests/send-key-test.sh LIBERTTY_BINARY
set -u
L=$1
fails=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; (( fails++ )); }
# Bytes a program reads raw, in hex, once it has COUNT of them.
dump() { print -r -- "sh -c '$1stty raw -echo; dd bs=1 count=$2 2>/dev/null | od -An -tx1; stty sane; sleep 10'"; }
seen() { $L +capture $1 | tr -s ' \n' ' ' | sed 's/^ //; s/ $//'; }

ID=$($L +new-session -e "$(dump '' 9)")
sleep 0.8
$L +send-key $ID ctrl+c enter up shift+a alt+f '?'
sleep 0.8
got=$(seen $ID)
[[ $got == "03 0d 1b 5b 41 41 1b 66 3f" ]] && ok "ctrl+c enter up shift+a alt+f ?" || bad "keys: $got"
$L +kill-session $ID > /dev/null

# A program that asked for application cursor keys gets them.
ID=$($L +new-session -e "$(dump 'printf "\033[?1h"; ' 3)")
sleep 0.8
$L +send-key $ID up
sleep 0.8
got=$(seen $ID)
[[ $got == "1b 4f 41" ]] && ok "up in application cursor mode" || bad "application cursor up: $got"
$L +kill-session $ID > /dev/null

# ctrl+c on a terminal in its usual mode interrupts the program.
ID=$($L +new-session -e "sh -c 'trap \"echo GOT-INT; sleep 10\" INT; while :; do sleep 0.1; done'")
sleep 0.8
$L +send-key $ID ctrl+c
sleep 0.8
[[ $(seen $ID) == *GOT-INT* ]] && ok "ctrl+c interrupts" || bad "ctrl+c didn't interrupt: $(seen $ID)"
$L +kill-session $ID > /dev/null

$L +send-key $ID bogus+x 2> /dev/null
[[ $? == 2 ]] && ok "an unknown key is refused" || bad "unknown key accepted"

(( fails == 0 )) && echo "send-key: all passed"
