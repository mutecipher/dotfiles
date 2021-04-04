#!/usr/bin/env bash
set -e

echo "running install-linux.sh"

# Install oh-my-zsh
sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

# Install Homebrew
bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"

# Bootstrap with Brewfile
brew bundle --file "$HOME/.dotfiles/Brewfile"

# Make dev directories
mkdir -p "$HOME/src/github.com/mutecipher"

# Install Rust 🦀
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Install latest Node.js 
nvm install --lts

# Install Ruby 2.7.2
ruby-install 2.7.2
