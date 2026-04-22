#!/usr/bin/env bash
#
# Bash library for color helpers.

color::supported() {
  if [[ -z ${_COLOR_SUPPORTED_CACHE+x} ]]; then
    local num_colors
    _COLOR_SUPPORTED_CACHE=1
    if [ -t 1 ] && num_colors=$(tput colors 2>/dev/null) && ((num_colors > 8)); then
      _COLOR_SUPPORTED_CACHE=0
    fi
  fi
  return $_COLOR_SUPPORTED_CACHE
}
