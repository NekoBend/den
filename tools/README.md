# tools - the `den` CLI

A small, dependency-free toolkit for LLM-assisted development workflows. It
bundles the verification scripts the skills use (`check`, `verify`, `refs`,
`doc`) with two workflow features for weak coding agents: a workspace
`memory` and per-tool `hook` installation that imprints context every turn.

This is the `tools/` subsystem of the `den` repo: a self-contained `uv` tool
package. It has no third-party dependencies (standard library only).

## Install

From the repo root:

```
uv tool install --editable ./tools     # puts `den` on PATH (~/.local/bin/den)
```

Editable so edits to `tools/*.py` take effect without reinstalling.

## Commands

```
den check  <file>              lint / format / typecheck a file (dispatches to run-checks.sh)
den verify <file>              check that imported APIs actually exist
den refs   --def|--uses SYM    find a symbol's definitions or usages across a tree
den doc    <file>              report docstring / doc-comment coverage
den memory show|save|...       workspace session memory (.den/memory.md)
den hook   install|run|...     per-tool hooks that imprint context every turn
```

`check`, `verify`, `refs`, and `doc` are ports of `agents/shared/scripts/`
exposed as a stable CLI. Run `den <command> --help` for per-command options.

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

`install` writes only the hooks den manages (marked by a sentinel) and leaves
foreign hooks untouched. Generic events map to each tool's own names:
`session-start`, `per-turn`, `post-tool`, `stop`.

### Per-tool support

| Tool | Per-turn inject | Mechanism | Config location |
|------|-----------------|-----------|-----------------|
| claude | yes | `hookSpecificOutput.additionalContext` | `~/.claude/settings.json` |
| gemini | yes | `hookSpecificOutput.additionalContext` | `~/.gemini/settings.json` |
| cline | yes | `contextModification` (script per event) | `~/.cline/hooks/` |
| copilot | session-start only | `additionalContext` (`userPromptSubmitted` is notify-only) | `~/.copilot/hooks/` |
| codex | not yet | (hooks ship as a marketplace plugin + trust) | deferred |

All four supported tools were verified end to end. codex is scaffolded but
disabled (`verified=False`) until the plugin/marketplace delivery is built.

## Architecture

Flat package: `den.py` is the dispatcher; each command is a sibling `_xxx.py`
module (`_check`, `_verify`, `_refs`, `_doc`, `_memory`, `_hook`) with a
`main(argv)` entry point. `den.py` inserts `tools/` on `sys.path` so the sibling
imports resolve however `den` is invoked. `den hook` registers a per-format
installer (`settings_json`, `copilot_json`, `cline_scripts`) and a per-tool
output emitter.

## Tests

```
python3 -m pytest tools/tests     # den memory + den hook (44 tests)
```

CI runs these in the `agents` job alongside `ruff check tools` and
`ruff format --check tools`.
