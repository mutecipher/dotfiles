" vim settings
set nocp " don't behave in vi compatible mode
set hidden " hides buffers rather than discarding them
set lpl " load plugins on startup
set shell=bash " default shell
set autochdir " auto change to directory of current file
set swf " create swap files
set bk " backup files
set backupdir=~/tmp " set a central area for backup files
set dir=~/tmp " swap file directory
set ofu=syntaxcomplete#Complete
filetype plugin indent on " set by filetype and indent
colorscheme desert " set color scheme
set background=dark " set background type
syntax enable " highlight syntax

" display options
set ruler " turn on ruler to show location of cursor
set number " show line numbers
set showmode " always show current mode
set modeline
set spl=en " set spellcheck lang

" text area settings
set expandtab
set laststatus=2
set tabstop=2 " set tab size
set shiftwidth=2 " 
set autoindent " self explanitory
set smartindent " self explanitory
set wrap " wrap to next line 
set wrapmargin=80 " wrap line after X chars
set textwidth=80 " set max line length
highlight ColorColumn ctermbg=233

" search settings
set ignorecase smartcase " ignore word case when searching
set incsearch " increment search with each char entered 
set hlsearch " highlight search results

" removing keymappings for arrow keys
map <Left> <Nop>
map <Right> <Nop>
map <Up> <Nop>
map <Down> <Nop>

" make changing windows easier
nnoremap <c-j> <c-w>j
nnoremap <c-k> <c-w>k
nnoremap <c-h> <c-w>h
nnoremap <c-l> <c-w>l

" make changing tabs easier
map <c-t> <esc>:tabnew<CR>
map <a-Tab> <esc>:tabNext<CR>

" reselect visual block after indent
vnoremap < <gv
vnoremap > >gv

" automatically reload vimrc when its saved
au BufWritePost .vimrc so ~/.vimrc

" better navigation of omnicomplete
set completeopt=longest,menuone
function! OmniPopup(action)
	if pumvisible()
		if a:action == 'j'
			return "\<C-N>"
		elseif a:action == 'k'
			return "\<C-P>"
		endif
	endif
	return a:action
endfunction

inoremap <silent><C-J> <C-R>=OmniPopup('j')<CR>
inoremap <silent><C-K> <C-R>=OmniPopul('k')<CR>

