#!/usr/bin/env bash
set -e

echo "[!] running scripts/install-linux.sh"

# Install default applications
apps=(neovim tmux zsh build-essential)
sudo apt update
sudo apt upgrade -y
sudo apt install -y "${apps[@]}"

# Install oh-my-zsh
[ ! -d $HOME/.oh-my-zsh ] && git clone https://github.com/ohmyzsh/ohmyzsh.git $HOME/.oh-my-zsh

# Install tpm
[! -d $HOME/.tmux/plugins/tpm ] && git clone https://github.com/tmux-plugins/tpm $HOME/.tmux/plugins/tpm

# Install chruby
wget -O "$HOME/chruby-0.3.9.tar.gz" https://github.com/postmodern/chruby/archive/v0.3.9.tar.gz
tar -xzvf "$HOME/chruby-0.3.9.tar.gz" -C "$HOME"
cd "$HOME/chruby-0.3.9"
sudo make install
rm -rf $HOME/chruby-0.3.9*

# Install ruby-install
wget -O "$HOME/ruby-install-0.8.1.tar.gz" https://github.com/postmodern/ruby-install/archive/v0.8.1.tar.gz
tar -xzvf "$HOME/ruby-install-0.8.1.tar.gz" -C "$HOME"
cd "$HOME/ruby-install-0.8.1"
sudo make install
rm -rf $HOME/ruby-install-0.8.1*

# Install pyenv
[ ! -d $HOME/.pyenv ] && git clone https://github.com/pyenv/pyenv.git $HOME/.pyenv

# Install nvm
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.38.0/install.sh | bash

# Install Rust 🦀
curl https://sh.rustup.rs -sSf | sh -s -- -y