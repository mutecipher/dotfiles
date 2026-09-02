# AGENTS.md

Personal dotfiles repository. Configs live here and are symlinked into `$HOME` or
`$HOME/.config/` by `setup.sh` (idempotent; see README.md for install/bootstrapping).

## Structure

- `.zshrc`, `.zprofile`, `.gitconfig` — root-level configs, symlinked to `$HOME`
- `.zprofile` — shell env init (Homebrew, nvm, pyenv, rbenv)
- `config/` — app configs symlinked into `$HOME/.config/` (nvim, ghostty, starship)
- `bin/` — custom scripts added to `$PATH` via `.zshrc`
- `lib/` — shell utility library; `bin/` scripts source it via `$DOTFILES_LIB`
  (exported in `.zshrc`), e.g. `. "$DOTFILES_LIB/clipboard.sh"`
- `Brewfile` — Homebrew dependencies (stays in repo, not symlinked)
- `setup.sh` — POSIX `sh` (no bashisms); add a `link` call here to symlink a new dotfile

## Editing rules

- Never commit generated files. `config/nvim/lazy-lock.json` is gitignored and
  rebuilt from source.
- Conventional commits (`feat(nvim):`, `fix(zsh):`, `chore:`).

## Neovim

LazyVim distribution; plugin specs in `config/nvim/lua/plugins/`.
