# Libertty shell integration: zsh reads this file because Libertty pointed ZDOTDIR
# here. Put the user's ZDOTDIR back first so their own startup files
# (.zprofile, .zshrc, ...) load exactly as they would without Libertty.
if [[ -n "${LIBERTTY_ZSH_ZDOTDIR+X}" ]]; then
    builtin export ZDOTDIR="$LIBERTTY_ZSH_ZDOTDIR"
    builtin unset LIBERTTY_ZSH_ZDOTDIR
else
    builtin unset ZDOTDIR
fi

builtin typeset _libertty_here="${${(%):-%x}:A:h}"
[[ -r "${ZDOTDIR:-$HOME}/.zshenv" ]] && builtin source -- "${ZDOTDIR:-$HOME}/.zshenv"
[[ -o interactive && -r "$_libertty_here/libertty-integration.zsh" ]] && builtin source -- "$_libertty_here/libertty-integration.zsh"
builtin unset _libertty_here
