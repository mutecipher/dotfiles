" plugin_settings.vim - Plugin configurations and settings

" airline {{{1

let g:airline#extensions#tabline#enabled = 1
let g:airline#extensions#tabline#formatter = 'unique_tail'
let g:airline_powerline_fonts = 1
let g:airline_theme='gruvbox'

" }}}1
" goyo {{{1

let g:goyo_width = '95%'
let g:goyo_height = '95%'
let g:goyo_linenr = 1

" }}}1
" nerdtree {{{1

let g:NERDTreeWinPos = "right"

" }}}1
" rspec {{{1

let g:rspec_command = "tmux split-window bundle exec rspec {spec}"

" }}}1
" gitgutter {{{1

highlight GitGutterAdd ctermfg=2
highlight GitGutterChange ctermfg=3
highlight GitGutterDelete ctermfg=1

" }}}1
" org.vim {{{1

let g:org#debug = 1

" }}}1
" rust {{{1

let g:rustfmt_autosave = 1

" }}}1
" language client {{{1

set completefunc=LanguageClient#complete
let g:LanguageClient_serverCommands = {
    \ 'rust': ['rustup', 'run', 'stable', 'rls'],
    \ 'ruby': ['bundle', 'exec', 'srb', 'tc', '--lsp'],
    \ 'go': ['gopls'],
    \ }

" }}}1
" deoplete {{{1

let g:deoplete#enable_at_startup = 1

" }}}1
" float-preview {{{1

set completeopt-=preview
let g:float_preview#docked = 0

" }}}1
" vim-go {{{1

let g:go_test_show_name = 1

" }}}1
" fzf.vim {{{1

let g:fzf_buffers_jump = 1
let g:fzf_tags_command = 'ripper-tags -R'

" }}}1
" vim-test {{{1

let test#strategy = "neovim"

" }}}1

" vim:ft=vim:fdm=marker:fdl=0
