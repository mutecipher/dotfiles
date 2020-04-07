" bindings.vim - Keybindings

noremap <C-b>     :NERDTreeToggle<CR>
noremap <C-p>     :GitFiles<CR>
noremap <Leader>t :call RunCurrentSpecFile()<CR>
noremap <Leader>s :call RunNearestSpec()<CR>
noremap <Leader>l :call RunLastSpec()<CR>
noremap <Leader>a :call RunAllSpecs()<CR>
noremap <Leader>z :Goyo<CR>

nnoremap <Leader>ev :NERDTree ~/.config/nvim/<CR>
nnoremap <Leader>re :source ~/.config/nvim/init.vim<CR>

nnoremap <Leader>w :bd!<CR>
nnoremap <Leader>W :bufdo! bd<CR>
nnoremap <Leader>f :only<CR>

nnoremap <F5> :call LanguageClient_contextMenu()<CR>
" Or map each action separately
nnoremap <silent> K :call LanguageClient#textDocument_hover()<CR>
nnoremap <silent> gd :call LanguageClient#textDocument_definition()<CR>
nnoremap <silent> <F1> :call LanguageClient#textDocument_rename()<CR>

nmap <silent> <Leader>tn :TestNearest<CR>
nmap <silent> <Leader>tf :TestFile<CR>
nmap <silent> <Leader>ts :TestSuite<CR>
nmap <silent> <Leader>tl :TestLast<CR>
nmap <silent> <Leader>tg :TestVisit<CR>

autocmd BufWritePre *.go :call LanguageClient#textDocument_formatting_sync()

" vim:ft=vim:fdm=marker:fdl=0
