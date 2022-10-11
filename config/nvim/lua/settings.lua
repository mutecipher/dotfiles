-- settings.lua

vim.g.mapleader = ' '
vim.g.loaded_ruby_provider = 0
vim.g.loaded_node_provider = 0
vim.g.loaded_perl_provider = 0

vim.opt.autoindent = true
vim.opt.autoread = true
vim.opt.autowrite = true
vim.opt.colorcolumn = { '121' }
vim.opt.completeopt = { 'menuone', 'noinsert', 'noselect' }
vim.opt.directory = { '/tmp/' }
vim.opt.expandtab = true
vim.opt.exrc = true
vim.opt.foldenable = true
vim.opt.hlsearch = true
vim.opt.ignorecase = true
vim.opt.incsearch = true
vim.opt.laststatus = 3
vim.opt.mouse = 'a'
vim.opt.number = true
vim.opt.numberwidth = 5
vim.opt.relativenumber = true
vim.opt.scrolloff = 4
vim.opt.secure = true
vim.opt.shiftwidth = 2
vim.opt.showcmd = true
vim.opt.showmatch = true
vim.opt.sidescrolloff = 10
vim.opt.smartcase = true
vim.opt.softtabstop = 2
vim.opt.splitbelow = true
vim.opt.splitright = true
vim.opt.syntax = 'on'
vim.opt.tabstop = 2
vim.opt.termguicolors = true
vim.opt.updatetime = 500
vim.opt.wildmenu = true
vim.opt.wrap = false
vim.opt.timeoutlen = 500

vim.api.nvim_create_autocmd({ 'BufRead', 'BufNewFile' }, {
  pattern = {"*.astro"},
  callback = function()
    vim.bo.filetype = "astro"
  end
})
