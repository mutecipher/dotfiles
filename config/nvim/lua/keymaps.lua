-- keymaps.lua

local opts = {
  noremap = true,
  silent = true
}

vim.keymap.set('n', '<cr>', '<cmd>noh<cr>', opts)
vim.keymap.set('n', '<leader>bl', '<cmd>Gitsigns blame_line<cr>', opts)
vim.keymap.set('n', '<leader>cs', '<cmd>Telescope colorscheme<cr>', opts)
vim.keymap.set('n', '<leader>df', '<cmd>Telescope find_files cwd=~/.dotfiles<cr>', opts)
vim.keymap.set('n', '<leader>fb', '<cmd>Telescope buffers<cr>', opts)
vim.keymap.set('n', '<leader>ff', '<cmd>Telescope find_files hidden=true<cr>', opts)
vim.keymap.set('n', '<leader>fg', '<cmd>Telescope live_grep<cr>', opts)
vim.keymap.set('n', '<leader>fh', '<cmd>Telescope help_tags<cr>', opts)
vim.keymap.set('n', '<leader>gb', '<cmd>Telescope git_branches<cr>', opts)
vim.keymap.set('n', '<leader>gc', '<cmd>Telescope git_commits<cr>', opts)
vim.keymap.set('n', '<leader>gs', '<cmd>Telescope git_status<cr>', opts)
vim.keymap.set('n', '<leader>h', '<c-w>h', opts)
vim.keymap.set('n', '<leader>j', '<c-w>j', opts)
vim.keymap.set('n', '<leader>k', '<c-w>k', opts)
vim.keymap.set('n', '<leader>l', '<c-w>l', opts)
vim.keymap.set('n', '<leader>sh', '<cmd>call system("tmux split-pane -v -p 25")<cr>', opts)
vim.keymap.set('n', '<leader>ss', '<cmd>split<cr>', opts)
vim.keymap.set('n', '<leader>tf', function() require("neotest").run.run(vim.fn.expand("%")) end, opts)
vim.keymap.set('n', '<leader>tn', function() require("neotest").run.run() end, opts)
vim.keymap.set('n', '<leader>ts', function() require("neotest").summary.toggle() end, opts)
vim.keymap.set('n', '<leader>vs', '<cmd>vsplit<cr>', opts)
vim.keymap.set('n', '<leader>w', '<cmd>Bdelete<cr>', opts)
vim.keymap.set('n', '<leader>{', '<cmd>BufferLineCyclePrev<cr>', opts)
vim.keymap.set('n', '<leader>}', '<cmd>BufferLineCycleNext<cr>', opts)
vim.keymap.set('n', 'Y', 'y$', opts)
vim.keymap.set('n', '[t', '<Plug>(ultest-prev-fail)', { noremap = false, silent = true })
vim.keymap.set('n', ']t', '<Plug>(ultest-next-fail)', { noremap = false, silent = true })
vim.keymap.set('n', 'm', '<cmd>NvimTreeToggle<cr>', opts)

-- TODO: Configure these eventually
-- imap <expr> <Tab>   vsnip#jumpable(1)   ? '<Plug>(vsnip-jump-next)'      : '<Tab>'
-- imap <expr> <S-Tab> vsnip#jumpable(-1)  ? '<Plug>(vsnip-jump-prev)'      : '<S-Tab>'
-- smap <expr> <Tab>   vsnip#jumpable(1)   ? '<Plug>(vsnip-jump-next)'      : '<Tab>'
-- smap <expr> <S-Tab> vsnip#jumpable(-1)  ? '<Plug>(vsnip-jump-prev)'      : '<S-Tab>'
