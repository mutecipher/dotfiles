export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="crcandy"
plugins=(
  colored-man-pages
  encode64
  git
  git-auto-fetch
  gpg-agent
  safe-paste
  themes
  zsh_reload
)
source "$ZSH/oh-my-zsh.sh"

source "$HOME/.zshaliases"
source "$HOME/.zshenv"
source "$HOME/.zshhelpers"

export PATH=$DOTBIN:$RUSTBIN:$GOBIN:$PYENVBIN:$PATH
