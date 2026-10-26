# Libertty shell integration for bash (3.2+).
#
# Written for Libertty from the protocol descriptions (FinalTerm OSC 133 semantic
# prompts, OSC 7 working directory); not derived from other terminals' scripts.
#
# Libertty starts bash as `bash --rcfile <this file> -i`: an interactive
# non-login bash reads its rc file instead of ~/.bashrc, which lets this file
# load without editing the user's. It then runs the startup files a login
# bash would have (/etc/profile runs macOS's path_helper, etc.) and installs
# the hooks. (`--posix` + ENV, the other way in, is ignored by macOS's bash 3.2.)

if [[ -n "${LIBERTTY_BASH_LOGIN-}" ]]; then
    builtin unset LIBERTTY_BASH_LOGIN
    # Login shell: /etc/profile, then the first of these that exists.
    [[ -r /etc/profile ]] && builtin source /etc/profile
    for _libertty_rc in ~/.bash_profile ~/.bash_login ~/.profile; do
        if [[ -r "$_libertty_rc" ]]; then
            builtin source "$_libertty_rc"
            break
        fi
    done
    builtin unset _libertty_rc
else
    [[ -r ~/.bashrc ]] && builtin source ~/.bashrc
fi

if [[ -z "${_LIBERTTY_BASH_INTEGRATED-}" ]]; then
    _LIBERTTY_BASH_INTEGRATED=1
    _libertty_command_ran=0
    _libertty_at_prompt=0
    _libertty_last_pwd=
    _libertty_clean_ps1=
    _libertty_marked_ps1=

    _libertty_report_pwd() {
        [[ "$PWD" == "$_libertty_last_pwd" ]] && return
        _libertty_last_pwd=$PWD
        local p=${PWD//%/%25}
        builtin printf '\e]7;file://%s%s\a' "${HOSTNAME}" "${p// /%20}"
    }

    # First in PROMPT_COMMAND, so $? is still the command's exit status.
    _libertty_precmd() {
        local status_=$?
        if (( _libertty_command_ran )); then
            builtin printf '\e]133;D;%d\a' "$status_"
            _libertty_command_ran=0
        fi
        _libertty_report_pwd
        return $status_
    }

    # Last in PROMPT_COMMAND: themes have built PS1 by now. Mark it from the
    # inside (\[…\] is zero-width to readline), so the marks come back
    # whenever bash redraws the prompt, and every line of a multi-line
    # prompt is marked: on resize Libertty clears exactly those rows.
    _libertty_prompt_end() {
        local status_=$?
        _libertty_at_prompt=1
        if [[ -n "$_libertty_marked_ps1" && "$PS1" == "$_libertty_marked_ps1" ]]; then
            PS1=$_libertty_clean_ps1
        fi
        _libertty_clean_ps1=$PS1
        local more='\[\e]133;P;k=s\a\]' nl=$'\n' ps1=$PS1
        ps1=${ps1//'\n'/'\n'$more}
        ps1=${ps1//$nl/$nl$more}
        PS1='\[\e]133;A;cl=line\a\]'"$ps1"'\[\e]133;B\a\]'
        _libertty_marked_ps1=$PS1
        return $status_
    }

    # DEBUG runs before every simple command. The first one after the prompt
    # is the start of the user's command line (one mark per line, even for
    # pipelines and lists). Works on every bash, including macOS's 3.2.
    _libertty_preexec() {
        # A `cd` earlier on the line (`cd proj && vim`): the folder now,
        # before the next command starts — zsh says it on chpwd.
        _libertty_report_pwd
        (( _libertty_at_prompt )) || return 0
        _libertty_at_prompt=0
        # An empty command line goes straight back to PROMPT_COMMAND: that's
        # a new prompt, not a command.
        [[ "$BASH_COMMAND" == _libertty_precmd* ]] && return 0
        _libertty_command_ran=1
        # The line as typed, from history (HISTCONTROL may leave it out: then none).
        local line
        line=$(HISTTIMEFORMAT= builtin history 1 2>/dev/null)
        line=${line#*[0-9] }
        line=${line#"${line%%[![:space:]]*}"}
        line=${line//%/%25}
        line=${line//;/%3B}
        line=${line//$'\n'/%0A}
        builtin printf '\e]133;C;cmdline_url=%s\a' "$line"
    }

    # TERM=xterm-ghostty is unknown to most remote hosts: ssh with a TERM
    # every host has (`ssh-env`). The user's own ssh function or alias wins.
    if [[ -n "${LIBERTTY_SSH_TERM-}" ]] && ! builtin declare -F ssh >/dev/null && ! builtin alias ssh >/dev/null 2>&1; then
        ssh() { TERM=$LIBERTTY_SSH_TERM command ssh "$@"; }
    fi

    if [[ "$(builtin declare -p PROMPT_COMMAND 2>/dev/null)" == "declare -a"* ]]; then
        PROMPT_COMMAND=(_libertty_precmd "${PROMPT_COMMAND[@]}" _libertty_prompt_end)   # bash 5.1+ array form
    else
        PROMPT_COMMAND="_libertty_precmd${PROMPT_COMMAND:+; $PROMPT_COMMAND}; _libertty_prompt_end"
    fi

    # Don't replace a DEBUG trap the user (or a framework like bash-preexec)
    # set: prompts and cwd still work, command start/end marks don't.
    if [[ -z "$(builtin trap -p DEBUG)" ]]; then
        builtin trap '_libertty_preexec' DEBUG
    fi
fi
