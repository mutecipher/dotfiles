" bindings.vim - Keybindings

noremap <C-b>     :NERDTreeToggle<CR>
noremap <C-p>     :Files<CR>
noremap <Leader>z :Goyo<CR>

nnoremap <Leader>ev :NERDTree ~/.config/nvim/<CR>
nnoremap <Leader>re :source ~/.config/nvim/init.vim<CR>

nnoremap <Leader>w :bd!<CR>
nnoremap <Leader>W :bufdo! bd<CR>
nnoremap <Leader>f :only<CR>

nnoremap <F5> :call LanguageClient_contextMenu()<CR>
nnoremap <silent> K :call LanguageClient#textDocument_hover()<CR>
nnoremap <silent> gd :call LanguageClient#textDocument_definition()<CR>
nnoremap <silent> <F1> :call LanguageClient#textDocument_rename()<CR>

nmap <silent> <Leader>tn :TestNearest<CR>
nmap <silent> <Leader>tf :TestFile<CR>
nmap <silent> <Leader>ts :TestSuite<CR>
nmap <silent> <Leader>tl :TestLast<CR>
nmap <silent> <Leader>tg :TestVisit<CR>


" vim:ft=vim:fdm=marker:fdl=0
