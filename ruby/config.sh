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

__info "running ruby/config.sh"

if test "$platform" == "Darwin"; then
  __warning_message "TODO: automate Ruby setup for macOS"
elif test "$platform" == "Linux"; then
  __warning_message "TODO: automate Ruby setup for Linux"
fi

