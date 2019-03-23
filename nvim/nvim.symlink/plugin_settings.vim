" plugin_settings.vim - Plugin configurations and settings

" airline {{{1

let g:airline#extensions#tabline#enabled = 1
let g:airline#extensions#tabline#formatter = 'unique_tail'
let g:airline_powerline_fonts = 1
let g:airline_theme='dark_minimal'

" }}}1
" goyo {{{1

let g:goyo_width = '90%'
let g:goyo_height = '90%'

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
" vundle {{{1

let g:vundle_default_git_proto = 'git'

" }}}1
" org.vim {{{1

let g:org#debug = 1

" }}}1
" ctrl-p {{{1

let g:ctrlp_working_path_mode = 'ra'
let g:ctrlp_root_markers = ['Gemfile', 'dev.yml']
let g:ctrlp_switch_buffer = 'et'

" }}}1

" vim:ft=vim:fdm=marker:fdl=0
