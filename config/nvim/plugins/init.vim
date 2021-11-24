" Always have `vim-plug` at the top as, obviously, all subsequent plugins rely on it.
source $HOME/.config/nvim/plugins/plug.vim

lua require('nvim-gps').setup{}
lua require('cokeline').setup{}
lua require('lualine').setup({ sections = { lualine_c = { { require('nvim-gps').get_location, cond = require('nvim-gps').is_available }, } } })

source $HOME/.config/nvim/plugins/completion.lua
source $HOME/.config/nvim/plugins/debugger.lua
source $HOME/.config/nvim/plugins/gitsigns.lua
source $HOME/.config/nvim/plugins/lspconfig.lua
source $HOME/.config/nvim/plugins/telescope.lua
source $HOME/.config/nvim/plugins/vsnip.vim
