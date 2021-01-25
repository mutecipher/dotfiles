" general.vim - general settings and configurations for Vim/NeoVim.

" editor {{{1

set autoread
set scrolloff=4 sidescrolloff=10 " scrolling offsets
set foldenable " enable folding
set foldlevelstart=10 " open most folds by default
set foldnestmax=10 " 10 nested folds max
set nowrap " don't line wrap
set expandtab tabstop=2 softtabstop=2 shiftwidth=2 " defaults
set autoindent " autoindent
set number relativenumber numberwidth=2 " show line numbers
set colorcolumn=121
set mouse=a

" }}}1
" file locations {{{1

set directory=/tmp/ " for swap/tmp files

" }}}1
" misc {{{1

let mapleader=","
set nocompatible " requirement for many plugins
colorscheme gruvbox
syntax on " enable syntax highlighting
set t_Co=256 " allow xterm-256
set background=dark
filetype indent plugin on
set autoread " recognize external modifications
set showcmd " show commands
set showmatch " show matching parenthesis, etc.
set wildmenu
set lazyredraw " don't update unless necessary
set showmatch
set incsearch " increment and search is typed
set hlsearch " highlight search results
set ignorecase smartcase " case insensitive search
set splitright splitbelow " split windows like other apps

" }}}1

" vim:ft=vim:fdm=marker:fdl=0
