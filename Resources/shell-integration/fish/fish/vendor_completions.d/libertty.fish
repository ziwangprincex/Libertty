# Completion for Libertty's command line in fish (3.0+). `libertty +complete`
# says what fits the words typed so far: commands, flags, session IDs,
# actions, settings and their values, themes, hosts. Libertty's shell
# integration puts this folder at the end of fish_complete_path (your own
# libertty.fish comes first); elsewhere,
# `libertty +completions fish > ~/.config/fish/completions/libertty.fish`.

function __libertty_complete
    set -l current (commandline -ct)
    set -l words (commandline -opc) "$current"
    set -e words[1]
    for line in (command libertty +complete fish -- $words 2>/dev/null)
        switch $line
            case :files
                __fish_complete_path "$current"
            case :dirs
                __fish_complete_directories "$current"
            case :commands
                __fish_complete_command
            case ':*'
            case '*'
                echo $line
        end
    end
end

complete -c libertty -f -a '(__libertty_complete)'
