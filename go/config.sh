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

__info "running go/config.sh"

if test "$platform" == "Darwin" ; then
  result=$(/usr/local/bin/brew --prefix go)
  if test -e "$result" ; then
    __success_message "[SKIPPING] go installed"
  else
    __warning_message "installing go..."
    brew install neovim
  fi
elif test "$platform" == "Linux" ; then
  if test -e "$(which go)" ; then
    __success_message "[SKIPPING] go installed"
  else
    __warning_message "installing go..."
    sudo apt install -y golang > /dev/null
  fi
fi
