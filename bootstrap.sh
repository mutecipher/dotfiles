#!/usr/bin/env bash
set -e

DOTFILES=(
  gemrc
  gitconfig
  gitignore
  irbrc
  my.cnf
  pryrc
  rspec
  tmux.conf
  zshrc
)

DIRS=(
  bin
)

CONFIG_FILES=(
  starship.toml
)

CONFIG_DIRS=(
  nvim
)

dotfiles_root="$(pwd)"

function backup() {
  mv "$1" "$1.backup"
}

for x in "${DOTFILES[@]}"; do
  pushd "$HOME" >/dev/null
  if [[ -f ".$x" ]]; then
    echo "⚠️  $HOME/.$x exists..."

    echo "Backing up $HOME/.$x..."
    backup ".$x"

    echo "🔗 Linking $x to $HOME/.$x"
    ln -s "$dotfiles_root/$x" ".$x"
  else
    echo "🔗 Linking $x to $HOME/.$x"
    ln -s "$dotfiles_root/$x" ".$x"
  fi
  popd >/dev/null
  echo
done

for x in "${DIRS[@]}"; do
  pushd "$HOME" >/dev/null
  if [[ -d ".$x" ]]; then
    echo "⚠️  $HOME/.$x exists..."

    echo "Backing up $HOME/.$x..."
    backup ".$x"

    echo "🔗 Linking $x to $HOME/.$x"
    ln -s "$dotfiles_root/$x" ".$x"
  else
    echo "🔗 Linking $x to $HOME/.$x"
    ln -s "$dotfiles_root/$x" ".$x"
  fi
  echo
  popd >/dev/null
done

for x in "${CONFIG_FILES[@]}"; do
  pushd "$HOME/.config" >/dev/null
  if [[ -f "$x" ]]; then
    echo "⚠️  $HOME/.config/$x exists..."

    echo "Backing up $HOME/.config/$x..."
    backup "$x"

    echo "🔗 Linking $x to $HOME/.config/$x"
    ln -s "$dotfiles_root/config/$x" "$x"
  else
    echo "🔗 Linking $x to $HOME/.config/$x"
    ln -s "$dotfiles_root/config/$x" "$x"
  fi
  echo
  popd >/dev/null
done

for x in "${CONFIG_DIRS[@]}"; do
  pushd "$HOME/.config"
  if [[ -d "$x" ]]; then
    echo "⚠️  $HOME/.config/$x exists..."

    echo "Backing up $HOME/.config/$x..."
    backup "$x"

    echo "🔗 Linking $x to $HOME/.config/$x"
    ln -s "$dotfiles_root/config/$x" "$x"
  else
    echo "🔗 Linking $x to $HOME/.config/$x"
    ln -s "$dotfiles_root/config/$x" "$x"
  fi
  echo
  popd >/dev/null
done

source "$HOME/.zshrc"
