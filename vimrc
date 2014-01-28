" ==============================================================================
" Cory's .vimrc
" ==============================================================================


" == system settings ===========================================================
au BufWritePost .vimrc so ~/.vimrc " auto reload .vimrc when edited

set nocp " don't behave in vi compatible mode
set history=50 " keep 50 lines in history
set ruler " turn on ruler to show location of cursor
set autoread " autoread when file is changed

syntax on " enable syntax highlighting
filet on " enable filetype detection
filet indent on " enable per filetype indentation
filet plugin on " enable per filetype plugin loading
set lpl " load plugins on startup

set shell=bash " set default shell
set autochdir " auto change to directory of current file
set swf " create swap files
set bk " backup files
set backupdir=~/.tmp " set a central area for backup files
set dir=~/.tmp " swap file directory
set wildmode=list:longest
set wildmenu
set wildignore=*.o,*.obj,*~

set noerrorbells
set novisualbell


" == buffer settings ===========================================================
set lazyredraw " only redraw when necessary
set scrolloff=15 " scroll offset
set splitbelow " new window goes below
set splitright " new window goes right
set relativenumber " line numbers relative to cursor position
set showmode " always show current mode
set spl=en " set spellcheck lang
set cursorline " cursor highlighting
set colorcolumn=81 " draw column to mark 81 characters
set list " display unprintable characters
set lcs=tab:›\ ,trail:·,eol:¬,nbsp:_ " values for whitespace
" set modeline
" set number " show line numbers


" == color settings ============================================================
colorscheme desert " set color scheme
set background=dark " set background type

hi ColorColumn ctermbg=232
hi CursorLine cterm=NONE ctermbg=233
hi SignColumn ctermbg=233
hi LineNr ctermbg=232 ctermfg=239

hi Comment ctermbg=233
hi Folded ctermfg=15
hi FoldColumn ctermbg=11

hi Pmenu ctermbg=233 ctermfg=239
hi PmenuSbar ctermbg=233
hi PmenuThumb ctermbg=233
hi PmenuSel ctermbg=22 ctermfg=11


" == text area settings ========================================================
set textwidth=80 " set max line length
set expandtab " use spaces rather than tab
set smarttab " make tabs smarter
set laststatus=2 " get all the status lines
set tabstop=2 " number of spaces a tab counts for
set autoindent " self explanitory
set shiftwidth=2 " number of spaces to use for autoindent
set smartindent " self explanitory
"set wrap " wrap text to next line 
"set wrapmargin=80 " wrap line after X chars
set showmatch " show matching braces
set mat=2 " length of time to show matching braces
set encoding=utf8 " encoding in utf8
set lbr " enable linebreak
set tw=500 " break on 500 characters


" == search settings ===========================================================
set ignorecase " igonore word case when search
set smartcase " when searching be smart
set incsearch " increment search with each char entered 
set hlsearch " highlight search results


" == misc functions/configs ====================================================
" better navigation of omnicomplete
set omnifunc=syntaxcomplete#Complete
set completeopt=longest,menuone
"function! OmniPopup(action)
  "if pumvisible()
    "if a:action == 'j'
      "return "\<C-N>"
    "elseif a:action == 'k'
      "return "\<C-P>"
    "endif
  ""endif
  "return a:action
"endfunction

"inoremap <silent><C-J> <C-R>=OmniPopup('j')<CR>
"inoremap <silent><C-K> <C-R>=OmniPopul('k')<CR>

" text selection movement (single lines)
nnoremap <c-Up> ddkP
nnoremap <c-Down> ddp
" text selection movement (multiple lines)
vmap <c-Up> xkP`[V`]
vmap <c-Down> xp`[V`]

" removing keymappings for arrow keys
map <Left> <Nop>
map <Right> <Nop>
map <Up> <Nop>
map <Down> <Nop>
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

" reselect visual block after indent
vnoremap < <gv
vnoremap > >gv


" ==============================================================================
" cursorline highlighting
" ==============================================================================


augroup CursorLine
  au!
  au VimEnter,WinEnter,BufWinEnter * setlocal cursorline
  au WinLeave * setlocal nocursorline
augroup END


" ==============================================================================
" automatically reload vimrc when its saved
" ==============================================================================



" ==============================================================================
" stuff that's not being used right now
" ==============================================================================

" hard to type things
"imap >> →
"imap << ←
"imap ^^ ↑
"imap VV ↓
"imap aa λ

" inoremap '' ''<Left>
" inoremap "" ""<Left>
" inoremap () ()<Left>
" inoremap <> <><Left>
" inoremap {} {}<Left>
" inoremap [] []<Left>
" inoremap () ()<Left>

" inoremap ' ''<Right>
" inoremap " ""<Right>
" inoremap ( ()<Right>
" inoremap < <><Right>
" inoremap { {}<Right>
" inoremap [ []<Right>
" inoremap ( ()<Right>
