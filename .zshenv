source "$HOME/.cargo/env"
case "$(uname -s | tr '[:upper:]' '[:lower:]')" in
  "darwin" )
    [ -s "$(brew --prefix)/opt/chruby/share/chruby/chruby.sh" ] && source "$(brew --prefix)/opt/chruby/share/chruby/chruby.sh"
    [ -s "$(brew --prefix)/opt/chruby/share/chruby/auto.sh" ]   && source "$(brew --prefix)/opt/chruby/share/chruby/auto.sh"
    [ -s "$(brew --prefix)/opt/nvm/nvm.sh" ]                    && source "$(brew --prefix)/opt/nvm/nvm.sh"
    ;;
  "linux" )
    [ -s "/usr/local/share/chruby/chruby.sh" ] && source "/usr/local/share/chruby/chruby.sh"
    [ -s "/usr/local/share/chruby/auto.sh" ] && source "/usr/local/share/chruby/auto.sh"
    [ -s "$HOME/.nvm/nvm.sh" ] && source "$HOME/.nvm/nvm.sh"
    ;;
esac

[ -e "$(which shadowenv)" ] && eval "$(shadowenv init zsh)"
[ -e "$(which starship)" ]  && eval "$(starship init zsh)"
[ -e "$(which gh)" ] && eval "$(gh completion -s zsh)"
[ -e "$(which pyenv)" ] && eval "$(pyenv init - zsh)"

export DOTNET_CLI_TELEMETRY_OPTOUT=true
export DOTBIN="$HOME/.bin"
export EDITOR=nvim
export GOPATH="$HOME/.go"
export GOBIN="$GOPATH/bin"
export GOPROXY="direct"
export NVM_DIR="$HOME/.nvm"
export RUSTBIN="$HOME/.cargo/bin"
export PYENV_ROOT="$HOME/.pyenv"
export PYENVBIN="$PYENV_ROOT/bin"
export ZSH_DOTENV_PROMPT=false

