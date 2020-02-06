" bindings.vim - Keybindings

noremap   <C-b>     :NERDTreeToggle<CR>
noremap   <Leader>t :call RunCurrentSpecFile()<CR>
noremap   <Leader>s :call RunNearestSpec()<CR>
noremap   <Leader>l :call RunLastSpec()<CR>
noremap   <Leader>a :call RunAllSpecs()<CR>
noremap   <Leader>z :Goyo<CR>

nnoremap  <Leader>ev  :NERDTree ~/.config/nvim/<CR>
nnoremap  <Leader>re  :source ~/.config/nvim/init.vim<CR>

" vim:ft=vim:fdm=marker:fdl=0
