. ~/.zsh/config
. ~/.zsh/aliases
. ~/.zsh/scripts

# Path to your oh-my-zsh configuration.
export ZSH=$HOME/.oh-my-zsh

# Set to the name theme to load.
export ZSH_THEME="cloud"

# Load zsh massive renamer
autoload -U zmv

# Turn off all auto correct
unsetopt correct_all

source $ZSH/oh-my-zsh.sh
