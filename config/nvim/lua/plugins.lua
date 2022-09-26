-- plugins.lua
-- https://github.com/wbthomason/packer.nvim
-- See also: https://github.com/rockerBOO/awesome-neovim

--- Bootstrap neovim with packer.nvim on first boot
local install_path = vim.fn.stdpath('data') .. '/site/pack/packer/start/packer.nvim'
if vim.fn.empty(vim.fn.glob(install_path)) > 0 then
  BOOTSTRAPPED = vim.fn.system({
    'git', 'clone', '--depth', '1', 'https://github.com/wbthomason/packer.nvim', install_path
  })
  print('Installed packer.nvim, re-launch NeoVim...')
  vim.cmd [[packadd packer.nvim]]
end

-- Automatically run PackerSync on save
vim.cmd [[
  augroup packer_user_config
    autocmd!
    autocmd BufWritePost plugins.lua source <afile> | PackerSync
  augroup end
]]

-- Don't error when first launching without packer.nvim
local ok, packer = pcall(require, 'packer')
if not ok then
  return
end

return packer.startup({
  function(use)
    -- Packer can manage itself
    use 'wbthomason/packer.nvim'

    -- LSP
    use 'williamboman/mason.nvim'
    use 'williamboman/mason-lspconfig.nvim'
    use {
      'neovim/nvim-lspconfig',
      config = [[
        require('plugins.lspconfig')
      ]]
    }
    use 'folke/trouble.nvim'
    use 'onsails/lspkind-nvim'

    -- Completion
    use {
      'hrsh7th/nvim-cmp',
      config = [[
        require('plugins.nvim-cmp')
      ]],
      requires = {
        { 'kyazdani42/nvim-web-devicons', opt = true }
      },
    }
    use 'hrsh7th/cmp-buffer'
    use 'hrsh7th/cmp-emoji'
    use 'hrsh7th/cmp-nvim-lsp'
    use 'hrsh7th/cmp-nvim-lua'
    use 'hrsh7th/cmp-path'
    use 'hrsh7th/cmp-vsnip'
    use 'windwp/nvim-ts-autotag'
    use {
      'norcalli/nvim-colorizer.lua',
      config = function()
        require("colorizer").setup {}
      end
    }
    use {
      'windwp/nvim-autopairs',
      config = function()
        require('nvim-autopairs').setup {}
      end
    }

    -- Syntax
    use {
      'nvim-treesitter/nvim-treesitter',
      config = [[
        require('plugins.treesitter')
      ]],
      run = ':TSUpdate'
    }
    use 'nvim-treesitter/playground'
    use 'nvim-treesitter/nvim-treesitter-refactor'
    use 'nvim-treesitter/nvim-treesitter-textobjects'

    -- Snippets
    use 'hrsh7th/vim-vsnip'
    use 'hrsh7th/vim-vsnip-integ'
    use {
      'danymat/neogen',
      config = function()
        require('neogen').setup {}
      end,
      requires = 'nvim-treesitter/nvim-treesitter'
    }
    use 'github/copilot.vim'

    -- Fuzzy finder
    use {
      'nvim-telescope/telescope.nvim',
      config = function()
        require('telescope').setup {}
      end,
      requires = {
        'nvim-lua/plenary.nvim',
        { 'kyazdani42/nvim-web-devicons', opt = true },
      }
    }
    use 'nvim-telescope/telescope-fzy-native.nvim'
    use 'nvim-telescope/telescope-symbols.nvim'

    -- Theme
    use 'projekt0n/github-nvim-theme'

    -- Utility
    use 'famiu/bufdelete.nvim'
    use {
      'rcarriga/nvim-notify',
      config = function()
        vim.notify = require('notify')
      end
    }

    -- Icons
    use 'kyazdani42/nvim-web-devicons'

    -- Debugging
    use {
      'mfussenegger/nvim-dap',
      config = [[
        require('plugins.dap')
      ]],
    }
    use 'rcarriga/nvim-dap-ui'

    -- Tab line
    use {
      'akinsho/bufferline.nvim',
      config = function()
        require("bufferline").setup {}
      end,
      requires = 'kyazdani42/nvim-web-devicons'
    }

    -- Status line
    use {
      'nvim-lualine/lualine.nvim',
      config = [[
        require('plugins.lualine')
      ]],
      requires = {
        { 'kyazdani42/nvim-web-devicons', opt = true },
      },
    }
    use {
      'SmiteshP/nvim-gps',
      requires = 'nvim-treesitter/nvim-treesitter'
    }
    use 'RRethy/nvim-treesitter-endwise'

    -- Cursor line
    use {
      'yamatsum/nvim-cursorline',
      config = function()
        require('nvim-cursorline').setup({
          cursorline = {
            enable = false,
            timeout = 1000,
            number = false
          },
          cursorword = {
            enable = true,
            min_length = 3,
            hl = { underline = true }
          }
        })
      end
    }

    -- Indent
    use 'lukas-reineke/indent-blankline.nvim'

    -- File explorer
    use {
      'kyazdani42/nvim-tree.lua',
      config = function()
        require('nvim-tree').setup {
          -- disable_netrw = true,
          hijack_cursor = false,
          ignore_buffer_on_setup = true,
          update_focused_file = {
            enable = true
          },
          diagnostics = {
            enable = true
          },
        }
      end,
      requires = 'kyazdani42/nvim-web-devicons'
    }

    -- Dependency management
    use 'vuki656/package-info.nvim'

    -- Git
    use {
      'lewis6991/gitsigns.nvim',
      config = function()
        require('gitsigns').setup {
          current_line_blame = true
        }
      end
    }
    use {
      'TimUntersberger/neogit',
      config = function()
        require('neogit').setup {
          kind = 'split'
        }
      end,
      requires = 'nvim-lua/plenary.nvim'
    }
    use {
      'ruifm/gitlinker.nvim',
      config = function()
        require('gitlinker').setup {}
      end,
      requires = 'nvim-lua/plenary.nvim',
    }

    -- Languages
    use {
      'ellisonleao/glow.nvim',
      config = function()
        vim.g.glow_border = 'rounded'
        vim.g.glow_use_pager = true
      end,
      ft = { 'markdown' }
    }
    use {
      'jghauser/follow-md-links.nvim',
      ft = { 'markdown' }
    }
    use {
      'rust-lang/rust.vim',
      ft = { 'rust' }
    }

    -- Comments
    use {
      'numToStr/Comment.nvim',
      config = function()
        require('Comment').setup {}
      end
    }

    -- GitHub
    use {
      'pwntester/octo.nvim',
      config = function()
        require('octo').setup {}
      end,
      requires = {
        'nvim-lua/plenary.nvim',
        'nvim-telescope/telescope.nvim',
        'kyazdani42/nvim-web-devicons',
      }
    }

    -- Project management
    use {
      'ahmedkhalf/project.nvim',
      config = function()
        require('project_nvim').setup {}
        require('telescope').load_extension('projects')
      end
    }

    -- Editor support
    -- use 'max-0406/autoclose.nvim'
    use 'p00f/nvim-ts-rainbow'
    use {
      'nacro90/numb.nvim',
      config = function()
        require('numb').setup {}
      end
    }

    -- Formatting
    use 'gpanders/editorconfig.nvim'

    -- Test
    use {
      "nvim-neotest/neotest",
      requires = {
        'nvim-lua/plenary.nvim',
        'nvim-treesitter/nvim-treesitter',
        'antoinemadec/FixCursorHold.nvim',
        'nvim-neotest/neotest-vim-test',
        'vim-test/vim-test',
        'nvim-neotest/neotest-python',
      },
      config = function()
        require('neotest').setup {
          adapters = {
            require('neotest-vim-test')({ ignore_filetypes = { 'python' } })
          }
        }
      end
    }

    -- Window management
    use {
      'sindrets/winshift.nvim',
      config = function()
        require('winshift').setup {}
      end
    }
    use {
      'luukvbaal/stabilize.nvim',
      config = function()
        require('stabilize').setup {
          nested = "QuickFixCmdPost,DiagnosticChanged *"
        }
      end
    }

    --- Shopify specific plugins
    if os.getenv('SHOPIFY_OWNED_DEVICE') then
      use "Shopify/shadowenv.vim"
      use "Shopify/spin-vim"
      use "Shopify/vim-devilish"
    end

    -- Automatically run a sync if the system has just installed Packer.nvim
    if BOOTSTRAPPED then
      require('packer').sync()
    end
  end,
  config = {
    autoremove = true,
    display = {
      open_fn = require('packer.util').float,
    },
    profile = {
      enabled = true,
    }
  }
})
