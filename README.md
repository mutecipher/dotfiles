# dotfiles

Config files that I use for my systems.

## Prerequisites

- `git`
- [oh-my-zsh](https://ohmyz.sh)
- [Homebrew](https://brew.sh) (macOS only)

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/mutecipher/dotfiles/main/install.sh | sh
```

This clones the repo to `~/.dotfiles` (or pulls if it already exists) and symlinks everything. Existing files are backed up with a `.bak` suffix.

It also bootstraps `herdr` (via its installer) and `pi` (via `npm install -g`) if they're missing. `pi` needs Node/npm, so install nvm from the `Brewfile` and start a fresh shell first.

## Re-running after updates

```sh
~/.dotfiles/setup.sh
```
