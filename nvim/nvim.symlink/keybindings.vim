" keybindings.vim - custom keybindings.

" navigation {{{1

noremap <C-b>     :NERDTreeToggle<CR>
noremap <C-p>     :Files<CR>
noremap <Leader>z :Goyo<CR>

nnoremap <Leader>ev :NERDTree ~/.config/nvim/<CR>
nnoremap <Leader>re :source ~/.config/nvim/init.vim<CR>
nnoremap <Leader>T :call system("tmux split-pane -v -p 25")<CR>

" }}}1
" window management {{{1

nnoremap <Leader>w :bd!<CR>
nnoremap <Leader>W :bufdo! bd<CR>
nnoremap <Leader>f :only<CR>

" }}}1
" language server {{{1

nnoremap <F5> :call LanguageClient_contextMenu()<CR>
nnoremap <silent> K :call LanguageClient#textDocument_hover()<CR>
nnoremap <silent> gd :call LanguageClient#textDocument_definition()<CR>
nnoremap <silent> <F1> :call LanguageClient#textDocument_rename()<CR>
nnoremap <silent> <F8> :call LanguageClient#textDocument_codeAction()<CR>

" }}}1
" testing {{{1

nmap <silent> <Leader>tn :TestNearest<CR>
nmap <silent> <Leader>tf :TestFile<CR>
nmap <silent> <Leader>ts :TestSuite<CR>
nmap <silent> <Leader>tl :TestLast<CR>
nmap <silent> <Leader>tg :TestVisit<CR>

" }}}1

" vim:ft=vim:fdm=marker:fdl=0
