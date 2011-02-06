export PATH=/usr/local/bin:/usr/local/sbin:/usr/local/share/npm/bin:$PATH

export NODE_PATH="/usr/local/lib/node"
export EDITOR="mate -w"
export GIT_EDITOR='mate -wl1'

source resty

alias v="mvim"
alias es="open -a Espresso"
alias g="git"
alias l="ls -GlAFh"
alias mkdir="mkdir -vp"
alias sizes='du -h -d1'
alias flush="dscacheutil -flushcache"

alias hackz='cat /dev/urandom | hexdump -C | grep "ca fe"'

alias home="cd ~/"
alias desk="cd ~/Desktop"
alias code="cd ~/code"

alias gadd="git add -A && git status -sb"
alias gwip="git commit -am 'wip'"

[[ -s "$HOME/.rvm/scripts/rvm" ]] && . "$HOME/.rvm/scripts/rvm"  # This loads RVM into a shell session.

## Custom prompt
# Colors
       RED="\[\033[0;31m\]"
      PINK="\[\033[1;31m\]"
    YELLOW="\[\033[1;33m\]"
     GREEN="\[\033[0;32m\]"
  LT_GREEN="\[\033[1;32m\]"
      BLUE="\[\033[0;34m\]"
     WHITE="\[\033[1;37m\]"
    PURPLE="\[\033[1;35m\]"
      CYAN="\[\033[1;36m\]"
     BROWN="\[\033[0;33m\]"
COLOR_NONE="\[\033[0m\]"

LIGHTNING_BOLT="⚡"
      UP_ARROW="↑"
    DOWN_ARROW="↓"
      UD_ARROW="↕"
      FF_ARROW="→"
       RECYCLE="♺"
        MIDDOT="•"
     PLUSMINUS="±"
