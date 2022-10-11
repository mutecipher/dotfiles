#!/usr/bin/env bash
set -e

DOTFILES=(
  gemrc
  gitconfig
  gitignore
  gitmessage
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
  helix
)

TMUX_DIRS=(
  colors
)

dotfiles_root="$(pwd)"

function backup() {
  mv "$1" "$1.backup"
}

for x in "${DOTFILES[@]}"; do
  cd "$HOME"
  if [[ -f ".$x" ]]; then
    echo "⚠️  $HOME/.$x exists..."

    echo "Backing up $HOME/.$x..."
    backup ".$x"

    echo "🔗 Linking $x to $HOME/.$x"
    ln -sf "$dotfiles_root/$x" ".$x"
  else
    echo "🔗 Linking $x to $HOME/.$x"
    ln -sf "$dotfiles_root/$x" ".$x"
  fi
  cd $dotfiles_root
  echo
done

for x in "${DIRS[@]}"; do
  cd "$HOME"
  if [[ -d ".$x" ]]; then
    echo "⚠️  $HOME/.$x exists..."

    echo "Backing up $HOME/.$x..."
    backup ".$x"

    echo "🔗 Linking $x to $HOME/.$x"
    ln -sfn "$dotfiles_root/$x" ".$x"
  else
    echo "🔗 Linking $x to $HOME/.$x"
    ln -sfn "$dotfiles_root/$x" ".$x"
  fi
  cd $dotfiles_root
  echo
done

for x in "${CONFIG_FILES[@]}"; do
  cd "$HOME/.config"
  if [[ -f "$x" ]]; then
    echo "⚠️  $HOME/.config/$x exists..."

    echo "Backing up $HOME/.config/$x..."
    backup "$x"

    echo "🔗 Linking $x to $HOME/.config/$x"
    ln -sf "$dotfiles_root/config/$x" "$x"
  else
    echo "🔗 Linking $x to $HOME/.config/$x"
    ln -sf "$dotfiles_root/config/$x" "$x"
  fi
  cd $dotfiles_root
  echo
done

for x in "${CONFIG_DIRS[@]}"; do
  cd "$HOME/.config"
  if [[ -d "$x" ]]; then
    echo "⚠️  $HOME/.config/$x exists..."

    echo "Backing up $HOME/.config/$x..."
    backup "$x"

    echo "🔗 Linking $x to $HOME/.config/$x"
    ln -sfn "$dotfiles_root/config/$x" "$x"
  else
    echo "🔗 Linking $x to $HOME/.config/$x"
    ln -sfn "$dotfiles_root/config/$x" "$x"
  fi
  cd $dotfiles_root
  echo
done

for x in "${TMUX_DIRS[@]}"; do
  mkdir -p "$HOME/.tmux"
  cd "$HOME/.tmux"
  if [[ -d "$x" ]]; then
    echo "⚠️  $HOME/.tmux/$x exists..."

    echo "Backing up $HOME/.tmux/$x..."
    backup "$x"

    echo "🔗 Linking $x to $HOME/.tmux/$x"
    ln -sfn "$dotfiles_root/tmux/$x" "$x"
  else
    echo "🔗 Linking $x to $HOME/.tmux/$x"
    ln -sfn "$dotfiles_root/tmux/$x" "$x"
  fi
  cd $dotfiles_root
  echo
done
