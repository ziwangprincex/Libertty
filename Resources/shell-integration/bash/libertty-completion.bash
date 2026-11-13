# Completion for Libertty's command line in bash (3.2+). `libertty +complete`
# says what fits the words typed so far: commands, flags, session IDs,
# actions, settings and their values, themes, hosts. Libertty's shell
# integration loads this unless you complete `libertty` yourself; elsewhere,
# `eval "$(libertty +completions bash)"` (bash 3.2 can't source <(…)).

_libertty_complete() {
    # The words as typed: bash's own (COMP_WORDS) are cut at = and :.
    local line=${COMP_LINE:0:COMP_POINT} reply
    local -a words=()
    read -r -a words <<< "$line"
    if [[ ${#words[@]} -eq 0 || $line == *[[:space:]] ]]; then words+=(""); fi
    local typed=${words[${#words[@]}-1]}
    # What bash puts the answer in place of: the word after its last = or :.
    local cur=${COMP_WORDS[COMP_CWORD]}
    local prefix=${typed%"$cur"}
    COMPREPLY=()
    local nospace=0 commands=0
    while IFS= read -r reply; do
        case $reply in
            :nospace) nospace=1 ;;
            :commands) commands=1 ;;
            # Files and folders: nothing here, so bash completes them (-o default).
            :files | :dirs) ;;
            *) COMPREPLY+=("${reply#"$prefix"}") ;;
        esac
    done < <(command libertty +complete bash -- "${words[@]:1}" 2> /dev/null)
    if ((commands)); then
        while IFS= read -r reply; do COMPREPLY+=("$reply"); done < <(compgen -c -- "$cur")
    fi
    if ((nospace)) && type compopt > /dev/null 2>&1; then compopt -o nospace; fi
    return 0
}

complete -o bashdefault -o default -F _libertty_complete libertty
