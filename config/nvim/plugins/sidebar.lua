require('sidebar-nvim').setup({
    open = true,
    initial_width = 25,
    hide_statusline = true,
    sections = {
      "git",
      "todos",
      "symbols",
      "diagnostics",
      "containers"
    },
    section_separator = "",
    disable_closing_prompt = true
})
