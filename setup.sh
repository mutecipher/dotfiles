#!/bin/sh
# setup.sh — create symlinks for all dotfiles
#
# Usage:
#   sh ~/.dotfiles/setup.sh
#
# Safe to re-run. Existing files are backed up with a .bak suffix before
# being replaced. Already-correct symlinks are skipped without touching them.

set -e

DOTFILES="${DOTFILES:-$HOME/.dotfiles}"

# ── helpers ───────────────────────────────────────────────────────────────────

info()  { printf '\033[0;34m=>\033[0m %s\n' "$*"; }
ok()    { printf '  \033[0;32mlinked\033[0m  %s\n' "$*"; }
skip()  { printf '  \033[0;90mskipped\033[0m %s\n' "$*"; }
backup(){ printf '  \033[0;33mbacked up\033[0m %s -> %s\n' "$1" "$2"; }
warn()  { printf '  \033[0;33mwarn\033[0m    %s\n' "$*" >&2; }

# link <repo-relative-path> <home-relative-destination>
#
# Examples:
#   link .zshrc .zshrc                        ~/.zshrc -> ~/.dotfiles/.zshrc
#   link config/nvim .config/nvim             ~/.config/nvim -> ~/.dotfiles/config/nvim
link() {
  src="$DOTFILES/$1"
  dst="$HOME/$2"

  if [ ! -e "$src" ]; then
    warn "source not found, skipping: $1"
    return
  fi

  # Already pointing at the right place — nothing to do
  if [ -L "$dst" ] && [ "$(readlink "$dst")" = "$src" ]; then
    skip "$2"
    return
  fi

  # Back up any real file or directory that would be overwritten
  if [ -e "$dst" ] && [ ! -L "$dst" ]; then
    mv "$dst" "${dst}.bak"
    backup "$2" "$2.bak"
  fi

  # Remove a stale symlink pointing elsewhere
  [ -L "$dst" ] && rm "$dst"

  mkdir -p "$(dirname "$dst")"
  ln -s "$src" "$dst"
  ok "$2"
}

# ── symlinks ──────────────────────────────────────────────────────────────────

info "Shell"
link .zshrc    .zshrc
link .zprofile .zprofile

info "Git"
link .gitconfig .gitconfig

info "Editors"
link config/nvim  .config/nvim
link config/emacs .config/emacs

info "Terminals"
link config/ghostty .config/ghostty

info "Other"
link config/starship.toml .config/starship.toml

info "Done."
