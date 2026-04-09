# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

A personal dotfiles repository managed via manual symlinks (no Stow or Chezmoi). Configs live here and are symlinked into `$HOME` or `$HOME/.config/`.

## Setup

Prerequisites: oh-my-zsh and Homebrew must already be installed.

```sh
# Install Homebrew packages
brew bundle

# Create symlinks manually (examples from README)
ln -s $HOME/.dotfiles/.gitconfig $HOME/.gitconfig
ln -s $HOME/.dotfiles/.zshrc $HOME/.zshrc
ln -s $HOME/.dotfiles/config/nvim $HOME/.config/nvim
ln -s $HOME/.dotfiles/config/ghostty $HOME/.config/ghostty
```

## Structure

- `.zshrc`, `.zprofile`, `.gitconfig` — root-level shell/git configs, symlinked to `$HOME`
- `config/` — app configs symlinked into `$HOME/.config/` (emacs, nvim, ghostty, starship)
- `bin/` — custom scripts added to `$PATH` via `.zshrc`
- `Brewfile` — all macOS dependencies managed by Homebrew

## Emacs Configuration

The Emacs config uses **literate programming** via Org-mode:
- Source: `config/emacs/config.org`
- Generated: `config/emacs/config.el` (excluded from git, built at load time)
- Custom modules: `config/emacs/lisp/` (`mutecipher-tidy.el`, `mutecipher-ligatures.el`, `mutecipher-centered.el`)

When modifying Emacs config, edit `config.org` — never edit `config.el` directly. The `.gitignore` excludes `config.el`, `cache/`, `elpa/`, and `tree-sitter/`.

## Neovim Configuration

Uses **LazyVim** distribution. Plugin specs live in `config/nvim/lua/plugins/`. The `lazy-lock.json` is excluded from git.

## Key Shell Aliases

- `dotfiles` — cd to this repo
- `vim` — aliased to `nvim`
- `k` / `kn` — kubectl shortcuts
- `dcu` / `dce` — dev container commands using Podman

## Custom bin/ Scripts

Notable utilities in `bin/`:
- `git-amend`, `git-nuke`, `git-uncommit` — Git workflow helpers
- `gpg-copy-key`, `ssh-copy-key` — key export utilities
- `dither` — image dithering utility
- `+x` — shorthand for `chmod +x`

## Commit Style

Use **conventional commits** (e.g. `feat(emacs):`, `fix(zsh):`, `chore:`).
