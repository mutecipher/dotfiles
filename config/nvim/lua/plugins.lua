-- plugins.lua

local install_path = vim.fn.stdpath('data')..'/site/pack/packer/start/packer.nvim'

if vim.fn.empty(vim.fn.glob(install_path)) > 0 then
  BOOTSTRAPPED = vim.fn.system({
    'git', 'clone', '--depth', '1', 'https://github.com/wbthomason/packer.nvim', install_path
  })
end

return require('packer').startup(
  {
    function(use)
      use 'SmiteshP/nvim-gps'
      use 'akinsho/bufferline.nvim'
      use 'cespare/vim-toml'
      use 'editorconfig/editorconfig-vim'
      use 'elzr/vim-json'
      use 'folke/trouble.nvim'
      use 'github/copilot.vim'
      use 'kyazdani42/nvim-tree.lua'
      use 'kyazdani42/nvim-web-devicons'
      use 'lewis6991/gitsigns.nvim'
      use 'lukas-reineke/indent-blankline.nvim'
      use 'neovim/nvim-lspconfig'
      use 'nvim-lua/plenary.nvim'
      use 'nvim-lualine/lualine.nvim'
      use 'nvim-treesitter/playground'
      use 'onsails/lspkind-nvim'
      use 'projekt0n/github-nvim-theme'
      use 'rust-lang/rust.vim'
      use 'sheerun/vim-polyglot'
      use 'tjdevries/colorbuddy.vim'
      use 'tpope/vim-commentary'
      use 'tpope/vim-fugitive'
      use 'tpope/vim-rhubarb'
      use 'vim-test/vim-test'
      use 'wbthomason/packer.nvim'
      use 'williamboman/nvim-lsp-installer'
      use {
        'hrsh7th/nvim-cmp',
        requires = {
          'hrsh7th/cmp-buffer',
          'hrsh7th/cmp-emoji',
          'hrsh7th/cmp-nvim-lsp',
          'hrsh7th/cmp-nvim-lua',
          'hrsh7th/cmp-path',
          'hrsh7th/cmp-vsnip'
        }
      }
      use { 'hrsh7th/vim-vsnip', requires = 'hrsh7th/vim-vsnip-integ' }
      use {
        'nvim-telescope/telescope.nvim',
        requires = {
          'nvim-telescope/telescope-fzy-native.nvim',
          'nvim-telescope/telescope-symbols.nvim'
        }
      }
      use { 'nvim-treesitter/nvim-treesitter', run = ':TSUpdate' }
      use { 'rcarriga/nvim-dap-ui', requires = 'mfussenegger/nvim-dap' }
      use { 'rcarriga/vim-ultest', run = ':UpdateRemotePlugins' }

      -- Automatically run a sync if the system has just installed Packer.nvim
      if BOOTSTRAPPED then
        require('packer').sync()
      end

      require('plugins.bufferline')
      require('plugins.dap')
      require('plugins.gitsigns')
      require('plugins.lspconfig')
      require('plugins.lualine')
      require('plugins.nvim-cmp')
      require('plugins.nvim-tree')
      require('plugins.telescope')
      require('plugins.theme')
      require('plugins.ultest')
      require('plugins.vsnip')
    end,
    config = {
      display = {
        open_fn = require('packer.util').float,
      }
    }
  }
)
