-- plugins.lua
-- https://github.com/wbthomason/packer.nvim
-- See also: https://github.com/rockerBOO/awesome-neovim

--- Bootstrap neovim with packer.nvim on first boot
local ensure_packer = function()
  local install_path = vim.fn.stdpath('data') .. '/site/pack/packer/start/packer.nvim'
  if vim.fn.empty(vim.fn.glob(install_path)) > 0 then
    vim.fn.system({ 'git', 'clone', '--depth', '1', 'https://github.com/wbthomason/packer.nvim', install_path })
    vim.cmd [[packadd packer.nvim]]
    return true
  end
  return false
end

local packer_bootstrap = ensure_packer()

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
        require('colorizer').setup {}
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
    use 'nvim-treesitter/nvim-treesitter-context'

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
        require('telescope').setup {
          defaults = {
            file_ignore_patterns = {
              "^.git/",
              "^node_modules/",
              "^vendor/",
              "**/*/.keep",
              "**/cache/"
            }
          },
          pickers = {
            find_files = {
              theme = 'dropdown',
              previewer = false,
              no_ignore = true,
              hidden = true,
              prompt_title = '',
              prompt_prefix = '🔎 ',
            }
          }
        }
      end,
      requires = {
        'nvim-lua/plenary.nvim',
        { 'kyazdani42/nvim-web-devicons', opt = true },
      }
    }
    use {
      'nvim-telescope/telescope-fzy-native.nvim',
      config = function()
        require('telescope').load_extension('fzy_native')
      end
    }
    use 'nvim-telescope/telescope-symbols.nvim'
    use {
      'FeiyouG/command_center.nvim',
      config = function()
        require('telescope').load_extension('command_center')
      end,
    }

    -- Theme
    use 'projekt0n/github-nvim-theme'
    use {
      'xiyaowong/nvim-transparent',
      config = function()
        require('transparent').setup {
          extra_groups = { 'NvimTree', 'NvimTreeNormal', 'NvimTreeVertSplit' },
        }
      end
    }

    -- Utility
    use 'famiu/bufdelete.nvim'

    -- Icons
    use 'kyazdani42/nvim-web-devicons'

    -- Debugging
    use 'mfussenegger/nvim-dap'
    use 'rcarriga/nvim-dap-ui'

    -- Status line
    use {
      'nvim-lualine/lualine.nvim',
      config = [[
        require('plugins.lualine')
      ]],
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
          hijack_cursor = false,
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
    use { 'sindrets/diffview.nvim', requires = 'nvim-lua/plenary.nvim' }
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

    -- Editor support
    use 'p00f/nvim-ts-rainbow'
    use {
      'nacro90/numb.nvim',
      config = function()
        require('numb').setup {}
      end
    }

    -- Formatting
    use 'gpanders/editorconfig.nvim'
    use {
      'mfussenegger/nvim-lint',
      config = function()
        require('lint').linters_by_ft = {
          lua = { 'luacheck' },
          ruby = { 'standardrb' },
          markdown = { 'markdownlint' },
          python = { 'flake8' },
          sh = { 'shellcheck' },
          yaml = { 'yamllint' },
        }
      end
    }

    -- Test
    use {
      'nvim-neotest/neotest',
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
            require('neotest-python')({
              runner = 'unittest'
            }),
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

    -- Automatically run a sync if the system has just installed Packer.nvim
    if packer_bootstrap then
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
