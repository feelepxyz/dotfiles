. ~/.zsh/config
. ~/.zsh/aliases
. ~/.zsh/scripts

# Path to your oh-my-zsh configuration.
export ZSH=$HOME/.oh-my-zsh

# Set to the name theme to load.
export ZSH_THEME="cloud"

# Which plugins would you like to load? (plugins can be found in ~/.oh-my-zsh/plugins/*)
# Example format: plugins=(rails git textmate ruby lighthouse)
plugins=(git ruby bundler cap node npm sublime)

# Load zsh massive renamer
autoload -U zmv

# Turn off all auto correct
unsetopt correct_all

source $ZSH/oh-my-zsh.sh
