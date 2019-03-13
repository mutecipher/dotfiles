#!/bin/bash

set -e

if test "$SHELL" != "/bin/zsh"; then
  echo "changing default shell to zsh"
  chsh -s /bin/zsh
fi

if ! test -e $HOME/.oh-my-zsh; then
  echo "installing oh-my-zsh"
  curl -fsSLo ~/omz-install.sh \
    https://raw.github.com/robbyrussell/oh-my-zsh/master/tools/install.sh

  ~/omz-install.sh
fi
