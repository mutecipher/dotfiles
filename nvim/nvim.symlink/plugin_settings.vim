" plugin_settings.vim - Plugin configurations and settings

" airline {{{1

let g:airline#extensions#tabline#enabled = 1
let g:airline#extensions#tabline#formatter = 'unique_tail'
let g:airline_powerline_fonts = 1
let g:airline_theme='dark_minimal'

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
" ctrl-p {{{1

let g:ctrlp_user_command = ['.git/', 'git --git-dir=%s/.git ls-files -oc --exclude-standard']
" let g:ctrlp_user_command = 'rg %s --files --glob ""'
let g:ctrlp_max_files = 0
let g:ctrlp_working_path_mode = 'ra'
let g:ctrlp_root_markers = ['Gemfile', 'dev.yml']
let g:ctrlp_switch_buffer = 'et'
let g:ctrlp_use_caching = 0

" }}}1
" rust {{{1

let g:rustfmt_autosave = 1

" }}}1
" language client {{{1

set completefunc=LanguageClient#complete
let g:LanguageClient_serverCommands = {
    \ 'rust': ['rustup', 'run', 'stable', 'rls'],
    \ 'ruby': ['solargraph', 'stdio'],
    \ }

" }}}1
" deoplete {{{1

let g:deoplete#enable_at_startup = 1

" }}}1
" float-preview {{{1

set completeopt-=preview
let g:float_preview#docked = 1

" }}}1

" vim:ft=vim:fdm=marker:fdl=0
