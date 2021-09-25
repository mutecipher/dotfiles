" plugins.vim - manage plugins via vim-plug.

" if empty(glob('$HOME/.config/nvim/autoload/plug.vim'))
"   silent !curl -fLo $HOME/.config/nvim/autoload/plug.vim --create-dirs
"         \ https://raw.githubusercontent.com/junegunn/wim-plug/master/plug.vim
"   autocmd VimEnter * PlugInstall --sync | source $HOME/.zshrc
" endif

call plug#begin()
" neovim specific {{{1

if has('nvim')
  Plug 'hrsh7th/nvim-cmp'
  Plug 'nvim-lua/completion-nvim'
  Plug 'neovim/nvim-lspconfig'
  Plug 'norcalli/snippets.nvim'
  Plug 'nvim-lua/plenary.nvim'
  Plug 'nvim-telescope/telescope.nvim'
  Plug 'nvim-telescope/telescope-symbols.nvim'
  Plug 'nvim-treesitter/nvim-treesitter'
  Plug 'nvim-treesitter/playground'
  Plug 'williamboman/nvim-lsp-installer'
endif

" }}}1
" global {{{1

" Themes
Plug 'arcticicestudio/nord-vim'
Plug 'morhetz/gruvbox'

" Git/GitHub helpers
Plug 'airblade/vim-gitgutter'
Plug 'tpope/vim-fugitive'
Plug 'tpope/vim-rhubarb'

" Comment toggle
Plug 'tpope/vim-commentary'

" Ruby support
Plug 'vim-ruby/vim-ruby' " ruby support
Plug 'tpope/vim-rails' " rails support
Plug 'thoughtbot/vim-rspec' " rspec support

" Debugger
Plug 'puremourning/vimspector'

" JSON
Plug 'elzr/vim-json'

" Plug 'christoomey/vim-tmux-navigator' " make navigating VIM in tmux easier
" Plug 'djoshea/vim-autoread' " read updates from file system
" Plug 'ekalinin/Dockerfile.vim' " dockerfile support
" Plug 'fatih/vim-go', {'do': ':GoInstallBinaries'} " the only necessary go plugin
" Plug 'fszymanski/deoplete-emoji'
" Plug 'godlygeek/tabular' " clean text up
" Plug 'janko/vim-test' " test runner
" Plug 'jparise/vim-graphql'
" Plug 'junegunn/fzf', { 'do': { -> fzf#install() } }
" Plug 'junegunn/fzf.vim'
" Plug 'junegunn/goyo.vim' " zen mode
" Plug 'junegunn/vim-plug'
" Plug 'majutsushi/tagbar' " view ctags of current file
" Plug 'ngmy/vim-rubocop' " rubocop support
" Plug 'othree/html5.vim'
" Plug 'rust-lang/rust.vim'
" Plug 'scrooloose/nerdtree' " folder explorer
" Plug 'sheerun/vim-polyglot' " improved syntax highlighting
" Plug 'terryma/vim-multiple-cursors' " multi-cursor support
" Plug 'tpope/vim-bundler' " bundler support
" Plug 'tpope/vim-dadbod' " database helpers
" Plug 'tpope/vim-dispatch' " async support
" Plug 'tpope/vim-endwise' " smartly add end
" Plug 'tpope/vim-eunuch' " unix helpers
" Plug 'tpope/vim-jdaddy'
" Plug 'tpope/vim-markdown'
" Plug 'tpope/vim-ragtag' " html, tag helpers
" Plug 'tpope/vim-surround' " improved quote/brace support
" Plug 'vim-airline/vim-airline' " sick bottom bar
" Plug 'vim-airline/vim-airline-themes' " sick bottom bar themes

" }}}1
call plug#end()

" vim:ft=vim:fdm=marker:fdl=0
