#!/bin/bash

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
brew bundle --file=./home/Brewfile
brew bundle cleanup --file=./home/Brewfile --force
brew cleanup

###############################################################################
# Dotfiles
###############################################################################

# Update dotfiles
git pull

# Symlink dotfiles
stow home -t ~/

###############################################################################
# Mac
###############################################################################

./install/mac.sh

# Install all available software updates
sudo softwareupdate -ia

###############################################################################
# zsh & iterm
###############################################################################

if [ $(echo $SHELL) != $(which zsh) ]; then
  sudo dscl . -create /Users/$USER UserShell $(which zsh)
fi

# Install the Solarized Dark theme for iTerm
# open "${HOME}/dotfiles/iterm/Solarized Dark.itermcolors"
