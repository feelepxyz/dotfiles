. ~/.zsh/config
. ~/.zsh/aliases
. ~/.zsh/scripts

# Load zsh massive renamer
autoload -U zmv

# Turn off all auto correct
unsetopt correct_all

setopt EXTENDED_GLOB

for rcfile in "${ZDOTDIR:-$HOME}"/.zprezto/runcoms/^README.md(.N); do
  ln -s "$rcfile" "${ZDOTDIR:-$HOME}/.${rcfile:t}"
done