# Libertty shell integration for fish (3.0+).
#
# Written for Libertty from the protocol descriptions (FinalTerm OSC 133 semantic
# prompts, OSC 7 working directory); not derived from other terminals' scripts.
#
# fish sources every vendor_conf.d/*.fish on its XDG_DATA_DIRS; Libertty prepends
# its own directory there, so this loads without touching the user's config.

status is-interactive; or exit 0
set -q _LIBERTTY_FISH_INTEGRATED; and exit 0
set -g _LIBERTTY_FISH_INTEGRATED 1

# Leave the data dir list as the user had it for anything started from here.
if set -q LIBERTTY_FISH_XDG_DATA_DIRS
    set -gx XDG_DATA_DIRS $LIBERTTY_FISH_XDG_DATA_DIRS
    set -e LIBERTTY_FISH_XDG_DATA_DIRS
else
    set -e XDG_DATA_DIRS
end

function __libertty_report_pwd --on-variable PWD
    printf '\e]7;file://%s%s\a' (hostname) (string replace -a ' ' '%20' -- (string replace -a '%' '%25' -- $PWD))
end

function __libertty_prompt --on-event fish_prompt
    printf '\e]133;A\a'
end

function __libertty_preexec --on-event fish_preexec
    set -l line (string replace -a '%' '%25' -- $argv[1] | string replace -a ';' '%3B' | string join '%0A')
    printf '\e]133;C;cmdline_url=%s\a' "$line"
end

function __libertty_postexec --on-event fish_postexec
    printf '\e]133;D;%d\a' $status
end

# No 133;B (input start): emitting it means wrapping fish_prompt, and defining
# fish_prompt this early would stop fish autoloading the user's own.

# TERM=xterm-ghostty is unknown to most remote hosts: ssh with a TERM every
# host has (`ssh-env`), but keep it for a host that has its terminfo
# (`libertty +terminfo setup`, or by itself with `ssh-terminfo`). The user's
# own ssh function wins.
if begin; set -q LIBERTTY_SSH_TERM; or set -q LIBERTTY_SSH_TERMINFO; end; and not functions -q ssh
    function ssh --wraps ssh
        set -l term $LIBERTTY_SSH_TERM
        if begin; test "$LIBERTTY_SSH_TERMINFO" = auto; or begin; set -q LIBERTTY_SSH_TERMINFO; and test -s "$LIBERTTY_TERMINFO_HOSTS"; end; end
            and command -q libertty
            set term (command libertty +terminfo ssh-term -- $argv); or set term $LIBERTTY_SSH_TERM
        end
        if test -n "$term"
            TERM=$term command ssh $argv
        else
            command ssh $argv
        end
    end
end

# `libertty` completes (its +commands, session IDs, actions, settings): its
# completion folder goes last, so a libertty.fish of your own comes first.
if command -q libertty
    set -l completions (string replace -r '/[^/]*/[^/]*$' '' -- (status --current-filename))/vendor_completions.d
    if test -d $completions; and not contains -- $completions $fish_complete_path
        set -ga fish_complete_path $completions
    end
end

__libertty_report_pwd
