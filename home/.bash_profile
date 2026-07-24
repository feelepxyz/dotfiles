if [[ "$(uname -m)" == "arm64" ]]; then
  eval "$(/opt/homebrew/bin/brew shellenv)"
else
  eval "$(/usr/local/bin/brew shellenv)"
fi

# Vite+ bin (https://viteplus.dev)
. "$HOME/.vite-plus/env"


# Added by Antigravity CLI installer
export PATH="/Users/feelepxyz/.local/bin:$PATH"
