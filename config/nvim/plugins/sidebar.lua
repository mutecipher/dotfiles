require('sidebar-nvim').setup({
    open = true,
    initial_width = 25,
    hide_statusline = true,
    sections = {
      "git",
      "diagnostics",
      "containers"
    },
    section_separator = "",
})
