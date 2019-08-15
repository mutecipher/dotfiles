#!/bin/bash
#
# ┌                                                                                                    ┐
# │                                       ░▒▓█ doтғιleѕ █▓▒░                                           │
# │                                                                                                    │
# │ You can run this script using curl:                                                                │
# │   sh -c "$(curl -sS https://raw.githubusercontent.com/cjhutchi/dotfiles/master/script/install.sh)" │
# │                                                                                                    │
# │ Alternatively, you can download the file first, then execute it locally:                           │
# │   wget https://raw.githubusercontent.com/cjhutchi/dotfiles/master/script/install.sh                │
# │   sh install.sh                                                                                    │
# │                                                                                                    │
# │ The following environment variables are available:                                                 │
# │   DOTFILES  - the path where you would like your dotfiles installed (default: $HOME/.dotfiles)     │
# │   OVERWRITE - when set to 1 will overwrite an existing install (default: 0)                        │
# └                                                                                                    ┘
#

set -e

DOTFILES=${DOTFILES:-~/.dotfiles}
OVERWRITE=${OVERWRITE:+0}

__heading() {
  echo -e "∴ ${BOLD}$1${RESET}"
}

__success_message() {
  echo -e "  ${GREEN}✓${RESET} $1"
}

__warning_message() {
  echo -e "  ${YELLOW}▲${RESET} $1"
}

__error_message() {
  echo -e "  ${RED}✗${RESET} $1"
}

command_exists() {
  command -v "$@" >/dev/null 2>&1
}

dotfiles_exists() {
  [ -e $DOTFILES ]
}

should_overwrite() {
  [ -n "$OVERWRITE" ]
}

footer() {
  echo -e "     ${GREEN}   _     _   ___ _ _"
  echo -e "      _| |___| |_|  _|_| |___ ___"
  echo -e "     | . | . |  _|  _| | | -_|_ -|"
  echo -e "     |___|___|_| |_| |_|_|___|___|${RESET}"
  echo -e "                      ...installed"
  echo
  echo -e "                    ${BLUE}macOS${RESET} ${mac_version}"
}

clone_dotfiles() {
  if ! command_exists git; then
    __error_message "${BLUE}git${RESET}  not installed..."
    exit 1
  fi

  if [ ! -e $DOTFILES ]; then
    git clone https://github.com/cjhutchi/dotfiles.git $DOTFILES 2>/dev/null && \
      __success_message "${BLUE}dotfiles${RESET} installed at ${BLUE}${DOTFILES}${RESET}" || \
      __error_message "Failed to clone ${BLUE}dotfiles${RESET} at ${BLUE}${DOTFILES}${RESET}"
  else
    if should_overwrite; then
      __warning_message "${BLUE}${DOTFILES}${RESET} already exists, backing up to ${BLUE}${DOTFILES}.old${RESET}"
      mv "${DOTFILES}" "${DOTFILES}.old"
      clone_dotfiles
    fi
  fi
}

bootstrap_dotfiles() {
  (cd $DOTFILES && script/bootstrap)
}

setup_color() {
  if [ -t 1 ]; then
    RED=$(printf '\033[31m')
    GREEN=$(printf '\033[32m')
    YELLOW=$(printf '\033[33m')
    BLUE=$(printf '\033[34m')
    BOLD=$(printf '\033[1m')
    RESET=$(printf '\033[m')
  else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    BOLD=""
    RESET=""
  fi
}

setup_env() {
  case "$(uname -s)" in
    Darwin)
      mac_version="$(sw_vers -productVersion)"
      shell="$(dscl . -read "/Users/${LOGNAME}" UserShell | awk '{print $NF}')"
      ;;
    *)
      __error_message "Unsupported platform..."
      exit 1
      ;;
  esac
}

check_if_should_run() {
  __heading "Checking for existing installation..."
  if ! dotfiles_exists; then
    __success_message "${BLUE}dotfiles${RESET} doesn't exist at ${BLUE}${DOTFILES}${RESET}"
  elif should_overwrite; then
    __warning_message "overwriting ${BLUE}dotfiles${RESET} at ${BLUE}${DOTFILES}${RESET}"
  else
    __error_message "${BLUE}dotfiles${RESET} already installed at ${BLUE}${DOTFILES}${RESET}"
    exit 1
  fi
}

main() {
  setup_color
  setup_env

  check_if_should_run

  __heading "Cloning dotfiles repo..."
  clone_dotfiles

  __heading "Bootstrapping system..."
  bootstrap_dotfiles

  __heading "Complete!"
  footer
}

main
