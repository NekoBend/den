# den - the unified CLI

A small CLI for LLM-assisted development. It bundles the deployable content
(skills, shared resources, parent prompts, shell sources, cheatsheets) into its
wheel and installs it, plus verification helpers, a workspace `memory`, and
per-turn `hook` imprinting for weak coding agents.

This is the `den/` package of the `den` repo: a self-contained `uv` tool whose
only runtime deps are `questionary` + `rich`, used purely for the interactive
UI. Every command degrades to plain stdin prompts and `print()` when those are
absent (see `den/_ui.py`), so the CLI still works on a stdlib-only interpreter
and in pipes / CI.

## Install

```
uv tool install git+https://github.com/NekoBend/den.git   # no clone needed
uv tool install .                                          # or from a checkout
```

The wheel bundles content under `den/_data/`, so `den install ...` works with no
source on disk; from a checkout it falls back to the repo root (`_content.py`).

## Commands

```
den install [skills|shell]     interactive setup, or deploy skills / shell directly
den hook    install|run|...    per-turn imprint hooks, per workspace
den memory  show|save|...      workspace session memory (.den/memory.md)
den cheat   [name]             view bundled cheatsheets offline
den check   <file>             lint / format / typecheck a file (run-checks.sh)
den verify  <file>             check that imported APIs actually exist
den refs    --def|--uses SYM   find a symbol's definitions or usages
den doc     <file>             docstring / doc-comment coverage
```

`den install` never silently clobbers local edits: files that already exist and
differ from the bundled version are listed and you are asked once before
overwriting (default no, so your changes are kept). Pass `--force` to overwrite
without asking; non-interactive runs skip the changed files. `den hook install`
into a tool's settings.json merges (it preserves foreign hooks and other keys).

Run `den <command> --help` for per-command options.

## `den memory`

Workspace-level session memory that the agent reads and overwrites. It lives at
`<project>/.den/memory.md`: a single Markdown file the agent owns and rewrites
wholesale. Because the agent may edit it directly (with its own file tools, not
only via `den memory save`), a content-hash `checkpoint` snapshots it into
`.den/history/` whenever it changes, so direct edits are captured and any bad
overwrite is recoverable.

| Subcommand | What it does |
|------------|--------------|
| `show` | print `memory.md` (empty if absent) |
| `save [--file F]` | overwrite `memory.md` from stdin or F (snapshots the old content first) |
| `checkpoint` | snapshot `memory.md` into history if it changed |
| `clear` | delete `memory.md` (snapshots it first) |
| `log` | list history snapshots, newest first |
| `restore [n]` | restore the n-th newest snapshot (default 1) |
| `diff [n]` | diff `memory.md` against the n-th newest snapshot |
| `path` | print the resolved `memory.md` path |

The `.den/` directory is resolved by walking up from the current directory to the
nearest existing `.den/`, falling back to `<cwd>/.den`. History keeps the last 20
snapshots.

## `den hook`

Installs per-tool hooks that imprint context every turn. Soft enforcement only:
the hooks never block a tool call. Each turn the tool runs `den hook run`, which

1. injects `.den/imprint.md` (static, human-owned directives) plus
   `den memory show` (agent-owned memory) as additional context, and
2. checkpoints memory, capturing the previous turn's direct edits.

Two files, two owners:

- `.den/imprint.md` - static directives that must not fall out of context (read
  the skill, use a subagent, record memory). Seeded with defaults on install,
  then human-edited. The agent does not overwrite it.
- `.den/memory.md` - the agent-owned, overwritable memory above.

```
den hook install [--tool T ...] [--all-tools]   # register hooks + seed imprint.md
den hook imprint                                 # print the composed injection
den hook list                                    # show den-managed hooks
den hook remove [--tool T ...]                    # unregister
den hook run --event E --tool T                   # the worker the tool invokes
```

Hooks install **per workspace**: run `den hook install` inside a project and it
writes that tool's project-level hook config under the current directory and
seeds `<cwd>/.den/imprint.md`, so hook + imprint + memory share one `.den` scope.
`install` writes only the hooks den manages (marked by a sentinel) and leaves
foreign hooks untouched. Generic events map to each tool's own names:
`session-start`, `per-turn`, `post-tool`, `stop`.

### Per-tool support

| Tool | Per-turn inject | Mechanism | Workspace config |
|------|-----------------|-----------|------------------|
| claude | yes | `hookSpecificOutput.additionalContext` | `.claude/settings.json` |
| gemini | yes | `hookSpecificOutput.additionalContext` | `.gemini/settings.json` |
| cline | yes | `contextModification` (script per event) | `.clinerules/hooks/` |
| copilot | session-start only | `additionalContext` (`userPromptSubmitted` is notify-only) | `.github/hooks/den.json` |
| codex | not yet | (hooks ship as a marketplace plugin + trust) | deferred |

For cline, `install` writes one script per event, named for the platform Cline
expects: extensionless `<Event>` (executable bash) on macOS/Linux, `<Event>.ps1`
(PowerShell) on Windows. Either way the script just calls `den hook run`, so
`den` must be on PATH where Cline runs the hook.

claude, gemini, copilot, and the macOS/Linux cline path were verified end to end.
The Windows cline `.ps1` path follows Cline's documented contract; verify against
a live Windows install. codex is scaffolded but disabled (`verified=False`).

## Architecture

`cli.py` is the dispatcher; each command is a sibling `_xxx.py` module
(`_check`, `_verify`, `_refs`, `_doc`, `_memory`, `_hook`, `_install`, `_shell`,
`_cheat`) with a `main(argv)` entry point and relative imports. `_content.py`
locates bundled content (wheel `den/_data/`, or the repo root from a checkout).
`den hook` registers a per-format installer (`settings_json`, `copilot_json`,
`cline_scripts`) and a per-tool output emitter; `den install` is one
cross-platform implementation of the skill and shell-environment installers.

## Tests

```
python3 -m pytest tests/den     # den memory, hook, install, shell, cheat
```

CI runs these alongside `ruff check agents den tests` and a `packaging` job
that builds the wheel and smoke-tests a sourceless install.
