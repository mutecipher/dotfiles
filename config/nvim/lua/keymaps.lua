-- keymaps.lua

local set = vim.keymap.set

local opts = {
  noremap = true,
  silent = true
}

-- Builtin vim maps
set('n', '<cr>', '<cmd>noh<cr>', opts)
set('n', 'Y', 'y$', opts)
set('n', '<leader>wh', '<c-w>h', opts)
set('n', '<leader>wj', '<c-w>j', opts)
set('n', '<leader>wk', '<c-w>k', opts)
set('n', '<leader>wl', '<c-w>l', opts)
set('n', '<leader>ws', '<cmd>split<cr>', opts)
set('n', '<leader>wv', '<cmd>vsplit<cr>', opts)

local has_telescope_builtin, ts_builtin = pcall(require, 'telescope.builtin')
if not has_telescope_builtin then
  return
end

local has_neotest, neotest = pcall(require, 'neotest')
if not has_neotest then
  return
end

-- Plugin maps
set('n', '<leader>c', function() ts_builtin.colorscheme() end, opts)
set('n', '<leader>fb', function() ts_builtin.buffers() end, opts)
set('n', '<leader>ff', function() ts_builtin.find_files() end, opts)
set('n', '<leader>fF', function() ts_builtin.find_files({ cwd = vim.fn.getcwd() }) end, opts)
set('n', '<leader>fd', function() ts_builtin.find_files({ cwd = '~/.dotfiles' }) end, opts)
set('n', '<leader>g', function() ts_builtin.live_grep() end, opts)
set('n', 'g?', function() ts_builtin.help_tags() end, opts)
set('n', '<leader>,', function() ts_builtin.vim_options() end, opts)
-- set('n', '<leader>tf', function() neotest.run.run(vim.fn.expand('%')) end, opts)
-- set('n', '<leader>tn', function() neotest.run.run() end, opts)
set('n', 'gs', function() neotest.summary.toggle() end, opts)
set('n', ']t', function() neotest.jump.next() end, opts)
set('n', '[t', function() neotest.jump.prev() end, opts)
set('n', '<leader>wq', function() require('bufdelete').bufdelete(vim.api.nvim_get_current_buf(), false) end, opts)
set('n', '<leader>W', function()
  require('bufdelete').bufdelete(vim.api.nvim_get_current_buf(), false)
  vim.api.nvim_win_close(vim.api.nvim_get_current_buf(), false)
end, opts)
set('n', '<leader>m', function() require('nvim-tree.api').tree.toggle() end, opts)
set('n', '<leader>B', function() require('dap').toggle_breakpoint() end, opts)

-- Tmux helpers
set('n', '<leader>sh', '<cmd>call system(\'tmux split-pane -v -p 25\')<cr>', opts)
