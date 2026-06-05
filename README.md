# den

[![CI](https://github.com/NekoBend/den/actions/workflows/ci.yml/badge.svg)](https://github.com/NekoBend/den/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)

My personal environment and tooling hub. One repo, two clearly separated
worlds: a portable LLM skill system (`agents/`), and the machine environment
(everything else).

## Quickstart

One installer, branching by component. It asks per component, so you install
only what you want:

```
git clone --depth 1 https://github.com/NekoBend/den.git
sh den/bootstrap/install.sh            # interactive: shell env? skills?
pwsh den/bootstrap/install.ps1         # same, on Windows
```

Or pick components non-interactively:

```
sh den/bootstrap/install.sh --shell --no-agents   # just the shell environment
sh den/bootstrap/install.sh --skills-only         # just the LLM agent skills
sh den/bootstrap/install.sh --all                 # everything, no prompts
```

The skills land in the directories coding agents read (`~/.agents`, `~/.claude`).
For OpenAI Codex, call the skills installer directly:

```
sh den/bootstrap/skills.sh --target ~/.codex --codex-config
```

The `den` CLI (verification helpers plus workspace memory and per-tool imprint
hooks) installs separately as a `uv` tool:

```
uv tool install .                           # puts `den` on PATH (from a checkout)
uv tool install git+https://github.com/NekoBend/den.git   # or straight from git
```

See `agents/README.md` for the skill system, `den/README.md` for the `den`
CLI, and `shell/README.md` for the shell environment.

## Layout

- `agents/`      LLM skill system: 8 skills + parent invariants + generated parent prompts. See `agents/README.md`.
- `den/`        the `den` CLI package: a dependency-free `uv` tool (`check`, `verify`, `refs`, `doc`, `memory`, `hook`) for LLM-assisted dev. See `den/README.md`.
- `bootstrap/`   the installer: one branching entry point (`install.sh`/`install.ps1`) plus the skills engine (`skills.sh`/`skills.ps1`) and the cmd/Clink shim installer.
- `shell/`       the interactive shell: bash/zsh, a PowerShell port, CMD shims, starship. See `shell/README.md`.
- `cheatsheets/` quick references (Python, regex, shell one-liners).
- `docker/`      dev container images (Ubuntu, Arch).
- `tests/`       shell functional tests (bash/zsh/pwsh, via `tests/shell/Dockerfile`).

## The installer

Everything installs from `bootstrap/`:

- `bootstrap/install.{sh,ps1}` is the single entry point. It branches by
  component (shell environment, LLM agent skills); skip the ones you do not
  want. Flags are the same `--xxx-yyy` form on both: `--shell/--no-shell`,
  `--agents/--no-agents`, `--skills-only`, `--all`, `--yes`, `--dry-run`.
  (PowerShell accepts a single or a double dash, so `--skills-only` works there
  too.)
- `bootstrap/skills.{sh,ps1}` is the skills engine the dispatcher delegates to;
  run it directly for skill-specific options (`--target`, `--codex-config`). It
  installs each skill as a self-contained unit, rewriting its shared references
  to absolute paths.
- `bootstrap/install.cmd` is a separate, smaller installer for the cmd/Clink
  shims on Windows.

## CI

`.github/workflows/ci.yml` runs three jobs: `agents` (ruff, pytest, bats),
`shell` (shellcheck + PSScriptAnalyzer, errors only), and `shell-tests` (the
bash/zsh/pwsh functional tests in Docker).

## Status

- `agents/` is complete and verified (build, install, and tests pass in CI).
- The environment (`bootstrap/`, `shell/`, `cheatsheets/`, `docker/`, `tests/`)
  has been migrated out of the old dotfiles repo, security- and
  performance-reviewed, and wired into CI. The shell layer keeps its existing
  modern -> native -> fallback wrapper design.
