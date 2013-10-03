" ==========
" random vim settings
" ==========

set nocp " don't behave in vi compatible mode
set listchars=tab:>-,eol:-
set lpl " load plugins on startup
set shell=bash " default shell
set autochdir " auto change to directory of current file
set swf " create swap files
set bk " backup files
set backupdir=~/.tmp " set a central area for backup files
set dir=~/.tmp " swap file directory
"set ofu=syntaxcomplete#Complete
filetype plugin indent on " set by filetype and indent
colorscheme desert " set color scheme
set background=dark " set background type
syntax enable " highlight syntax
set scrolloff=10
set splitbelow " new window goes below
set splitright " new window goes right
"set wildmode=list:longest
"set wildmenu
"set wildignore=*.o,*.obj,*~
set lazyredraw


" ==========
" display options
" ==========

set ruler " turn on ruler to show location of cursor
set number " show line numbers
set showmode " always show current mode
set modeline
set spl=en " set spellcheck lang
set cursorline " cursor highlighting
set colorcolumn=79
set lcs=tab:›\ ,trail:·,eol:¬,nbsp:_



" ==========
" text area settings
" ==========

set expandtab
set smarttab
set laststatus=2
set tabstop=2 " set tab size
set shiftwidth=2 " 
set autoindent " self explanitory
set smartindent " self explanitory
set wrap " wrap to next line 
set wrapmargin=80 " wrap line after X chars
set textwidth=80 " set max line length
highlight ColorColumn ctermbg=233
"set foldcolumn=4
"set foldenable
"set foldlevel=2
"set foldmethod=manual
"set foldminlines=0
set relativenumber


" ==========
" search settings
" ==========

set ignorecase smartcase " ignore word case when searching
set incsearch " increment search with each char entered 
set hlsearch " highlight search results


" ==========
" misc functions/configs
" ==========

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


" ========== 
" cursorline highlighting
" ==========

hi CursorLine cterm=NONE ctermbg=black

augroup CursorLine
  au!
  au VimEnter,WinEnter,BufWinEnter * setlocal cursorline
  au WinLeave * setlocal nocursorline
augroup END


" ==========
" automatically reload vimrc when its saved
" ==========

au BufWritePost .vimrc so ~/.vimrc


" ==========
" stuff that's not being used right now
" ==========

" hard to type things
"imap >> →
"imap << ←
"imap ^^ ↑
"imap VV ↓
"imap aa λ

" better navigation of omnicomplete
"  set completeopt=longest,menuone
"  function! OmniPopup(action)
"    if pumvisible()
"      if a:action == 'j'
"        return "\<C-N>"
"      elseif a:action == 'k'
"        return "\<C-P>"
"      endif
"    endif
"    return a:action
"  endfunction

"  inoremap <silent><C-J> <C-R>=OmniPopup('j')<CR>
"  inoremap <silent><C-K> <C-R>=OmniPopul('k')<CR>

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
