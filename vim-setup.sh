#!/usr/bin/env bash
set -euo pipefail

# Create Vim directories if they don't exist
mkdir -p ~/.vim/colors
mkdir -p ~/.vim/autoload

# Download Gruvbox color scheme
curl -fLo ~/.vim/colors/gruvbox.vim --create-dirs \
  https://raw.githubusercontent.com/morhetz/gruvbox/master/colors/gruvbox.vim

# Download plug.vim (for plugin management, if needed later)
curl -fLo ~/.vim/autoload/plug.vim --create-dirs \
  https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

# Create .vimrc file with our configuration
cat >~/.vimrc <<'EOF'
" Basic Settings
syntax on
set background=dark
set number
set ruler
set showcmd
set incsearch
set hlsearch
set ignorecase
set smartcase
set expandtab
set tabstop=4
set shiftwidth=4
set autoindent
set smartindent
set backspace=indent,eol,start
set t_Co=256
set laststatus=2
set cursorline
set wildmenu
set showmatch
set scrolloff=3

" Optimize for SSH sessions
set ttyfast
set ttymouse=xterm2
set mouse=a
set ttimeoutlen=50

" Make Bash scripts use 2 spaces for indentation
autocmd FileType sh setlocal tabstop=2 shiftwidth=2

" Highlight trailing whitespace
highlight ExtraWhitespace ctermbg=red guibg=red
match ExtraWhitespace /\s\+$/
autocmd BufWinEnter * match ExtraWhitespace /\s\+$/
autocmd InsertLeave * match ExtraWhitespace /\s\+$/

" Color scheme settings
let g:gruvbox_contrast_dark = 'medium'
let g:gruvbox_improved_strings = 1
colorscheme gruvbox

" Status line configuration
set statusline=%F%m%r%h%w\ [FORMAT=%{&ff}]\ [TYPE=%Y]\ [POS=%l,%v][%p%%]\ %{strftime(\"%d/%m/%y\ -\ %H:%M\")}

" Bash-specific settings
let g:is_bash = 1
let g:sh_no_error = 1

" Useful keybindings for editing Bash scripts
nnoremap <F5> :!bash %<CR>          " Execute current script
nnoremap <F6> :!bash -n %<CR>       " Check syntax
nnoremap <F7> :!shellcheck %<CR>    " Run shellcheck if installed
EOF

echo "Vim configuration complete. Gruvbox color scheme installed."
echo "Note: If colors don't display correctly over SSH, ensure your terminal supports 256 colors."
echo "You may need to add 'export TERM=xterm-256color' to your .bashrc or .bash_profile"
