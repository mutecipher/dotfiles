#!/bin/bash
set -e

if test $PLATFORM == "osx"; then
  result=`/usr/local/bin/brew --prefix tmux`
  if test -e "$result" ; then
    echo "tmux installed"
  else
    echo "install tmux with brew"
    brew install tmux

    echo "install tmux plugins"
    git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
  fi
elif test "$PLATFORM" == "linux"; then
  exit 1;
else
  exit 1;
fi

