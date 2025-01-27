# Create Developer directory if it doesn't exist
if [ ! -d "$HOME/Developer" ]; then
  mkdir "$HOME/Developer"
fi

# macOS specific configs
if [[ "$(uname -s)" == "Darwin" ]]; then
  # homebrew initialization
  if [[ "$(uname -m)" == "arm64" ]]; then # Apple Silicon
    eval "$(/opt/homebrew/bin/brew shellenv)"
  else                                    # Intel
    eval "$(/usr/local/bin/brew shellenv)"
  fi

  # nvm initialization
  [ -s "$(brew --prefix nvm)/nvm.sh" ] && source "$(brew --prefix nvm)/nvm.sh"
  [ -s "$(brew --prefix nvm)/etc/bash_completion.d/nvm" ] && source "$(brew --prefix nvm)/etc/bash_completion.d/nvm"
fi

# pyenv initialization
eval "$(pyenv init -)"

# rbenv initialization
eval "$(rbenv init - zsh)"

# cargo initialization
[ -s "${HOME}/.cargo/env" ] && source "$HOME/.cargo/env"
