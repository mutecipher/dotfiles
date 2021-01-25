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

__info "running starship/config.sh"

if test -e /usr/local/bin/starship ; then
  __success_message "[SKIPPING] starship installed"
else
  if [[ "$(uname -m)" =~ /*arm*/ ]] ; then
    __error_message "starship not supported ARM processors"
  else
    __warning_message "installing starship..."
    curl -fsSL https://starship.rs/install.sh | bash
  fi
fi
