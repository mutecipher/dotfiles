#!/bin/bash

if test "$PLATFORM" = "osx"; then
  result=`/usr/local/bin/brew --prefix neovim`
  if test -e "$result" ; then
    echo "neovim already installed"
  else
    echo "install neovim with brew"
    brew install neovim

    echo "install vim plugins"
    curl -fLo ~/.config/nvim/autoload/plug.vim --create-dirs \
      https://raw.githubusercontent.com/junegunn/vim-plug/master/plug.vim

    nvim +PluginInstall +qall
  fi
elif test "$PLATFORM" = "linux"; then
  exit 1;
else
  exit 1;
fi

exit 0;
