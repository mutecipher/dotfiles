" packages.vim - Plugins and packages to be installed

" if plug.vim is not installed, install it.
if empty(glob('$HOME/.config/nvim/autoload/plug.vim'))
  silent !curl -fLo $HOME/.config/nvim/autoload/plug.vim --create-dirs
        \ https://raw.githubusercontent.com/junegunn/wim-plug/master/plug.vim
  autocmd VimEnter * PlugInstall --sync | source $HOME/.zshrc
endif

call plug#begin('~/.config/nvim/plugged')

" general {{{1

Plug 'junegunn/vim-plug'

Plug 'tpope/vim-commentary' "comment block support
Plug 'tpope/vim-dispatch' " async support
Plug 'tpope/vim-fugitive' " git support
Plug 'tpope/vim-rhubarb' " github support
Plug 'tpope/vim-surround' " improved quote/brace support
Plug 'tpope/vim-ragtag' " html, tag helpers
Plug 'tpope/vim-eunuch' " unix helpers
Plug 'tpope/vim-dadbod' " database helpers

" Plug 'kien/ctrlp.vim' " fuzzy file finder
Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
Plug 'junegunn/fzf.vim'
Plug 'junegunn/goyo.vim' " zen mode
Plug 'scrooloose/nerdtree' " folder explorer
Plug 'airblade/vim-gitgutter' " git gutter
Plug 'ekalinin/Dockerfile.vim' " dockerfile support
Plug 'vim-airline/vim-airline' " sick bottom bar
Plug 'vim-airline/vim-airline-themes' " sick bottom bar themes
Plug 'djoshea/vim-autoread' " read updates from file system
Plug 'terryma/vim-multiple-cursors' " multi-cursor support
Plug 'godlygeek/tabular' " clean text up
Plug 'christoomey/vim-tmux-navigator' " make navigating VIM in tmux easier
Plug 'majutsushi/tagbar' " view ctags of current file
Plug 'autozimu/LanguageClient-neovim', { 'branch': 'next', 'do': 'bash install.sh', } " language server
Plug 'Shougo/deoplete.nvim', { 'do': ':UpdateRemotePlugins' } " better autocomplete
Plug 'Shougo/deoppet.nvim', { 'do': ':UpdateRemotePlugins' }
Plug 'fszymanski/deoplete-emoji'
Plug 'ncm2/float-preview.nvim'
Plug 'janko/vim-test' " test runner
Plug 'Shopify/shadowenv.vim' " shadowenv support

Plug 'cjhutchi/org.vim'

" }}}1
" languages {{{1

" go {{{2

Plug 'fatih/vim-go', {'do': ':GoUpdateBinaries'} " the only necessary go plugin

" }}}2
" ruby {{{2

Plug 'vim-ruby/vim-ruby' " ruby support
Plug 'tpope/vim-rails' " rails support
Plug 'tpope/vim-bundler' " bundler support
Plug 'tpope/vim-endwise' " smartly add end
Plug 'thoughtbot/vim-rspec' " rspec support
Plug 'ngmy/vim-rubocop' " rubocop support

" }}}2
" web {{{2

Plug 'othree/html5.vim'
Plug 'elzr/vim-json'
Plug 'tpope/vim-markdown'
Plug 'jparise/vim-graphql'

" }}}2
" json {{{2

Plug 'tpope/vim-jdaddy'

" }}}2
" rust {{{2

Plug 'rust-lang/rust.vim'

" }}}2
" syntax highlighting {{{2

Plug 'sheerun/vim-polyglot' " improved syntax highlighting

" }}}2

" }}}1

call plug#end()

" vim:ft=vim:fdm=marker:fdl=0
