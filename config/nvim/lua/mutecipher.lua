local M = {}

M.fuzzy_file_search = function()
  local has_telescope, telescope = pcall(require, 'telescope.builtin')
  if not has_telescope then
    error "requires telescope.nvim to use"
  end

  local opts = {
    previewer = false,
    sorting_strategy = "ascending",
  }

  telescope.current_buffer_fuzzy_find(opts)
end

return M
