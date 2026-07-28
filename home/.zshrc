. ~/.zsh/config
. ~/.zsh/aliases
. ~/.zsh/autocompletion
. ~/.zsh/scripts

# bun completions
[ -s "/Users/feelepxyz/.bun/_bun" ] && source "/Users/feelepxyz/.bun/_bun"

# bun
export BUN_INSTALL="$HOME/.bun"
export PATH="$BUN_INSTALL/bin:$PATH"

# proto
export PROTO_HOME="$HOME/.proto";
export PATH="$PROTO_HOME/shims:$PROTO_HOME/bin:$PATH";
# Vite+ bin (https://viteplus.dev)
. "$HOME/.vite-plus/env"


# kimi-code
export PATH="/Users/feelepxyz/.kimi-code/bin:$PATH"

# Pi
export PATH="/Users/feelepxyz/.vite-plus/js_runtime/node/24.18.0/bin:$PATH"

# worktrunk
if command -v wt >/dev/null 2>&1; then eval "$(command wt config shell init zsh)"; fi
