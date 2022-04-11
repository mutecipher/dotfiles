local sidebar = require('sidebar-nvim')
local opts = {
    open = true,
    initial_width = 25,
    hide_statusline = true,
    section_separator = "",
    disable_closing_prompt = true
}

sidebar.setup(opts)
