#!/bin/bash

# Ask for the administrator password upfront
sudo -v

###############################################################################
# XCode Command Line Tools                                                    #
###############################################################################

./install/xcode.sh

###############################################################################
# Brew
###############################################################################

./install/brew.sh

brew update
brew upgrade
brew bundle
brew cleanup

###############################################################################
# Dotfiles
###############################################################################

mkdir -p ~/.config/credentials
touch ~/.config/credentials/keys

# Assumes dotfiles are already cloned
cd ~/dotfiles
git pull
stow home -t ~/
cd ~/

###############################################################################
# zsh & iterm
###############################################################################

if [[ ! $(echo $SHELL) == $(which zsh) ]]; then
  sudo dscl . -create /Users/$USER UserShell $(which zsh)
fi

# Don’t display the annoying prompt when quitting iTerm
defaults write com.googlecode.iterm2 PromptOnQuit -bool false

# Reload zsh settings
source ~/.zshrc

# Install the Solarized Dark theme for iTerm
open "${HOME}/dotfiles/iterm/Solarized Dark.itermcolors"

###############################################################################
# Mac
###############################################################################

./install/mac.sh
