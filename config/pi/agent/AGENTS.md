# AGENTS.md

Global guidance for `pi`, applied across every project. Repo-level `AGENTS.md`
files layer on top and take precedence — keep this file free of stack- and
domain-specific rules.

## Interaction

- Be concise. Lead with the answer; skip preamble and "here's what I did" recaps.
- If a request is ambiguous or open-ended, ask clarifying questions before
  building.
- For design and layout choices, present options or a preview first — don't
  decide unilaterally.
- Show outcomes, not mechanics. Don't narrate the process.
- Ground factual claims in sources; flag uncertainty and conflicting evidence.

## Process

- For non-trivial work: investigate read-only, then plan, then execute.
- Commit as you go in small, atomic, logically-scoped commits using
  Conventional Commits. Push when asked.
- Make the hard change easy, then make the easy change. Land the preparatory
  refactor as its own commit before the behavior change, and avoid large
  sweeping diffs that are hard to review.
- Delegate independent or tangential work so the main thread keeps moving.
- Be token-mindful; match model and effort tier to the task.
- Verify by exercising the real thing, not just a test suite.
- Stay in scope. Don't refactor internals or widen the ask without checking
  first.

## Conventions

- Never commit generated files, secrets, or credentials; env and secrets live in
  gitignored files.
- Prefer explicit, visible configuration over hidden defaults.
- UI should match the host application's native look and feel using its existing
  widgets and theme tokens, and support both light and dark.
- Terminal output favors NerdFont symbols with Unicode fallbacks. Keep the main
  view quiet; push detail to logs or transcripts.
- Keep README human-facing and `AGENTS.md` agent-facing. Keep agent context lean,
  scoped to where it's relevant, and living with the code rather than in a
  central `/docs` folder.

## Environment

- macOS with Homebrew; zsh; nvm, pyenv, and rbenv.
- Ghostty terminal; `herdr` as the terminal workspace manager, paired with `pi`
  and `nvim`.
- Projects live under `~/Developer`; dotfiles are symlinked from `~/.dotfiles`.
- Neovim via LazyVim with Helix-like keybindings.
- Nerd Fonts are installed locally, but shipped code needs fallbacks.
- DeepSeek is the default provider; a local `mlx_lm` server is available.
