#!/usr/bin/env bash
#
# Bash library for file system helpers.

##############################
# Returns the filename of the calling file.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes the filename of the calling file to stdout.
##############################
fs::current_file() {
  local current_file
  current_file=$(readlink -f "${0}")
  echo "${current_file##*/}"
}
