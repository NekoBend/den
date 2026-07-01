# den

[![CI](https://github.com/NekoBend/den/actions/workflows/ci.yml/badge.svg)](https://github.com/NekoBend/den/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-yellow.svg)](LICENSE)

My personal environment and tooling hub. One repo, two clearly separated
worlds: a portable LLM skill system (`agents/`), and the machine environment
(everything else).

## Quickstart

`den` is the single command. Install it once (no clone needed), then it sets up
everything from content bundled in the package:

```
uv tool install git+https://github.com/NekoBend/den.git   # or: uv tool install . from a checkout
```

Then deploy what you want:

```
den install                        # interactive: asks shell? skills? which tools?
den install shell                  # shell env (bash/zsh + PowerShell, starship, cmd shims)
den install skills --all-tools     # LLM agent skills into every tool's dirs
den install skills --tool claude   # ...or just one tool
den install skills --target ~/.codex --codex-config   # print the Codex TOML block
den install hook --tool cline      # per-turn imprint hooks (run inside a workspace)
den install cheatsheets            # deploy the offline cheatsheets to your data dir
```

See `agents/README.md` for the skill system, `den/README.md` for the full `den`
CLI, and `shell/README.md` for the shell environment.

## Layout

- `agents/`      LLM skill system: 8 skills + parent invariants + generated parent prompts. See `agents/README.md`.
- `den/`        the `den` CLI package: a `uv` tool that bundles the deployable content and installs it (`install`, `uninstall`, `hook`, `memory`). Its only deps are `questionary` + `rich` for the interactive UI, with a stdlib fallback. See `den/README.md`.
- `shell/`       the interactive shell sources: bash/zsh, a PowerShell port, CMD shims, starship (deployed by `den install shell`). See `shell/README.md`.
- `cheatsheets/` quick references (Python, regex, shell one-liners).
- `docker/`      dev container images (Ubuntu, Arch).
- `tests/`       shell functional tests (bash/zsh/pwsh, via `tests/shell/Dockerfile`).

## The den CLI

Installation is `den` itself: `uv tool install` bundles the content (skills,
shared resources, parent prompts, shell sources, cheatsheets) into the wheel, so
`den install ...` deploys with no source checkout on disk. One cross-platform
Python implementation replaces the old bash + PowerShell installers.

- `den install skills` deploys each skill as a self-contained unit (the skill
  plus only the shared resources it references, with `shared/...` paths
  rewritten to absolute paths under the skill). `--tool`, `--all-tools`,
  `--target`, `--with-parent`, `--codex-config`, `--dry-run`.
- `den install shell` deploys the bash/zsh config to `~/.config/shell`, the
  PowerShell config to the profile dir, starship, and (on Windows) the cmd/Clink
  shims, then wires the relevant rc files idempotently.
- `den uninstall skills|shell` mirrors install: it removes a deployed file only
  when it is byte-identical to den's version (so your edits are kept), strips the
  rc-file block, and prunes emptied dirs. It is stateless (no manifest), lists
  the plan and asks before deleting (`--yes`, `--dry-run`).
- `den install hook` registers per-turn imprint hooks per workspace; `den hook`
  (run/list/imprint/memory) is the runtime plumbing those hooks invoke. See
  `den/README.md`.

## CI

`.github/workflows/ci.yml` runs four jobs: `agents` (ruff, pytest, bats, and a
lint of the generated parent prompts), `packaging` (wheel + sdist build,
completeness asserts, sourceless install), `shell` (shellcheck +
PSScriptAnalyzer, errors only), and `shell-tests` (the bash/zsh/pwsh functional
tests in Docker).

## Status

- `agents/` is complete and verified (build, install, and tests pass in CI).
- The environment (`shell/`, `cheatsheets/`, `docker/`, `tests/`) has been
  migrated out of the old dotfiles repo, security- and performance-reviewed, and
  wired into CI. The shell layer keeps its existing modern -> native -> fallback
  wrapper design.
- The bash/PowerShell installers were retired; `den install` is the one
  cross-platform installer.
