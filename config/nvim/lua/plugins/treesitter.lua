-- treesitter.lua

require('nvim-treesitter.configs').setup({
  ensure_installed = {
    'html',
    'http',
    'css',
    'javascript',
    'json',
    'jsonc',
    'markdown',
    'yaml',
    'typescript',
    'python',
    'rust',
    'lua',
    'go',
    'ruby',
    'vim'
  },
  sync_install = true,
  auto_install = true,
  highlight = {
    enable = true
  },
  playground = {
    enable = true,
    disable = {},
    updatetime = 25,
    persist_queries = false,
    keybindings = {
      toggle_query_editor = 'o',
      toggle_hl_groups = 'i',
      toggle_injected_languages = 't',
      toggle_anonymous_nodes = 'a',
      toggle_language_display = 'I',
      focus_language = 'f',
      unfocus_language = 'F',
      update = 'R',
      goto_node = '<cr>',
      show_help = '?',
    },
  },
  query_linter = {
    enable = true,
    use_virtual_text = true,
    lint_events = { "BufWrite", "CursorHold" },
  },
  rainbow = {
    enable = true
  },
  textobjects = {
    move = {
      enable = true,
      set_jumps = true,
      goto_next_start = {
        [']m'] = '@function.outer',
        [']c'] = '@class.outer',
      },
      goto_previous_start = {
        ['[m'] = '@function.outer',
        ['[c'] = '@class.outer',
      },
    }
  }
  -- refactor = {
  --   highlight_definitions = {
  --     enable = true,
  --     clear_on_cursor_move = true,
  --   },
  --   -- smart_rename = {
  --   --   enable = true,
  --   --   keymaps = {
  --   --     smart_rename = 'grr',
  --   --   },
  --   -- },
  --   navigation = {
  --     enable = true,
  --     keymaps = {
  --       goto_definition = 'gnd',
  --       list_definitions = 'gnD',
  --       list_definitions_toc = 'gO',
  --       goto_next_usage = '<a-*>',
  --       goto_previous_usage = '<a-#>',
  --     },
  --   },
  -- },
  -- textobjects = {
  --   select = {
  --     enable = true,
  --
  --     -- Automatically jump forward to textobj, similar to targets.vim
  --     lookahead = true,
  --
  --     keymaps = {
  --       -- You can use the capture groups defined in textobjects.scm
  --       ['af'] = '@function.outer',
  --       ['if'] = '@function.inner',
  --       ['ac'] = '@class.outer',
  --       ['ic'] = '@class.inner',
  --     },
  --   },
  --   swap = {
  --     enable = true,
  --     swap_next = {
  --       ['<leader>a'] = '@parameter.inner',
  --     },
  --     swap_previous = {
  --       ['<leader>A'] = '@parameter.inner',
  --     },
  --   },
  --   move = {
  --     enable = true,
  --     set_jumps = true, -- whether to set jumps in the jumplist
  --     goto_next_start = {
  --       [']m'] = '@function.outer',
  --       [']]'] = '@class.outer',
  --     },
  --     goto_next_end = {
  --       [']M'] = '@function.outer',
  --       [']['] = '@class.outer',
  --     },
  --     goto_previous_start = {
  --       ['[m'] = '@function.outer',
  --       ['[['] = '@class.outer',
  --     },
  --     goto_previous_end = {
  --       ['[M'] = '@function.outer',
  --       ['[]'] = '@class.outer',
  --     },
  --   },
  --   lsp_interop = {
  --     enable = true,
  --     border = 'none',
  --     -- peek_definition_code = {
  --     --   ['<leader>df'] = '@function.outer',
  --     --   ['<leader>dF'] = '@class.outer',
  --     -- },
  --   }
  -- },
})
