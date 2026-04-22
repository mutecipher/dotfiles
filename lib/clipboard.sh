#!/usr/bin/env bash
#
# Bash library for clipboard helpers.

##############################
# Copies stdin to the system clipboard.
# Tries pbcopy (macOS), wl-copy (Wayland), xclip (X11), xsel (X11),
# in that order.
# Arguments:
#   None (reads from stdin).
# Returns:
#   0 on success, 1 if no clipboard command is available.
##############################
clipboard::copy() {
  if command -v pbcopy >/dev/null 2>&1; then
    pbcopy
  elif [ -n "${WAYLAND_DISPLAY:-}" ] && command -v wl-copy >/dev/null 2>&1; then
    wl-copy
  elif command -v xclip >/dev/null 2>&1; then
    xclip -selection clipboard
  elif command -v xsel >/dev/null 2>&1; then
    xsel --clipboard --input
  else
    echo "No clipboard command found (install pbcopy, wl-copy, xclip, or xsel)." >&2
    return 1
  fi
}
