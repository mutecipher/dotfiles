#!/usr/bin/env bash
#
# Bash library for logging helpers.

. color.sh
. date-time.sh
. fs.sh

##############################
# Logs an informal message with a timestamp and the current file.
# name.
# Globals:
#   None
# Arguments:
#   None
# Output:
#   Writes a message to stdout.
##############################
logger::info() {
  if color::supported; then
    printf "\033[1;34m%-7s\033[0m $(datetime::iso8601) \033[1m%-6s\033[0m %s\n" \
      "info" \
      "$(fs::current_file)" \
      "$*"
  else
    printf "%-7s $(datetime::iso8601) %-6s %s\n" \
      "info" \
      "$(fs::current_file)" \
      "$*"
  fi
}

##############################
# Logs an informal message with a timestamp and the current file.
# name.
# Globals:
#   None
# Arguments:
#   None
# Output:
#   Writes a message to stdout.
##############################
logger::warn() {
  if color::supported; then
    printf "\033[1;33m%-7s\033[0m $(datetime::iso8601) \033[1m%-6s\033[0m %s\n" \
      "warning" \
      "$(fs::current_file)" \
      "$*"
  else
    printf "%-7s $(datetime::iso8601) %-6s %s\n" \
      "warning" \
      "$(fs::current_file)" \
      "$*"
  fi
}

##############################
# Logs an error message with a timestamp and the current file
# name.
# Globals:
#   None
# Arguments:
#   None
# Output:
#   Writes a message to stderr.
##############################
logger::error() {
  if color::supported; then
    printf "\033[1;31m%-7s\033[0m $(datetime::iso8601) \033[1m%-6s\033[0m %s\n" \
      "error" \
      "$(fs::current_file)" \
      "$*" \
      >&2
  else
    printf "%-7s $(datetime::iso8601) %-6s %s\n" \
      "error" \
      "$(fs::current_file)" \
      "$*" \
      >&2
  fi

}
