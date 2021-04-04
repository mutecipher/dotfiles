source "$HOME/.cargo/env"
[ -s "$(brew --prefix)/opt/chruby/share/chruby/chruby.sh" ] && source "$(brew --prefix)/opt/chruby/share/chruby/chruby.sh"
[ -s "$(brew --prefix)/opt/chruby/share/chruby/auto.sh" ]   && source "$(brew --prefix)/opt/chruby/share/chruby/auto.sh"
[ -s "$(brew --prefix)/opt/nvm/nvm.sh" ]                    && source "$(brew --prefix)/opt/nvm/nvm.sh"

[ -e "$(which shadowenv)" ] && eval "$(shadowenv init zsh)"
[ -e "$(which starship)" ]  && eval "$(starship init zsh)"
[ -e "$(which gh)" ] && eval "$(gh completion -s zsh)"
[ -e "$(which pyenv)" ] && eval "$(pyenv init - zsh)"

export DOTNET_CLI_TELEMETRY_OPTOUT=true
export DOTBIN=$HOME/.bin
export EDITOR=nvim
export GOPATH=$HOME/.go
export GOBIN=$GOPATH/bin
export GOPROXY="direct"
export NVM_DIR="$HOME/.nvm"
export RUSTBIN=$HOME/.cargo/bin
export PYENV_ROOT="$HOME/.pyenv"
export PYENVBIN="$PYENV_ROOT/bin"
export ZSH_DOTENV_PROMPT=false

