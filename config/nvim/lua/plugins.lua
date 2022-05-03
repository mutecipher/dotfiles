-- plugins.lua
-- https://github.com/wbthomason/packer.nvim
-- See also: https://github.com/rockerBOO/awesome-neovim

-- Bootstrap neovim with packer.nvim on first boot
local install_path = vim.fn.stdpath('data') .. '/site/pack/packer/start/packer.nvim'
if vim.fn.empty(vim.fn.glob(install_path)) > 0 then
  BOOTSTRAPPED = vim.fn.system({
    'git', 'clone', '--depth', '1', 'https://github.com/wbthomason/packer.nvim', install_path
  })
  print('Installed packer.nvim, relauch neovim...')
  vim.cmd[[packadd packer.nvim]]
end

vim.cmd[[
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
    use {
      {
        'neovim/nvim-lspconfig',
        config = [[require('plugins.lspconfig')]]
      },
      'folke/trouble.nvim',
      {
        'kosayoda/nvim-lightbulb',
        config = function()
          require('nvim-lightbulb').setup({})
          vim.cmd [[autocmd CursorHold,CursorHoldI * lua require'nvim-lightbulb'.update_lightbulb()]]
        end
      },
      'onsails/lspkind-nvim',
      {
        'j-hui/fidget.nvim',
        config = function()
          require('fidget').setup({
            text = {
              spinner = 'dots'
            }
          })
        end
      },
      {
        'weilbith/nvim-code-action-menu',
        cmd = 'CodeActionMenu',
      },
      'williamboman/nvim-lsp-installer'
    }

    -- Completion
    use {
      {
        'hrsh7th/nvim-cmp',
        config = [[require('plugins.nvim-cmp')]],
        requires = {
          { 'kyazdani42/nvim-web-devicons', opt = true }
        },
      },
      'hrsh7th/cmp-buffer',
      'hrsh7th/cmp-emoji',
      'hrsh7th/cmp-nvim-lsp',
      'hrsh7th/cmp-nvim-lua',
      'hrsh7th/cmp-path',
      'hrsh7th/cmp-vsnip'
    }

    -- Syntax
    use {
      {
        'nvim-treesitter/nvim-treesitter',
        config = [[require('plugins.treesitter')]],
        run = ':TSUpdate'
      },
      'nvim-treesitter/playground',
      'nvim-treesitter/nvim-treesitter-refactor',
      'nvim-treesitter/nvim-treesitter-textobjects'
    }

    -- Snippets
    use {
      {
        'hrsh7th/vim-vsnip',
        config = [[require('plugins.vsnip')]],
      },
      'hrsh7th/vim-vsnip-integ',
      {
        'danymat/neogen',
        config = function()
          require('neogen').setup({})
        end,
        requires = 'nvim-treesitter/nvim-treesitter'
      },
      'github/copilot.vim',
    }

    -- Fuzzy finder
    use {
      {
        'nvim-telescope/telescope.nvim',
        config = [[require('plugins.telescope')]],
        requires = {
          'nvim-lua/plenary.nvim',
          { 'kyazdani42/nvim-web-devicons', opt = true },
        }
      },
      'nvim-telescope/telescope-fzy-native.nvim',
      'nvim-telescope/telescope-symbols.nvim'
    }

    -- Theme
    use {
      'projekt0n/github-nvim-theme',
      config = [[require('plugins.theme')]]
    }

    -- Utility
    use {
      'famiu/bufdelete.nvim',
      {
        'rcarriga/nvim-notify',
        config = function()
          vim.notify = require('notify')
        end
      },
    }

    -- Icons
    use 'kyazdani42/nvim-web-devicons'

    -- Debugging
    use {
      {
        'mfussenegger/nvim-dap',
        config = [[require('plugins.dap')]],
      },
      'rcarriga/nvim-dap-ui'
    }

    -- Tab line
    use {
      'akinsho/bufferline.nvim',
      config = [[require('plugins.bufferline')]],
      requires = 'kyazdani42/nvim-web-devicons'
    }

    -- Status line
    use {
      {
        'nvim-lualine/lualine.nvim',
        config = [[require('plugins.lualine')]],
        requires = {
          { 'kyazdani42/nvim-web-devicons', opt = true },
        },
      },
      {
        'SmiteshP/nvim-gps',
        requires = 'nvim-treesitter/nvim-treesitter'
      },
      'RRethy/nvim-treesitter-endwise'
    }

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
      config = [[require('plugins.nvim-tree')]],
      requires = 'kyazdani42/nvim-web-devicons'
    }

    -- Dependency management
    use 'vuki656/package-info.nvim'

    -- Git
    use {
      {
        'lewis6991/gitsigns.nvim',
        config = [[require('plugins.gitsigns')]]
      },
      {
        'TimUntersberger/neogit',
        config = function()
          require('neogit').setup({
            kind = 'split'
          })
        end,
        requires = 'nvim-lua/plenary.nvim'
      },
      {
        'ruifm/gitlinker.nvim',
        config = function()
          require('gitlinker').setup()
        end,
        requires = 'nvim-lua/plenary.nvim',
      }
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
    -- use 'cespare/vim-toml'
    -- use 'elzr/vim-json'
    -- use 'tpope/vim-fugitive'
    -- use 'tpope/vim-rhubarb'

    -- Comments
    use {
      'numToStr/Comment.nvim',
      config = [[require('plugins.comment')]]
    }

    -- GitHub
    use {
      {
        'pwntester/octo.nvim',
        config = function()
          require('octo').setup()
        end,
        requires = {
          'nvim-lua/plenary.nvim',
          'nvim-telescope/telescope.nvim',
          'kyazdani42/nvim-web-devicons',
        }
      },
      {
        'pwntester/codeql.nvim',
        config = function()
          require('codeql').setup {}
        end,
        requires = {
          'MunifTanjim/nui.nvim',
          'nvim-lua/telescope.nvim',
          'kyazdani42/nvim-web-devicons',
        }
      }
    }

    -- Project management
    use {
      'ahmedkhalf/project.nvim',
      config = function()
        require('project_nvim').setup({})
        require('telescope').load_extension('projects')
      end
    }

    -- Editor support
    use {
      'max-0406/autoclose.nvim',
      'p00f/nvim-ts-rainbow',
      {
        'Pocco81/AutoSave.nvim',
        config = function()
          require('autosave').setup()
          vim.g.autosave_state = true
        end
      },
      {
        'nacro90/numb.nvim',
        config = function()
          require('numb').setup()
        end
      }
    }

    -- Formatting
    use 'gpanders/editorconfig.nvim'

    -- Development
    use {
      'NTBBloodbath/rest.nvim',
      requires = { 'nvim-lua/plenary.nvim' },
      config = function()
        require('rest-nvim').setup({
          -- Open request results in a horizontal split
          result_split_horizontal = false,
          -- Skip SSL verification, useful for unknown certificates
          skip_ssl_verification = false,
          -- Highlight request on run
          highlight = {
            enabled = true,
            timeout = 150,
          },
          result = {
            -- toggle showing URL, HTTP info, headers at top the of result window
            show_url = true,
            show_http_info = true,
            show_headers = true,
          },
          -- Jump to request line on run
          jump_to_request = false,
          env_file = '.env',
          custom_dynamic_variables = {},
          yank_dry_run = true,
        })
      end
    }

    -- Test
    use {
      'rcarriga/vim-ultest',
      config = [[require('plugins.ultest')]],
      requires = 'vim-test/vim-test',
      run = ':UpdateRemotePlugins',
    }

    -- Remote development
    use 'jamestthompson3/nvim-remote-containers'

    -- Window management
    use {
      {
        'sindrets/winshift.nvim',
        config = function()
          require('winshift').setup()
        end
      },
      {
        'luukvbaal/stabilize.nvim',
        config = function()
          require('stabilize').setup({
            nested = "QuickFixCmdPost,DiagnosticChanged *"
          })
        end
      }
    }

    -- Automatically run a sync if the system has just installed Packer.nvim
    if BOOTSTRAPPED then require('packer').sync() end
  end,
  config = {
    display = {
      open_fn = require('packer.util').float,
    }
  }
})
