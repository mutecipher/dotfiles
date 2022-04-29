-- lualine.lua
-- https://github.com/nvim-lualine/lualine.nvim

local gps = require('nvim-gps');

gps.setup{}

require('lualine').setup({
  sections = {
    lualine_c = {
      {
        gps.get_location,
        cond = gps.is_available
      },
    }
  }
})
