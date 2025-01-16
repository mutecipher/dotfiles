#!/usr/bin/env bash
#
# Bash library for datetime helpers.

##############################
# Returns the date in +%Y-%m-%d format.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes datetime in YYYY-MM-DD format to stdout.
##############################
datetime::date() {
  date +%Y-%m-%d
}

##############################
# Returns the time in +%H:%M:%S%z format.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes datetime in HH:MM:SS-ZZZZ format to stdout.
##############################
datetime::time() {
  date +%H:%M:%S%z
}

##############################
# Returns the date in ISO 8601 format.
# Globals:
#   None
# Arguments:
#   None
# Outputs:
#   Writes datetime in ISO8601 format to stdout.
##############################
datetime::iso8601() {
  echo "$(datetime::date)T$(datetime::time)"
}
