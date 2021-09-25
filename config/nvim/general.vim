" general.vim - general settings and configurations for Vim/Neovim.

" general {{{1
set nocompatible
let mapleader="\<Space>"
set directory=/tmp/
set autoread
filetype indent plugin on
set lazyredraw

" }}}1
" editor {{{1

set autoindent
set colorcolumn=121
set completeopt=menuone,noinsert,noselect
set shortmess+=c
set expandtab tabstop=2 softtabstop=2 shiftwidth=2
set foldenable
set foldlevelstart=10
set foldnestmax=10
set mouse=a
set nowrap
set number relativenumber numberwidth=2
set scrolloff=4 sidescrolloff=10

" }}}1
" misc {{{1

set showcmd " show commands
set showmatch " show matching parenthesis, etc.
set wildmenu
set showmatch
set incsearch " increment and search is typed
set hlsearch " highlight search results
set ignorecase smartcase " case insensitive search
set splitright splitbelow " split windows like other apps

" }}}1

" vim:ft=vim:fdm=marker:fdl=0
