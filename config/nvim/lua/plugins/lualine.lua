-- lualine.lua
-- https://github.com/nvim-lualine/lualine.nvim

local has_gps, gps = pcall(require, 'nvim-gps');
if not has_gps then
  require('lualine').setup()
else
  gps.setup{}

  require('lualine').setup({
    options = { theme = 'github_light' },
    sections = {
      lualine_c = {
        { gps.get_location, cond = gps.is_available }
      }
    }
  })
end

