-- keymaps.lua

local opts = {
  noremap = true,
  silent = true
}

-- Builtin vim maps
vim.keymap.set('n', '<cr>',       '<cmd>noh<cr>', opts)
vim.keymap.set('n', 'Y',          'y$', opts)
vim.keymap.set('n', '<leader>wh',  '<c-w>h', opts)
vim.keymap.set('n', '<leader>wj',  '<c-w>j', opts)
vim.keymap.set('n', '<leader>wk',  '<c-w>k', opts)
vim.keymap.set('n', '<leader>wl',  '<c-w>l', opts)
vim.keymap.set('n', '<leader>ws',  '<cmd>split<cr>', opts)
vim.keymap.set('n', '<leader>wv',  '<cmd>vsplit<cr>', opts)

-- Plugin maps
vim.keymap.set('n', '<leader>c',  function() require('telescope.builtin').colorscheme() end, opts)
vim.keymap.set('n', '<leader>b',  function() require('telescope.builtin').buffers() end, opts)
vim.keymap.set('n', '<leader>f',  function() require('telescope.builtin').find_files() end, opts)
vim.keymap.set('n', '<leader>F',  function() require('telescope.builtin').find_files({cwd = vim.fn.getcwd()}) end, opts)
vim.keymap.set('n', '<leader>fd', function() require('telescope.builtin').find_files({cwd = '~/.dotfiles'}) end, opts)
vim.keymap.set('n', '<leader>g',  function() require('telescope.builtin').live_grep() end, opts)
vim.keymap.set('n', '<leader>H',  function() require('telescope.builtin').help_tags() end, opts)
vim.keymap.set('n', '<leader>,',  function() require('telescope.builtin').vim_options() end, opts)
vim.keymap.set('n', '<leader>tf', function() require('neotest').run.run(vim.fn.expand('%')) end, opts)
vim.keymap.set('n', '<leader>tn', function() require('neotest').run.run() end, opts)
vim.keymap.set('n', '<leader>ts', function() require('neotest').summary.toggle() end, opts)
vim.keymap.set('n', '<leader>w',  function() require('bufdelete').bufdelete(vim.api.nvim_get_current_buf(), false) end, opts)
vim.keymap.set('n', '<leader>W',  function()
  require('bufdelete').bufdelete(vim.api.nvim_get_current_buf(), false)
  vim.api.nvim_win_close(0, false)
end, opts)
vim.keymap.set('n', '<leader>m',  function() require('nvim-tree.api').tree.toggle() end, opts)
vim.keymap.set('n', '<leader>B',  function() require('dap').toggle_breakpoint() end, opts)

-- Tmux helpers
vim.keymap.set('n', '<leader>sh', '<cmd>call system(\'tmux split-pane -v -p 25\')<cr>', opts)
