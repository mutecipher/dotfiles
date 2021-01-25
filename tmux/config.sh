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

__info "running tmux/config.sh"

if test "$PLATFORM" == "osx"; then
  result=$(/usr/local/bin/brew --prefix tmux)
  if test -e "$result" ; then
    __success_message "[SKIPPING] tmux installed"
  else
    __warning_message "installing tmux..."
    brew install tmux
  fi
elif test "$PLATFORM" == "linux"; then
  result=$(/usr/bin/tmux)
  if test -e "$result" ; then
    __success_message "[SKIPPING] tmux installed"
  else
    __warning_message "installing tmux..."
    sudo apt install -y tmux > /dev/null
  fi
fi

if [ -d "$HOME/.tmux/plugins" ] ; then
  __success_message "[SKIPPING] tmux plugins installed"
else
  __warning_message "installing tmux plugins..."
  mkdir -p ~/.tmux/plugins
  git clone https://github.com/tmux-plugins/tpm ~/.tmux/plugins/tpm
fi
