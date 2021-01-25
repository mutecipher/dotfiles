#!/usr/bin/env bash
#
# Author: Cory Hutchison
#

set -e

# Include helper methods
DIR="${BASH_SOURCE%/*}"
if [ ! -d "$DIR" ] ; then DIR="$PWD" ; fi
# shellcheck source=../script/misc
. "script/misc"

__info "running nvim/config.sh"

if test "$platform" == "Darwin"; then
  result=$(/usr/local/bin/brew --prefix neovim)
  if test -e "$result" ; then
    __success_message "[SKIPPING] neovim installed"
  else
    __warning_message "installing neovim..."
    brew install neovim
  fi
elif test "$platform" == "Linux"; then
  if test -e "$(which nvim)" ; then
    __success_message "[SKIPPING] neovim installed"
  else
    __warning_message "installing neovim..."
    sudo apt install -y neovim > /dev/null
  fi
fi

if test -d "$HOME/.config/nvim/plugged" ; then
  __success_message "[SKIPPING] vim plugins installed"
else
  __warning_message "installing vim plugins..."
  curl -s "$HOME/.config/nvim/autoload/plug.vim" --create-dirs \
    "https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim" > /dev/null

  nvim +PluginInstall +qall > /dev/null
fi
