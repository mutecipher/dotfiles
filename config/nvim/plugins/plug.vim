let nvim_data_dir = stdpath('data').'/site'
let vim_plug_uri = 'https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim'
let vim_plug_path = nvim_data_dir.'/autoload/plug.vim'

" If vim-plug is not installed; install it, and the following plugins.
if empty(glob(vim_plug_path))
  silent execute '!curl -fLo '.vim_plug_path.' --create-dirs '.vim_plug_uri
  autocmd VimEnter * PlugInstall --sync | source $HOME/.config/nvim/init.vim
endif

call plug#begin(nvim_data_dir.'/plugged')
" UI
Plug 'nvim-lualine/lualine.nvim'
Plug 'SmiteshP/nvim-gps'

" LSP
Plug 'neovim/nvim-lspconfig'
Plug 'williamboman/nvim-lsp-installer'

" Autocomplete
Plug 'hrsh7th/nvim-cmp'
Plug 'onsails/lspkind-nvim'
Plug 'hrsh7th/vim-vsnip'
Plug 'hrsh7th/vim-vsnip-integ'
Plug 'hrsh7th/cmp-nvim-lsp'
Plug 'hrsh7th/cmp-nvim-lua'
Plug 'hrsh7th/cmp-path'
Plug 'hrsh7th/cmp-emoji'
Plug 'hrsh7th/cmp-buffer'
Plug 'hrsh7th/cmp-vsnip'

" Telescope
Plug 'nvim-lua/plenary.nvim'
Plug 'nvim-telescope/telescope.nvim'
Plug 'nvim-telescope/telescope-fzy-native.nvim'
Plug 'nvim-telescope/telescope-symbols.nvim'

" Treesitter
Plug 'nvim-treesitter/nvim-treesitter', { 'do': ':TSUpdate' }
Plug 'nvim-treesitter/playground'

" Themes
Plug 'dracula/vim', { 'as': 'dracula' }

" Git/GitHub helpers
Plug 'lewis6991/gitsigns.nvim'
Plug 'tpope/vim-fugitive'
Plug 'tpope/vim-rhubarb'

" Syntax highlighting improvements
Plug 'sheerun/vim-polyglot'

" Editorconfig
Plug 'editorconfig/editorconfig-vim'

" Comment toggle
Plug 'tpope/vim-commentary'

" Ruby support
Plug 'vim-ruby/vim-ruby'
Plug 'tpope/vim-rails'

" Testing
Plug 'vim-test/vim-test'
Plug 'rcarriga/vim-ultest', { 'do': ':UpdateRemotePlugins' }


" Debugger
Plug 'mfussenegger/nvim-dap'
Plug 'rcarriga/nvim-dap-ui'

" JSON
Plug 'elzr/vim-json'

" Rust
Plug 'rust-lang/rust.vim'
Plug 'cespare/vim-toml'

" Indentation guide
Plug 'lukas-reineke/indent-blankline.nvim'

" DevIcons
Plug 'kyazdani42/nvim-web-devicons'
call plug#end()
