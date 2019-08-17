" packages.vim - Plugins and packages to be installed

call plug#begin('~/.config/nvim/plugged')

" general {{{1

Plug 'junegunn/vim-plug'

Plug 'kien/ctrlp.vim' " fuzzy file finder
Plug 'junegunn/goyo.vim' " zen mode
Plug 'scrooloose/nerdtree' " folder explorer
Plug 'airblade/vim-gitgutter' " git gutter
Plug 'tpope/vim-commentary' "comment block support
Plug 'tpope/vim-dispatch' " async support
Plug 'tpope/vim-fugitive' " git support
Plug 'tpope/vim-rhubarb' " github support
Plug 'tpope/vim-surround' " improved quote/brace support
Plug 'ekalinin/Dockerfile.vim' " dockerfile support
Plug 'sheerun/vim-polyglot' " improved syntax highlighting
Plug 'vim-airline/vim-airline' " sick bottom bar
Plug 'vim-airline/vim-airline-themes' " sick bottom bar themes
Plug 'djoshea/vim-autoread' " read updates from file system
Plug 'terryma/vim-multiple-cursors' " multi-cursor support
Plug 'godlygeek/tabular' " clean text up
Plug 'christoomey/vim-tmux-navigator' " make navigating VIM in tmux easier
Plug 'majutsushi/tagbar' " view ctags of current file
Plug 'neoclide/coc.nvim', {'branch': 'release'} " language server

Plug 'cjhutchi/org.vim'

" }}}1
" languages {{{1

" go {{{2

Plug 'fatih/vim-go' " the only necessary go plugin

" }}}2
" ruby {{{2

Plug 'vim-ruby/vim-ruby' " ruby support
Plug 'tpope/vim-rails' " rails support
Plug 'tpope/vim-bundler' " bundler support
Plug 'tpope/vim-endwise' " smartly add end
Plug 'thoughtbot/vim-rspec' " rspec support

" }}}2
" web {{{2

Plug 'othree/html5.vim'
Plug 'elzr/vim-json'
Plug 'tpope/vim-markdown'
Plug 'jparise/vim-graphql'

" }}}2
" latex {{{2

Plug 'lervag/vimtex'

" }}}2

" }}}1

call plug#end()

" vim:ft=vim:fdm=marker:fdl=0
