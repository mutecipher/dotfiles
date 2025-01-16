#!/usr/bin/env bash
#
# Bash library for color helpers.

color::supported() {
  if [[ $- == *i* ]]; then
    return 1
  else
    local num_colors
    num_colors=$(tput colors)
    if ((num_colors > 8)); then
      return 0
    fi
  fi
}

color::for() {
  case $1 in
  black) echo 0 ;;
  red) echo 1 ;;
  green) echo 2 ;;
  yellow) echo 3 ;;
  blue) echo 4 ;;
  magenta) echo 5 ;;
  cyan) echo 6 ;;
  white) echo 7 ;;
  reset) echo 888 ;;
  *) echo 9 ;;
  esac
}
