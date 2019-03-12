#!/bin/bash

if test $PLATFORM == "osx"; then
  result=`/usr/local/bin/brew --prefix chruby`
  if test -e "$result"; then
    echo "chruby installed"
  else
    echo "installing chruby"
    brew install chruby
  fi
  source "$(brew --prefix chruby)/share/chruby/chruby.sh"
  chruby_reset

  exit 0;
elif test "$PLATFORM" == "linux"; then
  exit 1;
else
  exit 1;
fi

