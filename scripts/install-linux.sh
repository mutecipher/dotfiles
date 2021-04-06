#!/usr/bin/env bash
set -e

echo "running install-linux.sh"

# Install default applications
apps=(neovim tmux go zsh)
sudo apt update
sudo apt upgrade -y
sudo apt install "$apps"

# Install oh-my-zsh
# sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended

# Make dev directories
mkdir -p "$HOME/src/github.com/mutecipher"

# Install chruby
wget -O "$HOME/chruby-0.3.9.tar.gz" https://github.com/postmodern/chruby/archive/v0.3.9.tar.gz
tar -xzvf "$HOME/chruby-0.3.9.tar.gz" -C "$HOME"
cd "$HOME/chruby-0.3.9"
sudo make install

# Install ruby-install
wget -O "$HOME/ruby-install-0.8.1.tar.gz" https://github.com/postmodern/ruby-install/archive/v0.8.1.tar.gz
tar -xzvf "$HOME/ruby-install-0.8.1.tar.gz" -C "$HOME"
cd "$HOME/ruby-install-0.8.1"
sudo make install

# Install pyenv
curl https://pyenv.run | bash

# Install nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.38.0/install.sh | bash

# Install Rust 🦀
curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh

# Install Ruby 2.7.2
ruby-install 2.7.2

# Install Node.js
# nvm install --lts
