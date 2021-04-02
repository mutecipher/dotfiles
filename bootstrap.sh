#!/usr/bin/env bash
set -e

FILES=(
  .gemrc
  .gitconfig
  .gitignore
  .irbrc
  .my.conf
  .pryrc
  .rspec
  .tmux.conf
  .zshaliases
  .zshenv
  .zshhelpers
  .zshhooks
  .zshrc
  .bin
)

for file in "${FILES[@]}"; do
  echo "$file"
done
