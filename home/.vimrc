
source ~/.vim/vimrc-vanilla.vim

if !isdirectory(expand("~/.vim/backup"))
  silent! execute "!mkdir -p ~/.vim/backup"
endif
set backup
set backupdir=~/.vim/backup
