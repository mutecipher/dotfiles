-- nvim-tree.lua
-- https://github.com/kyazdani42/nvim-tree.lua

require('nvim-tree').setup({
  open_on_setup = true,
  update_focused_file = {
    enable = true
  },
  diagnostics = {
    enable = true
  },
})
