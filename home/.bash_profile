# shellcheck shell=bash disable=SC1091
if [[ "$(uname -s)" == Darwin ]]; then
  if [[ -x /opt/homebrew/bin/brew ]]; then
    eval "$(/opt/homebrew/bin/brew shellenv)"
  elif [[ -x /usr/local/bin/brew ]]; then
    eval "$(/usr/local/bin/brew shellenv)"
  fi
fi

# Preserve Bash's interactive setup on Omarchy, even when Zsh is used in Ghostty.
[[ -f "$HOME/.bashrc" ]] && . "$HOME/.bashrc"

# Vite+ bin (https://viteplus.dev)
[[ -f "$HOME/.vite-plus/env" ]] && . "$HOME/.vite-plus/env"
export PATH="$HOME/.local/bin:$PATH"
