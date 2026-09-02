# AGENTS.md

Personal dotfiles repository. Configs live here and are symlinked into `$HOME` or
`$HOME/.config/` by `setup.sh` (idempotent; see README.md for install/bootstrapping).

## Structure

- `.zshrc`, `.zprofile`, `.gitconfig` — root-level configs, symlinked to `$HOME`
- `.zprofile` — shell env init (Homebrew, nvm, pyenv, rbenv)
- `config/` — app configs symlinked into `$HOME/.config/` (emacs, nvim, ghostty, starship)
- `bin/` — custom scripts added to `$PATH` via `.zshrc`
- `lib/` — shell utility library; `bin/` scripts source it via `$DOTFILES_LIB`
  (exported in `.zshrc`), e.g. `. "$DOTFILES_LIB/clipboard.sh"`
- `Brewfile` — Homebrew dependencies (stays in repo, not symlinked)
- `setup.sh` — POSIX `sh` (no bashisms); add a `link` call here to symlink a new dotfile

## Editing rules

- Never commit generated files. `config/emacs/config.el` and
  `config/nvim/lazy-lock.json` are gitignored and rebuilt from source.
- Emacs config is **literate**: edit `config/emacs/config.org`, never `config.el`.
- Conventional commits (`feat(emacs):`, `fix(zsh):`, `chore:`).

## Emacs

- Entry points: `config/emacs/early-init.el` (startup tuning),
  `config/emacs/init.el` (bootstraps org-babel tangle from `config.org`)
- Custom modules: `config/emacs/lisp/mutecipher-<feature>.el`, each a standalone
  `provide`d feature. `mutecipher-acp.el` is the ACP client entry point.
- Themes in `config/emacs/themes/`, ert tests in `config/emacs/test/`. Run one test file:

  ```sh
  emacs -Q --batch -L config/emacs/lisp -L config/emacs/test \
    -l config/emacs/test/<name>-tests.el -f ert-run-tests-batch-and-exit
  ```

## Neovim

LazyVim distribution; plugin specs in `config/nvim/lua/plugins/`.
