#!/usr/bin/env bash
set -e

DOTFILES=(
  .gemrc
  .gitconfig
  .gitignore
  .irbrc
  .my.cnf
  .pryrc
  .rspec
  .tmux.conf
  .zshaliases
  .zshenv
  .zshhelpers
  .zshrc
)

DIRS=(
  .bin
)

CONFIG_FILES=(
  starship.toml
)

CONFIG_DIRS=(
  nvim
)

platform="$(uname -s | tr '[:upper:]' '[:lower:]')"
dotfiles_root="$(pwd)"

case "${platform}" in
  "darwin" )
    echo "🥾 Bootstrapping macOS..."
    # scripts/install-macos.sh
    ;;
  "linux" )
    echo "🥾 Bootstrapping Linux..."
    # scripts/install-linux.sh
    ;;
  * )
    echo "not macOS" ;;
esac

function backup() {
  mv "$1" "$1.backup"
}

for x in "${DOTFILES[@]}"; do
  pushd "$HOME"
  if [[ -f "$x" ]]; then
    echo "⚠️  $HOME/$x exists..."

    echo "Backing up $HOME/$x..."
    backup "$x"

    printf "🔗 Linking $x to $HOME/$x"
    ln -s "$dotfiles_root/$x" "$x"
  else
    printf "🔗 Linking $x to $HOME/$x"
    ln -s "$dotfiles_root/$x" "$x"
  fi
  popd
done

for x in "${DIRS[@]}"; do
  pushd "$HOME"
  if [[ -d "$x" ]]; then
    echo "⚠️  $HOME/$x exists..."

    echo "Backing up $HOME/$x..."
    backup "$x"

    echo "🔗 Linking $x to $HOME/$x"
    ln -s "$dotfiles_root/$x" "$x"
  else
    echo "🔗 Linking $x to $HOME/$x"
    ln -s "$dotfiles_root/$x" "$x"
  fi
done

for x in "${CONFIG_FILES[@]}"; do
  pushd "$HOME/.config"
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
done
