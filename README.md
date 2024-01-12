# dotfiles

Config files that I use for my systems.

## Prerequisites

- [oh-my-zsh](https://ohmyz.sh)
- [Homebrew](https://brew.sh)

## Setup

```shell
# I typically run this from the $HOME directory
git clone https://github.com/cjhutchi/dotfiles $HOME/.dotfiles
ln -s $HOME/.dotfiles/.gitconfig $HOME/.gitconfig
ln -s $HOME/.dotfiles/.zshrc $HOME/.zshrc
ln -s $HOME/.dotfiles/.zprofile HOME/.zprofile
ln -s $HOME/.dotfiles/config/nvim $HOME/.config/nvim
ln -s $HOME/.dotfiles/config/helix $HOME/.config/helix
ln -s $HOME/.dotfiles/config/kitty $HOME/.config/kitty
```
