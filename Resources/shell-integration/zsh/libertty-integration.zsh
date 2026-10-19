# Libertty shell integration for zsh.
#
# Written for Libertty from the protocol descriptions (FinalTerm OSC 133 semantic
# prompts, OSC 7 working directory); not derived from other terminals' scripts.
#
#   OSC 133;A;cl=line  a prompt starts       (Libertty clears OSC 7501 working/blocked records)
#   OSC 133;P;k=s      a continuation line of a multi-line prompt
#   OSC 133;B          input starts
#   OSC 133;C;cmdline_url=…  the command's output starts (and what it was)
#   OSC 133;D;<n>      the command finished with exit status n
#   OSC 7;file://      the shell's working directory
#
# The prompt marks live inside PS1 (as %{…%}, zero-width to zsh), so zsh
# re-emits them every time it redraws the prompt: after a window resize, on
# reset-prompt, on job notifications. On resize Libertty (libghostty-vt) clears
# the marked prompt rows and zsh redraws them in place, instead of leaving
# the old prompt behind.

[[ -n "${_LIBERTTY_ZSH_INTEGRATED-}" ]] && builtin return
builtin typeset -g _LIBERTTY_ZSH_INTEGRATED=1
builtin typeset -gi _libertty_command_ran=0
builtin typeset -g _libertty_clean_ps1 _libertty_clean_ps2 _libertty_marked_ps1

_libertty_report_pwd() {
    # Percent-encode what a file URL can't carry literally.
    builtin local p="${PWD//\%/%25}"
    p="${p// /%20}"
    builtin printf '\e]7;file://%s%s\a' "${HOST}" "$p"
}

# First precmd hook: it still sees the command's exit status.
_libertty_status() {
    builtin local status_=$?
    if (( _libertty_command_ran )); then
        builtin printf '\e]133;D;%d\a' "$status_"
        _libertty_command_ran=0
    fi
    builtin return $status_
}

# Last precmd hook: themes have built this prompt's PS1 by now; mark it.
_libertty_mark_prompt() {
    builtin local status_=$?
    # Stay last, even if a plugin added a hook after us.
    if [[ ${precmd_functions[-1]} != _libertty_mark_prompt ]]; then
        precmd_functions=(${precmd_functions:#_libertty_mark_prompt} _libertty_mark_prompt)
    fi
    if [[ -o prompt_percent ]]; then
        # Start from the unmarked prompt: ours from last time if nothing
        # changed it, else whatever the theme just set.
        if [[ -n "$_libertty_marked_ps1" && "$PS1" == "$_libertty_marked_ps1" ]]; then
            PS1=$_libertty_clean_ps1
            PS2=$_libertty_clean_ps2
        fi
        _libertty_clean_ps1=$PS1
        _libertty_clean_ps2=$PS2

        builtin local start=$'%{\e]133;A;cl=line\a%}' more=$'%{\e]133;P;k=s\a%}' input=$'%{\e]133;B\a%}'
        builtin local ps1=$PS1 ps2=$PS2
        # A trailing lone % would swallow the { of the next mark.
        [[ "$ps1" == *[^%]% || "$ps1" == % ]] && ps1+=%
        [[ "$ps2" == *[^%]% || "$ps2" == % ]] && ps2+=%
        ps1=${ps1//$'\n'/$'\n'$more}
        PS1="${start}${ps1}${input}"
        PS2="${more}${ps2}${input}"
        _libertty_marked_ps1=$PS1
    else
        # Prompt escapes are off: mark the prompt once, from here.
        builtin printf '\e]133;A;cl=line\a'
    fi
    builtin return $status_
}

# A command line in percent-encoding (OSC 133 cmdline_url): only what can
# end or confuse the sequence is escaped.
_libertty_urlencode() {
    builtin local s=$1
    s=${s//\%/%25}
    s=${s//;/%3B}
    s=${s//$'\n'/%0A}
    s=${s//$'\a'/%07}
    s=${s//$'\e'/%1B}
    builtin print -rn -- "$s"
}

_libertty_preexec() {
    # Show the user's own prompt to anything inspecting PS1 while it runs.
    if [[ "$PS1" == "$_libertty_marked_ps1" ]]; then
        PS1=$_libertty_clean_ps1
        PS2=$_libertty_clean_ps2
    fi
    _libertty_command_ran=1
    # $1 is the command line as typed (for "make test finished" notifications).
    builtin printf '\e]133;C;cmdline_url=%s\a' "$(_libertty_urlencode "$1")"
}

# TERM=xterm-ghostty is unknown to most remote hosts: ssh with a TERM every
# host has (`ssh-env`). The user's own ssh function or alias wins.
if [[ -n "${LIBERTTY_SSH_TERM-}" ]] && (( ! $+functions[ssh] )) && (( ! $+aliases[ssh] )); then
    ssh() { TERM=$LIBERTTY_SSH_TERM command ssh "$@"; }
fi

builtin autoload -Uz add-zsh-hook
add-zsh-hook chpwd _libertty_report_pwd
add-zsh-hook preexec _libertty_preexec
precmd_functions=(_libertty_status ${precmd_functions:#(_libertty_status|_libertty_mark_prompt)} _libertty_mark_prompt)

_libertty_report_pwd
