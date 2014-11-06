#!/bin/bash

DIR=`pwd`

echo "→ Current directory is \"$DIR\""

cd ~
echo "→ Moving to home directory"
echo

if [ -f ./.bashrc ]; then
  printf "→ bashrc already present\n"
  printf "delete (y/n)? "
  read X

  if [ "$X" = "y" ]; then
    echo "  deleting.."
    rm ./.bashrc
  elif [ "$X" = "n" ]; then
    echo "  skipping.."
  fi
  ln -s $DIR/bash/bashrc ./.bashrc
fi

echo

if [ -f ./.bash_profile ]; then
  printf "→ bash_profile already present\n"
  printf "delete (y/n)? "
  read X

  if [ "$X" = "y" ]; then
    echo "  deleting.."
    rm ./.bash_profile
  elif [ "$X" = "n" ]; then
    echo "  skipping.."
  fi
  ln -s $DIR/bash/bash_profile ./.bash_profile
fi

echo

if [ -f ./.bash_aliases ]; then
  printf "→ bash_aliases already present\n"
  printf "delete (y/n)? "
  read X

  if [ "$X" = "y" ]; then
    echo "  deleting.."
    rm ./.bash_aliases
  elif [ "$X" = "n" ]; then
    echo "  skipping.."
  fi
  ln -s $DIR/bash/bash_aliases ./.bash_aliases
fi

echo

if [ -f ./.vimrc ]; then
  printf "→ vimrc already present\n"
  printf "delete (y/n)? "
  read X

  if [ "$X" = "y" ]; then
    echo "  deleting.."
    rm ./.vimrc
  elif [ "$X" = "n" ]; then
    echo "  skipping.."
  fi
  ln -s $DIR/vim/vimrc ./.vimrc
fi
