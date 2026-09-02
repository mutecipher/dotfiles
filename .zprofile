# Create Developer directory if it doesn't exist
if [ ! -d "$HOME/Developer" ]; then
  mkdir "$HOME/Developer"
fi

# Homebrew initialization — probe the canonical install paths across macOS and Linux
for brew_path in \
  /opt/homebrew/bin/brew \
  /usr/local/bin/brew \
  /home/linuxbrew/.linuxbrew/bin/brew \
  "$HOME/.linuxbrew/bin/brew"; do
  if [ -x "$brew_path" ]; then
    eval "$("$brew_path" shellenv)"
    break
  fi
done
unset brew_path

# nvm initialization — prefer Homebrew's copy when present, else the standard installer layout
if [ -n "${HOMEBREW_PREFIX:-}" ] && [ -s "$HOMEBREW_PREFIX/opt/nvm/nvm.sh" ]; then
  source "$HOMEBREW_PREFIX/opt/nvm/nvm.sh"
  [ -s "$HOMEBREW_PREFIX/opt/nvm/etc/bash_completion.d/nvm" ] && source "$HOMEBREW_PREFIX/opt/nvm/etc/bash_completion.d/nvm"
elif [ -s "${NVM_DIR:-$HOME/.nvm}/nvm.sh" ]; then
  export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"
  source "$NVM_DIR/nvm.sh"
  [ -s "$NVM_DIR/bash_completion" ] && source "$NVM_DIR/bash_completion"
fi

# pyenv initialization — prefer Homebrew's copy when present, else the standalone installer layout
if ! command -v pyenv >/dev/null 2>&1 && [ -x "${PYENV_ROOT:-$HOME/.pyenv}/bin/pyenv" ]; then
  export PYENV_ROOT="${PYENV_ROOT:-$HOME/.pyenv}"
  export PATH="$PYENV_ROOT/bin:$PATH"
fi
if command -v pyenv >/dev/null 2>&1; then
  eval "$(pyenv init - zsh)"
  command -v pyenv-virtualenv-init >/dev/null 2>&1 && eval "$(pyenv virtualenv-init - zsh)"
fi

# rbenv initialization
eval "$(rbenv init - --no-rehash zsh)"
