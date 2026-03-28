#!/bin/sh
# install.sh — bootstrap dotfiles on a new machine
#
# Usage:
#   curl -fsSL https://raw.githubusercontent.com/mutecipher/dotfiles/main/install.sh | sh
#
# What it does:
#   1. Checks that git is available
#   2. Clones (or updates) the repo to ~/.dotfiles
#   3. Runs setup.sh to create all symlinks

set -e

DOTFILES="${DOTFILES:-$HOME/.dotfiles}"
REPO="https://github.com/mutecipher/dotfiles.git"

# ── helpers ───────────────────────────────────────────────────────────────────

info() { printf '\033[0;34m=>\033[0m %s\n' "$*"; }
die()  { printf '\033[0;31mError:\033[0m %s\n' "$*" >&2; exit 1; }

# ── preflight ─────────────────────────────────────────────────────────────────

command -v git > /dev/null 2>&1 || die "git is required but not installed."

# ── clone or update ───────────────────────────────────────────────────────────

if [ -d "$DOTFILES/.git" ]; then
  info "Dotfiles already present at $DOTFILES, pulling latest..."
  git -C "$DOTFILES" pull --ff-only
else
  info "Cloning dotfiles to $DOTFILES..."
  git clone "$REPO" "$DOTFILES"
fi

# ── run setup ─────────────────────────────────────────────────────────────────

sh "$DOTFILES/setup.sh"
