-- nvim-tree.lua
-- https://github.com/kyazdani42/nvim-tree.lua

require('nvim-tree').setup({
  disable_netrw = true,
  hijack_cursor = false,
  ignore_buffer_on_setup = true,
  update_focused_file = {
    enable = true
  },
  diagnostics = {
    enable = true
  },
})
