#!/usr/bin/env bash
set -e

echo "[!] running scripts/install-macos.sh"

# Install oh-my-zsh
[ ! -d $HOME/.oh-my-zsh ] && git clone https://github.com/ohmyzsh/ohmyzsh.git $HOME/.oh-my-zsh

# Install Homebrew
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Bootstrap with Brewfile
brew bundle --file Brewfile

# Install Rust 🦀
curl https://sh.rustup.rs -sSf | sh -s -- -y

source $HOME/.zshrc