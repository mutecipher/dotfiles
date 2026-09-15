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

## Homebrew packages

```sh
brew bundle                            # shared, every machine
brew bundle --file=Brewfile.personal   # personal machine only
```

`Brewfile.personal` holds things I only want at home. It is not included by `Brewfile`, so `brew bundle cleanup` needs the same `--file` or it will offer to uninstall everything in it.

## Re-running after updates

```sh
~/.dotfiles/setup.sh
```
