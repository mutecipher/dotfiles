" General
nnoremap Y y$

nnoremap <c-h> <c-w>h
nnoremap <c-j> <c-w>j
nnoremap <c-k> <c-w>k
nnoremap <c-l> <c-w>l

nnoremap <cr> <cmd>noh<cr>

" Telescope helpers
nnoremap <leader>ff <cmd>Telescope find_files<cr>
nnoremap <leader>fg <cmd>Telescope live_grep<cr>
nnoremap <leader>fb <cmd>Telescope buffers<cr>
nnoremap <leader>fh <cmd>Telescope help_tags<cr>
nnoremap <leader>cs <cmd>Telescope colorscheme<cr>
nnoremap <leader>df <cmd>Telescope find_files cwd=~/.dotfiles<cr>

" Git helpers
nnoremap <leader>gb <cmd>Telescope git_branches<cr>
nnoremap <leader>gc <cmd>Telescope git_commits<cr>
nnoremap <leader>gs <cmd>Telescope git_status<cr>
nnoremap <leader>bl <cmd>Gitsigns blame_line<cr>
nnoremap gB <cmd>Git blame<cr>

" Tmux helpers
nnoremap <leader>sh <cmd>call system("tmux split-pane -v -p 25")<cr>

" Custom maps
nnoremap <leader>fif <cmd>lua require('mutecipher').fuzzy_file_search()<cr>
