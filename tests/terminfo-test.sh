#!/bin/zsh
# libertty +terminfo and the ssh it gives a TERM to, against a stand-in ssh
# whose "host" is a folder here (its own HOME and no terminfo of ours):
# prints "terminfo: all passed" or what failed.
#   tests/terminfo-test.sh LIBERTTY_BINARY
set -u
L=$1
T=$(mktemp -d)
trap 'rm -rf $T' EXIT
fails=0
ok() { echo "ok    $1"; }
bad() { echo "FAIL  $1"; (( fails++ )); }

mkdir -p $T/remote $T/data $T/config/libertty
# ssh -G answers what a host resolves to; anything else runs the command
# "there": in $T/remote's HOME, knowing no terminfo but its own.
cat > $T/ssh <<'SSH'
#!/bin/sh
if [ "$1" = -G ]; then
  shift
  while [ $# -gt 1 ]; do shift; done
  printf 'user me\nhostname %s.example\nport 22\n' "$1"; exit 0
fi
while [ $# -gt 0 ]; do case "$1" in -o|-p|-l) shift 2 ;; -*) shift ;; *) break ;; esac; done
host=$1; shift
echo "$host" >> "$FAKE_REMOTE/connections"
exec env -u TERMINFO -u TERMINFO_DIRS HOME="$FAKE_REMOTE" /bin/sh -c "$*"
SSH
chmod +x $T/ssh
export LIBERTTY_SSH=$T/ssh FAKE_REMOTE=$T/remote LIBERTTY_DATA_DIR=$T/data XDG_CONFIG_HOME=$T/config
unset LIBERTTY_SSH_TERM

[[ $($L +terminfo status) == *"No hosts"* ]] && ok "status: none yet" || bad "status before"
$L +terminfo setup box > $T/setup.txt 2>&1 && ok "setup box" || bad "setup: $(cat $T/setup.txt)"
env -u TERMINFO -u TERMINFO_DIRS HOME=$T/remote infocmp xterm-ghostty > /dev/null 2>&1 \
  && ok "the host knows xterm-ghostty now (its ~/.terminfo)" || bad "not installed there"
[[ $($L +terminfo status) == "me@box.example:22" ]] && ok "status: remembered as ssh resolves it" || bad "status: $($L +terminfo status)"
[[ $($L +terminfo ssh-term -- box) == xterm-ghostty ]] && ok "ssh to it: TERM=xterm-ghostty" || bad "ssh-term box"
[[ $(LIBERTTY_SSH_TERM=xterm-256color $L +terminfo ssh-term -- other) == xterm-256color ]] \
  && ok "another host: ssh-env's TERM" || bad "ssh-term other"
# ssh-terminfo: a login installs it; a command, or -N, doesn't.
print 'ssh-terminfo = true' > $T/config/libertty/config
rm -f $T/remote/connections
[[ $(LIBERTTY_SSH_TERM=xterm-256color $L +terminfo ssh-term -- -p 2222 cmdhost uptime 2>/dev/null) == xterm-256color ]] \
  && [[ ! -e $T/remote/connections ]] && ok "ssh-terminfo: not for a command" || bad "installed for a command"
[[ $(LIBERTTY_SSH_TERM=xterm-256color $L +terminfo ssh-term -- -N fwd 2>/dev/null) == xterm-256color ]] \
  && [[ ! -e $T/remote/connections ]] && ok "ssh-terminfo: not for -N" || bad "installed for -N"
[[ $(LIBERTTY_SSH_TERM=xterm-256color $L +terminfo ssh-term -- -l me newhost 2>/dev/null) == xterm-ghostty ]] \
  && ok "ssh-terminfo: a login installs it first" || bad "ssh-terminfo login"
$L +terminfo status | grep -q "me@newhost.example:22" && ok "…and remembers it" || bad "not remembered"
$L +terminfo forget box && ! $L +terminfo status | grep -q box && ok "forget" || bad "forget"
$L +terminfo show | grep -q "^xterm-ghostty|" && ok "show: the source" || bad "show"
$L +terminfo bogus > /dev/null 2>&1; [[ $? == 2 ]] && ok "usage: 2" || bad "usage status"

# The shell integration's ssh takes the TERM +terminfo ssh-term says (a
# stand-in libertty and ssh on PATH).
mkdir -p $T/bin
printf '#!/bin/sh\necho xterm-ghostty\n' > $T/bin/libertty
printf '#!/bin/sh\necho "TERM=$TERM args=$*"\n' > $T/bin/ssh
chmod +x $T/bin/*
R=${0:A:h:h}/Resources/shell-integration
for sh in zsh bash; do
  if [[ $sh == zsh ]]; then
    out=$(PATH=$T/bin:$PATH LIBERTTY_SSH_TERM=xterm-256color LIBERTTY_SSH_TERMINFO=auto zsh -fc "source $R/zsh/libertty-integration.zsh; ssh -p 22 box" 2>/dev/null)
  else
    out=$(PATH=$T/bin:$PATH LIBERTTY_SSH_TERM=xterm-256color LIBERTTY_SSH_TERMINFO=auto bash --norc -c "source $R/bash/libertty.bash; ssh box" 2>/dev/null)
  fi
  [[ $out == *"TERM=xterm-ghostty args="* ]] && ok "$sh's ssh: the TERM +terminfo says" || bad "$sh's ssh: $out"
done
# Without ssh-terminfo and no host that has it: ssh-env's TERM, libertty not asked.
out=$(PATH=$T/bin:$PATH LIBERTTY_SSH_TERM=xterm-256color LIBERTTY_SSH_TERMINFO=known LIBERTTY_TERMINFO_HOSTS=$T/none \
  zsh -fc "source $R/zsh/libertty-integration.zsh; ssh box" 2>/dev/null)
[[ $out == *"TERM=xterm-256color args="* ]] && ok "no hosts known: libertty isn't asked" || bad "known, none: $out"

(( fails == 0 )) && echo "terminfo: all passed" || echo "terminfo: $fails failed"
