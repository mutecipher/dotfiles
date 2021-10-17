local has_telescope, telescope = pcall(require, 'telescope.builtin')
if not has_telescope then
  error "requires telescope.nvim to use"
end

local M = {}

function M.find_in_file()
  local opts = {
    previewer = false,
    sorting_strategy = "ascending",
  }

  telescope.current_buffer_fuzzy_find(opts)
end

return M
