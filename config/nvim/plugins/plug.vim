let nvim_data_dir = stdpath('data').'/site'
let vim_plug_uri = 'https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'
let vim_plug_path = nvim_data_dir.'/autoload/plug.vim'

" If vim-plug is not installed; install it, and the following plugins.
if empty(glob(vim_plug_path))
  silent execute '!curl -fLo '.vim_plug_path.' --create-dirs '.vim_plug_uri
  autocmd VimEnter * PlugInstall --sync | source $HOME/.config/nvim/init.vim
endif

call plug#begin(nvim_data_dir.'/plugged')
if has('nvim')
  " LSP
  Plug 'neovim/nvim-lspconfig'
  Plug 'nvim-lua/completion-nvim'

  " Telescope
  Plug 'nvim-lua/plenary.nvim'
  Plug 'nvim-telescope/telescope.nvim'
  Plug 'nvim-telescope/telescope-fzy-native.nvim'
  Plug 'nvim-telescope/telescope-symbols.nvim'

  " Treesitter
  Plug 'nvim-treesitter/nvim-treesitter'
  Plug 'nvim-treesitter/playground'
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
Plug 'vim-ruby/vim-ruby'
Plug 'tpope/vim-rails'
Plug 'thoughtbot/vim-rspec'

" Debugger
Plug 'puremourning/vimspector'

" JSON
Plug 'elzr/vim-json'

" Rust
Plug 'rust-lang/rust.vim'
Plug 'cespare/vim-toml'

" Airline Status bar
Plug 'vim-airline/vim-airline'
Plug 'vim-airline/vim-airline-themes'

" Plug 'christoomey/vim-tmux-navigator' " make navigating VIM in tmux easier
" Plug 'djoshea/vim-autoread' " read updates from file system
" Plug 'ekalinin/Dockerfile.vim' " dockerfile support
" Plug 'fatih/vim-go', {'do': ':GoInstallBinaries'} " the only necessary go plugin
" Plug 'fszymanski/deoplete-emoji'
" Plug 'godlygeek/tabular' " clean text up
" Plug 'janko/vim-test' " test runner
" Plug 'jparise/vim-graphql'
" Plug 'majutsushi/tagbar' " view ctags of current file
" Plug 'ngmy/vim-rubocop' " rubocop support
" Plug 'othree/html5.vim'
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

call plug#end()
