export ZSH=$HOME/.oh-my-zsh
ZSH_THEME="robbyrussell"
plugins=(
  colored-man-pages
  encode64
  git
  git-auto-fetch
  gpg-agent
  safe-paste
  zsh_reload
)
source $ZSH/oh-my-zsh.sh

source .zshaliases
source .zshenv
source .zshhelpers
source .zshhooks

export PATH=$DOTBIN:$RUSTBIN:$GOBIN:$PYENVBIN:$PATH
