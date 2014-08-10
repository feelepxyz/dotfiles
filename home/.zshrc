# Load zsh massive renamer
autoload -U zmv

# Turn off all auto correct
unsetopt correct_all

# Turn on extended globbing patterns
setopt EXTENDED_GLOB

# Source Prezto.
if [[ -s "${ZDOTDIR:-$HOME}/.zprezto/init.zsh" ]]; then
  source "${ZDOTDIR:-$HOME}/.zprezto/init.zsh"
fi

source $HOME/.zsh/config
source $HOME/.zsh/aliases
source $HOME/.zsh/scripts
