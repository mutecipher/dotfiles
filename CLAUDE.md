# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Repository Overview

A personal dotfiles repository managed via automated symlinks. Configs live here and are symlinked into `$HOME` or `$HOME/.config/`.

## Setup

Prerequisites: oh-my-zsh and Homebrew must already be installed.

```sh
# Bootstrap a new machine (clones repo + runs setup.sh)
curl -fsSL https://raw.githubusercontent.com/mutecipher/dotfiles/main/install.sh | sh

# Or, if the repo is already cloned, create/update symlinks
sh ~/.dotfiles/setup.sh
```

`setup.sh` is idempotent — safe to re-run. Existing files are backed up with a `.bak` suffix before being replaced; already-correct symlinks are skipped.

## Structure

- `.zshrc`, `.zprofile`, `.gitconfig` — root-level shell/git configs, symlinked to `$HOME`
- `config/` — app configs symlinked into `$HOME/.config/` (emacs, nvim, ghostty)
- `config/starship.toml` — Starship prompt config (a file, not a directory like the others)
- `bin/` — custom scripts added to `$PATH` via `.zshrc`
- `lib/` — shell utility library (`clipboard.sh`, `color.sh`, `date-time.sh`, `fs.sh`, `logger.sh`) sourced by scripts in `bin/`
- `Brewfile` — all macOS dependencies managed by Homebrew

## Emacs Configuration

The Emacs config uses **literate programming** via Org-mode:
- Entry points: `config/emacs/early-init.el` (startup tuning), `config/emacs/init.el` (bootstraps org-babel tangle)
- Source: `config/emacs/config.org`
- Generated: `config/emacs/config.el` (excluded from git, built at load time)
- Custom modules: `config/emacs/lisp/` — naming convention `mutecipher-<feature>.el`, each is a standalone `provide`d feature
- Custom themes: `config/emacs/themes/` (`liminal-dark-theme.el`, `liminal-light-theme.el`)

When modifying Emacs config, edit `config.org` — never edit `config.el` directly. The `.gitignore` excludes `config.el`, `cache/`, `elpa/`, and `tree-sitter/`.

### Emacs modules (`lisp/`)

| Group | Modules |
|---|---|
| UI / appearance | `mutecipher-appearance.el`, `mutecipher-modeline.el`, `mutecipher-icons.el`, `mutecipher-colorize.el` |
| Editing / display | `mutecipher-centered.el`, `mutecipher-ligatures.el`, `mutecipher-tidy.el`, `mutecipher-flymake-inline.el`, `mutecipher-hover.el`, `mutecipher-vc-gutter.el` |
| Language / treesit | `mutecipher-treesit.el` |
| Content / modes | `mutecipher-blog.el`, `mutecipher-markdown.el`, `mutecipher-todo-keywords.el` |
| Tools / integrations | `mutecipher-acp.el`, `mutecipher-containers.el`, `mutecipher-git-blame.el` |

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
- `token-estimate` — token count estimation
- `+x` — shorthand for `chmod +x`

## Commit Style

Use **conventional commits** (e.g. `feat(emacs):`, `fix(zsh):`, `chore:`).
