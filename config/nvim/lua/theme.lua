-- theme.lua
-- https://github.com/projekt0n/github-nvim-theme

local ok, github = pcall(require, 'github-theme')
if not ok then
  return
end

github.setup({})
-- vim.cmd('colorscheme github_dark')
