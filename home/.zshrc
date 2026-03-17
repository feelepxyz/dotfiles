. ~/.zsh/config
. ~/.zsh/prompt
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