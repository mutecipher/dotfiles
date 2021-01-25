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

__info "running zsh/config.sh"

if test -e "$(which zsh)" ; then
  __success_message "[SKIPPING] zsh installed"
else
  if test "$platform" == "Darwin" ; then
    __warning_message "installing zsh..."
    brew install zsh
  elif test "$platform" == "Linux" ; then
    __warning_message "installing zsh..."
    sudo apt install zsh > /dev/null
  fi
fi

if [[ "$SHELL" =~ /*zsh*/ ]]; then
  __warning_message "changing default shell to zsh"
  sudo chsh -s /bin/zsh
else
  __success_message "[SKIPPING] zsh default shell"
fi

if ! test -e $HOME/.oh-my-zsh; then
  __warning_message "installing oh-my-zsh..."
  sh -c "$(curl -fsSL https://raw.github.com/ohmyzsh/ohmyzsh/master/tools/install.sh)"
fi

if test -e /usr/local/bin/starship ; then
  __success_message "[SKIPPING] starship installed"
else
  __warning_message "installing starship..."
  curl -fsSL https://starship.rs/install.sh | bash
fi
