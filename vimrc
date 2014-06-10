" ==============================================================================
" Cory's .vimrc
" ==============================================================================


" == system settings ===========================================================
au BufWritePost .vimrc so ~/.vimrc              " auto reload .vimrc when edited
"au BufWritePre * :%s/\s\+$//           " remove all trailing whitespace on save

set nocp                                    " don't behave in vi compatible mode
set history=50                                        " keep 50 lines in history
set ruler                             " turn on ruler to show location of cursor
set autoread                                     " autoread when file is changed

syntax on                                           " enable syntax highlighting
filet on                                             " enable filetype detection
filet indent on                                " enable per filetype indentation
filet plugin on                             " enable per filetype plugin loading
set lpl                                                " load plugins on startup

set shell=bash                                               " set default shell
set autochdir                         " auto change to directory of current file
set swf                                                      " create swap files
set bk                                                            " backup files
set backupdir=~/.tmp                       " set a central area for backup files
set dir=~/.tmp                                             " swap file directory
set wildmenu
set wildmode=list:longest
set wildignore=*.o,*.obj,*~

set noerrorbells
set novisualbell

" ==============================================================================

" == statusline settings =======================================================
set statusline=                                                   " clear buffer
set statusline+=[%n]\                                            " buffer number
set statusline+=%f\                                                       " path
set statusline+=%h%m%r%w                                                 " flags
set statusline+=[%{strlen(&ft)?&ft:'none'},                           " filetype
set statusline+=%{strlen(&fenc)?&fenc:&enc},                          " encoding
set statusline+=%{&fileformat}]                                         " format
set statusline+=%=                                                 " align right
set statusline+=%{synIDattr(synID(line('.'),col('.'),1),'name')}\    " highlight
set statusline+=%b,0x%-8B\                                        " current char
set statusline+=%-14.(%l/%L,%c%V%)\ %<%P                                " offset
" ==============================================================================


" == buffer settings ===========================================================
set lazyredraw                                      " only redraw when necessary
set scrolloff=15                                                 " scroll offset
set splitbelow                                           " new window goes below
set splitright                                           " new window goes right
set relativenumber                    " line numbers relative to cursor position
"set number                                                  " show line numbers
set showmode                                          " always show current mode
set spl=en                                                 " set spellcheck lang
set cursorline                                             " cursor highlighting
let &colorcolumn="81,".join(range(82,199),",")
"set colorcolumn=81                          " draw column to mark 81 characters
set list                                        " display unprintable characters
set lcs=tab:›\ ,trail:·,eol:¬,nbsp:_                     " values for whitespace
set nuw=3
"set modeline 
                                               " resize vsplits on window resize
au VimResized * exe "normal! \<C-w>="
" ==============================================================================


" == color settings ============================================================
colorscheme desert                                            " set color scheme
set background=dark                                        " set background type

                                              " change some colorscheme settings
hi ColorColumn ctermbg=233
hi CursorLine cterm=NONE ctermbg=234
hi SignColumn ctermbg=233
hi LineNr ctermbg=233 ctermfg=240

hi StatusLine ctermfg=234 ctermbg=15

hi Comment ctermbg=233
hi Folded ctermfg=15
hi FoldColumn ctermbg=11
hi Search ctermbg=10 ctermfg=238

hi Pmenu ctermbg=233 ctermfg=239
hi PmenuSbar ctermbg=233
hi PmenuThumb ctermbg=233
hi PmenuSel ctermbg=22 ctermfg=11
" ==============================================================================


" == text area settings ========================================================
set textwidth=80                                           " set max line length
set expandtab                                       " use spaces rather than tab
set smarttab                                                 " make tabs smarter
set laststatus=2                                      " get all the status lines
set tabstop=2                                " number of spaces a tab counts for
set autoindent                                                " self explanitory
set shiftwidth=2                        " number of spaces to use for autoindent
set smartindent                                               " self explanitory
set showmatch                                             " show matching braces
set mat=1                               " length of time to show matching braces
set encoding=utf8                                             " encoding in utf8
set lbr                                                       " enable linebreak
set tw=500                                             " break on 500 characters
set completeopt=longest,menuone                    " make omnicomplete menu nice
"set wrap                                                            " wrap text
"set wrapmargin=80                                         " wrap after 80 chars
" ==============================================================================


" == search settings ===========================================================
set ignorecase                                    " ignore word case when search
set smartcase                                          " when searching be smart
set incsearch                          " increment search with each char entered
set hlsearch                                          " highlight search results
" ==============================================================================


" == alternate key mappings ====================================================
                                           " removing keymappings for arrow keys
map <Left> <Nop>
map <Right> <Nop>
map <Up> <Nop>
map <Down> <Nop>

                                             " make j and k work how they should
nnoremap j gj
nnoremap k gk

                                                  " make changing windows easier
nnoremap <c-j> <c-w>j
nnoremap <c-k> <c-w>k
nnoremap <c-h> <c-w>h
nnoremap <c-l> <c-w>l

                                                        " faster window resizing
if bufwinnr(1)
  map + <c-W>+
  map - <c-W>-
endif

                                                     " make changing tabs easier
map <c-t> <esc>:tabnew<CR>
map <c-Right> <esc>:tabNext<CR>
map <c-Left> <esc>:tabprevious<CR>

                                              " use arrow keys to change buffers
noremap <Left> :bp<CR>
noremap <Right> :bn<CR>

                                            " reselect visual block after indent
vnoremap < <gv
vnoremap > >gv
" ==============================================================================


" == functions =================================================================
                                              " cursorline only in active window
augroup CursorLine
  au!
  au VimEnter,WinEnter,BufWinEnter * setlocal cursorline
  au WinLeave * setlocal nocursorline
augroup END
" ==============================================================================


" == not in use ================================================================
" text selection movement (single lines)
"nnoremap <c-Up> ddkP
"nnoremap <c-Down> ddp

" text selection movement (multiple lines)
"vmap <c-Up> xkP`[V`]
"vmap <c-Down> xp`[V`]


" hard to type things
"imap >> →
"imap << ←
"imap ^^ ↑
"imap VV ↓
"imap aa λ

" hacky autocomplete for braces
"inoremap '' ''<Left>
"inoremap "" ""<Left>
"inoremap () ()<Left>
"inoremap <> <><Left>
"inoremap {} {}<Left>
"inoremap [] []<Left>
"inoremap () ()<Left>

"inoremap ' ''<Right>
"inoremap " ""<Right>
"inoremap ( ()<Right>
"inoremap < <><Right>
"inoremap { {}<Right>
"inoremap [ []<Right>
"inoremap ( ()<Right>
" ==============================================================================
