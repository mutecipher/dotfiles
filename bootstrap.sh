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
  .zshhooks
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

for x in "${DOTFILES[@]}"; do
  if [[ -f "$HOME/$x" ]]; then
    echo "⚠️  $HOME/$x exists..."
  else
    printf "🔗 Linking $x to $HOME/$x"
    # do something
    printf " ✅"
    echo
  fi
done

for x in "${DIRS[@]}"; do
  if [[ -d "$HOME/$x" ]]; then
    echo "⚠️  $HOME/$x exists..."
  else
    echo "🔗 Linking $x to $HOME/$x"
  fi
done

for x in "${CONFIG_FILES[@]}"; do
  if [[ -f "$HOME/.config/$x" ]]; then
    echo "⚠️  $HOME/.config/$x exists..."
  else
    echo "🔗 Linking $x to $HOME/.config/$x"
  fi
done

for x in "${CONFIG_DIRS[@]}"; do
  if [[ -d "$HOME/.config/$x" ]]; then
    echo "⚠️  $HOME/.config/$x exists..."
  else
    echo "🔗 Linking $x to $HOME/.config/$x"
  fi
done
