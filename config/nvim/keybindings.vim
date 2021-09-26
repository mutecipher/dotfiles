" keybindings.vim - custom keybindings.

" navigation {{{1

" General
nnoremap Y y$

nnoremap <c-h> <c-w>h
nnoremap <c-j> <c-w>j
nnoremap <c-k> <c-w>k
nnoremap <c-l> <c-w>l

" Neovim helpers
nnoremap <leader>ff <cmd>Telescope find_files<cr>
nnoremap <leader>fg <cmd>Telescope live_grep<cr>
nnoremap <leader>fb <cmd>Telescope buffers<cr>
nnoremap <leader>fh <cmd>Telescope help_tags<cr>
nnoremap <leader>cs <cmd>Telescope colorscheme<cr>

" Git helpers
nnoremap <leader>gb <cmd>Telescope git_branches<cr>
nnoremap <leader>gc <cmd>Telescope git_commits<cr>
nnoremap <leader>gs <cmd>Telescope git_status<cr>

" Quickfix
nnoremap <leader>qf <cmd>Telescope quickfix<cr>

" Tmux helpers
nnoremap <Leader>sh <cmd>call system("tmux split-pane -v -p 25")<cr>

" }}}1

" vim:ft=vim:fdm=marker:fdl=0
