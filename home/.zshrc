source ~/.zsh/config
source ~/.zsh/aliases
source ~/.zsh/autocompletion
source ~/.zsh/scripts

if [[ -r "${BUN_INSTALL:-$HOME/.bun}/_bun" ]]; then
  source "${BUN_INSTALL:-$HOME/.bun}/_bun"
fi
if (( $+commands[wt] )); then eval "$(command wt config shell init zsh)"; fi

# Load native plugins after completion and widget setup, highlighting last.
if [[ "$OSTYPE" == darwin* ]]; then
  for dotfiles_plugin in "$HOMEBREW_PREFIX/share/zsh-autosuggestions/zsh-autosuggestions.zsh" \
    "$HOMEBREW_PREFIX/opt/zsh-fast-syntax-highlighting/share/zsh-fast-syntax-highlighting/fast-syntax-highlighting.plugin.zsh"; do
    [[ -r "$dotfiles_plugin" ]] && source "$dotfiles_plugin"
  done
else
  for dotfiles_plugin in /usr/share/zsh/plugins/zsh-autosuggestions/zsh-autosuggestions.zsh \
    /usr/share/zsh/plugins/zsh-syntax-highlighting/zsh-syntax-highlighting.zsh; do
    [[ -r "$dotfiles_plugin" ]] && source "$dotfiles_plugin"
  done
fi
unset dotfiles_plugin
