main() {
  if which tput >/dev/null 2>&1; then
    ncolors=$(tput colors)
  fi
  if [ -t 1 ] && [ -n "$ncolors" ] && [ "$ncolors" -ge 8 ]; then
    RED="$(tput setaf 1)"
    GREEN="$(tput setaf 2)"
    YELLOW="$(tput setaf 3)"
    BLUE="$(tput setaf 4)"
    BOLD="$(tput bold)"
    NORMAL="$(tput sgr0)"
  else
    RED=""
    GREEN=""
    YELLOW=""
    BLUE=""
    BOLD=""
    NORMAL=""
  fi

  set -e

  printf "${BLUE}Cloning dotfiles...${NORMAL}\n"
  command -v git >/dev/null 2>&1 || {
    echo "Error: git is not installed"
    exit 1
  }
  if [ "$OSTYPE" = cygwin ]; then
    if git --version | grep msysgit > /dev/null; then
      echo "Error: Windows/MSYS Git is not supported on Cygwin"
      echo "Error: Make sure the Cygwin git package is installed and is first on the path"
      exit 1
    fi
  fi
  env git clone https://github.com/cjhutchi/dotfiles.git ~/.dotfiles || {
    printf "Error: git clone of dotfiles repo failed\n"
    exit 1
  }

  printf "${BLUE}Bootstrapping your system...${NORMAL}\n"
  # TODO: Run the bootstrap script to symlink all the appropriate dotfiles

  printf "${GREEN}"
  echo " _       _ _                _   "
  echo "| |_ ___| | |   _ _ ___ ___| |_ "
  echo "|   | -_| | |  | | | -_| .'|   |"
  echo "|_|_|___|_|_|  |_  |___|__,|_|_|"
  echo "               |___|            "
  echo " _           _   _              "
  echo "| |_ ___ ___| |_| |_ ___ ___    "
  echo "| . |  _| . |  _|   | -_|  _|   "
  echo "|___|_| |___|_| |_|_|___|_|     "
  printf "${NORMAL}"
  echo "                           ....you're good to go"
  echo ""
}

main
