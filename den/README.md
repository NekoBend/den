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
den install   [skills|shell|hook|cheatsheets]   interactive setup, or one target
den uninstall [skills|shell|hook|cheatsheets]   remove den files, keeping your edits
den upgrade   [--refresh] [--force]             upgrade den via uv (alias: update)
den board     [--port N] [--open] [--dir PATH]  serve the project's report board

# runtime plumbing invoked by installed hooks and skills (not everyday commands):
den hook   run|list|imprint|memory   the per-turn worker + hook lifecycle
den hook memory show|add|...          workspace session memory (.den/memory.md)
den verify <file.py...>               format/lint/typecheck each file, config-faithfully
```

`den install` never silently clobbers local edits: files that already exist and
differ from the bundled version are listed and you are asked once before
overwriting (default no, so your changes are kept). Pass `--force` to overwrite
without asking; each file it overwrites is first copied to `<file>.den.bak`
(`.den.bak.1`, `.2`, ... when an earlier backup holds something else; the copy
keeps the file's permissions minus execute).
Non-interactive runs skip the changed files and exit non-zero,
so a scripted install cannot mistake a full skip for success. `den install hook`
into a tool's settings file merges (it preserves foreign hooks and other keys).

### Parent profiles (frontier / weak)

The parent prompt ships in two profiles. `--profile frontier` (the default)
deploys the compact invariants parent for models that follow instructions
natively and auto-fire skills. `--profile weak` deploys the skill router:
maximal scaffolding for weak/local models, written to whatever parent file
the tool reads. Every tool defaults to frontier; the interactive flow asks
about weak only for cline / cline-cli / copilot (the tools where local or
weak models are plausible).

For mixed usage (the same tool running frontier today and a weak model
tomorrow), keep the global parent frontier and give the weak-model project
its own workspace deploy:

```
den install skills --target . --with-parent --profile weak
```

A `--target` directory is treated as a checkout den does not control: a
destination that reaches a symlink below it (a `CLAUDE.md` or `AGENTS.md`
linked elsewhere, a symlinked `skills/`, a dangling link) is refused and
reported, never written through, and the run exits non-zero. The default
tool dirs (`~/.claude`, `~/.agents`, ...) still follow links, so a dotfiles
setup that symlinks them keeps working.

Double-load caveat: cline (extension) reads its global Rules dir AND a
workspace `AGENTS.md`; Copilot reads its global instructions AND a repo
`.github/copilot-instructions.md`. In a weak workspace both parents load;
that is safe (the rules agree) but costs the weak model input budget -
cline's Rules UI can toggle the global parent off per workspace. codex
and cline-cli read a single global file, so no double load.

On Windows, `den install shell --coreutils` also installs microsoft/coreutils via
winget (an interactive run asks; default no). The pwsh wrappers then use it as
their Unix-command tier (`ls`/`cat`/`grep`/`find`/`cp`/`rm`/...); see
`shell/README.md`. It is Windows + pwsh 7 only and falls back to the PowerShell
builtins when absent.

`den uninstall` is the mirror: it re-derives what `den install` would deploy and
removes each file ONLY if it is byte-identical to den's version, so a file you
edited is kept and reported (package-manager semantics). It is stateless (no
manifest): "unchanged" means "matches what this den version installs". It strips
the rc-file `# ===== den =====` block and prunes dirs den created that became
empty. It lists the plan and asks once before deleting (`--yes` to skip,
`--dry-run` to preview only; non-interactive runs require `--yes`). Hooks are
per-workspace, so `den uninstall` does not touch them; use `den uninstall hook`.

Being stateless has one cost: when den stops deploying something (a retired
tool, a renamed skill, a deleted script), the old copy is no longer anything
den knows about, so no den command removes it.
[`MIGRATIONS.md`](../MIGRATIONS.md) lists every such leftover with the command
that clears it.

Run `den <command> --help` for per-command options.

## `den upgrade`

`den upgrade` (alias `den update`) runs `uv tool upgrade den`, so it follows
whatever source den was installed from (the git URL above, or a local path).
Upgrading swaps the binary and its bundled content, but bundled content only
reaches disk on `den install ...` - so after an upgrade your deployed skills
and shell files are still the old version's until redeployed. Two ways:

```
den upgrade --refresh    # upgrade, then redeploy what den had deployed
den upgrade              # upgrade only; prints a reminder to redeploy
```

`--refresh` redeploys only what den can prove it wrote. Before running uv, the
running (old) den compares every deployed file in each tool dir (`~/.claude`,
`~/.agents`, `~/.copilot`, the cline Rules dir, `~/.codex`) and the shell files
byte for byte with its own bundled content, both skill flavors and both parent
profiles. After the upgrade the *new* binary (the running process still has the
old package imported) redeploys:

- the skills in each tool dir that holds den's skills, in the flavor found
  there (`--no-den-cli` or not); a skill you deleted stays deleted, a skill the
  new version added arrives, and the same holds for a file within a skill;
- each parent prompt that matched a profile, in that same profile; a parent
  that matches neither (hand-written, or edited) is left alone and named, even
  with `--force`;
- the shell files, when den's were found, as they were installed: the extras
  only when some were on disk (a `--no-extras` install stays without), and
  den's `~/.local/bin` helpers only when some were there (`--bin`); a shell
  file you deleted stays deleted.

A file still exactly as the old den deployed it is replaced; that is checked
again right before the write, so an edit made while uv runs counts as yours.
Any other file that differs (your edit, or a file from an earlier version
whose update was skipped back then) is kept and listed, and the refresh still
exits 0. A file the old den deploys that is missing (deleted, or never
deployed because an earlier update was skipped) is not created and is listed
too. `--force` replaces or creates those as well, copying each existing one
to `<file>.den.bak` first (a parent prompt edited while uv ran is kept even
then). den still records nothing between runs: the lists of files, with a
SHA-256 of each one den wrote, are a temporary hand-over from the old binary
to the new one (`den install skills|shell --refresh-plan FILE`). Skills
deployed with `--target` are not refreshed; re-run that install. `--dry-run`
shows what would be refreshed without running anything.

The refresh is driven by the den you upgrade *from*. Upgrading from a den
older than this behavior still runs that den's refresh (`den install skills
--with-parent` into `~/.claude` and `~/.agents`, frontier profile); for that
one upgrade, run `den upgrade` without `--refresh` and redeploy by hand.

Windows caveat: `den upgrade` runs from the very tool venv uv replaces, and
Windows locks running executables. If uv reports a file-in-use error there,
run `uv tool upgrade den` directly from your shell instead (den itself then
is not running, so nothing is locked).

## `den board`

A per-project localhost page for reporting observations back to an agent
while you exercise the thing under test (a game, a build, a device) - so a
debug session does not round-trip through chat for every "ran it again,
here is what happened". Press a button, optionally attach a note; each
report is appended as one JSON line (`{ts, button, text}`) to
`.den/board/reports.jsonl`. Agents never talk to the server: they read
that file (the troubleshoot skill checks for it by name).

```
den board                 # serve http://127.0.0.1:8484 for the nearest .den project
den board --open          # ...and open it in the browser
den board --port 9000     # prefer another port
den board --dir ~/proj    # serve a specific project root

# the agent-side surface (append to .den/board/agent.jsonl, print the new id):
den board task "retest the boss fight after this fix"
den board reply <report-id> "seen - fixed in build 7, please retry"
```

The channel is two-way with exactly one writer per file: the server appends
the user's reports to `reports.jsonl`; agents append tasks and replies to
`agent.jsonl` (ids are generated - use the commands above rather than
hand-writing JSON; a hand-appended line without an id still works, the
server derives a stable one from its content). The page shows open tasks
with Done / Can't buttons - the user's reaction lands in `reports.jsonl`
with `re=<task id>` - and threads replies under the report they name.
Agents still never talk to the server.

Multiple boards coexist: each project has its own server, file, and lock.
If the preferred port is busy the next free one is used; a second
`den board` in the same project just reprints the live instance's URL; the
page titles itself after the project so parallel tabs stay apart. The
server binds 127.0.0.1 only, refuses non-loopback Host headers (DNS
rebinding), and refuses browser writes whose Origin is not the board
itself. Edit `.den/board/board.json` to rename the
board or change its button set (`{id, label, color}` per button); delete
`reports.jsonl` (or ask the agent to) when a session is done.

## `den hook memory`

Workspace-level session memory that the agent reads and overwrites. It lives at
`<project>/.den/memory.md`: a single Markdown file the agent owns. It can be
rewritten wholesale (`save`, or the agent's own file tools) or grown one fact at
a time with `add` (a low-friction append, so a weak agent records a decision
without reproducing the whole file). Because the agent may edit it directly, a
content-hash `checkpoint` snapshots it into `.den/history/` whenever it changes,
so direct edits are captured and any bad overwrite is recoverable.

| Subcommand | What it does |
|------------|--------------|
| `show` | print `memory.md` (empty if absent) |
| `save [--file F]` | overwrite `memory.md` from stdin or F (snapshots the old content first) |
| `add <text>` | append one fact to `memory.md` from args or stdin (snapshots first); low-friction counterpart to `save` |
| `checkpoint` | snapshot `memory.md` into history if it changed |
| `clear` | delete `memory.md` (snapshots it first) |
| `log` | list history snapshots, newest first |
| `restore [n]` | restore the n-th newest snapshot (default 1) |
| `diff [n]` | diff `memory.md` against the n-th newest snapshot |
| `path` | print the resolved `memory.md` path |

Memory is UTF-8 text whatever the locale: `show`, `log`, `diff` and
`den hook imprint` write UTF-8, and `save`/`add` read stdin (and `save --file`
its file) as UTF-8 (a leading BOM is dropped), also on a Windows console set to
an ANSI code page. Input that is not UTF-8 is refused with exit 2 and nothing is
written.

The `.den/` directory is resolved by walking up from the current directory to the
nearest existing `.den/`, falling back to `<cwd>/.den`. History keeps the last 20
snapshots. Only files named the way den names them (`memory.<UTC stamp>.md`,
with a stamp that is not in the future) are snapshots: anything else in
`.den/history/`, such as a `memory.zzz.md` a cloned repo shipped to sort first,
is never listed, restored, rotated or deleted, and `den install hook` names it
along with the first line of every real snapshot.

den never follows a symlink at or under `.den/` (memory, imprint, history,
the board files, and the `.clinerules` mirror): a cloned repository ships the
layout of `.den/`, and a symlink there would pull an outside file into the
model's context every turn or make `save`/`add`/`restore` write through it.
A refused read yields nothing and says so once on stderr; a refused write
fails.

## `den hook`

Installs per-tool hooks that imprint context every turn. Soft enforcement only:
the hooks never block a tool call. Each turn the tool runs `den hook run`, which

1. injects `.den/imprint.md` (static, human-owned directives) plus
   `den hook memory show` (agent-owned memory) as additional context, and
2. checkpoints memory, capturing the previous turn's direct edits.

`den hook run` fails open for every tool: an argument it does not know (an
event or tool from another den version), a pinned `--den-dir` that is not
absolute on this OS (a command written on the other side of a WSL/Windows
pair), or an error while reading memory is one line on stderr, the tool's
empty response, and exit 0 with nothing injected. It never exits 2, which
Claude Code treats as blocking the prompt.

Two files, two owners:

- `.den/imprint.md` - static directives that must not fall out of context (read
  the skill, use a subagent, record memory). Seeded with defaults on install,
  then human-edited. The agent does not overwrite it.
- `.den/memory.md` - the agent-owned, overwritable memory above.

```
den install hook [--tool T ...] [--all-tools]    # register hooks + seed imprint.md
den uninstall hook [--tool T ...]                # unregister
den hook imprint                                 # print the composed injection
den hook list                                    # show den-managed hooks
den hook memory show|add|...                     # workspace session memory
den hook run --event E --tool T                   # the worker the tool invokes
```

Hooks install **per workspace**: run `den install hook` inside a project and it
writes that tool's project-level hook config under the current directory and
seeds `<cwd>/.den/imprint.md`, so hook + imprint + memory share one `.den` scope.
`install` writes only the hooks den manages (marked by a sentinel) and leaves
foreign hooks untouched. Generic events map to each tool's own names:
`session-start`, `per-turn`, `post-tool`, `stop`.

`--all-tools` installs every verified tool: claude, copilot and cline (the
extension). cline-cli is installed only when named, and naming it together
with cline (or with `--all-tools`, which adds to any `--tool`) is refused
(exit 2), in the interactive picker too, because the
extension would then load the imprint and memory twice (see below). For
`list` and `uninstall hook`, `--all-tools` still covers every tool.

The workspace-relative config (`.claude/settings.local.json` and the other
per-tool paths below) must stay in the workspace: `den install hook` refuses it
when any path component is a symlink, so a checked-out repo cannot redirect the
install into your global settings. An explicit `--config PATH` is taken as given.

Each hook command pins this machine's absolute `.den` path, so claude's hooks go
to `.claude/settings.local.json`, Claude Code's personal file, not the shared
`.claude/settings.json` you commit. `den install hook` moves den's entries out
of `.claude/settings.json` (an earlier den wrote them there; everything else in
the file is kept, and a file without den entries is not touched; a symlinked
one is never edited: `list` shows den's entries there, and install and
`uninstall hook` exit 1 until you remove them by hand), `list` and
`uninstall hook` read both files, and inside a git work tree install adds
`settings.local.json` to `.git/info/exclude` unless git already ignores it.
copilot (`.github/hooks/den.json`) and cline (`.clinerules/hooks/`) have no
personal counterpart; there, a command from another machine just fails open.
The install also reports a pre-existing `.den/memory.md` (size, first line,
snapshot count, and each snapshot's first line, since `restore` can bring any of
them back) next to the imprint, because both are injected every turn.

### Per-tool support

| Tool | Per-turn inject | Mechanism | Workspace config |
|------|-----------------|-----------|------------------|
| claude | yes | `hookSpecificOutput.additionalContext` | `.claude/settings.local.json` |
| cline | yes (extension) | `contextModification` (script per event) | `.clinerules/hooks/` |
| cline-cli | session-start | `.clinerules/*.md` rule files (no hook) | `.clinerules/` |
| copilot | session-start only | `additionalContext` (`userPromptSubmitted` is notify-only) | `.github/hooks/den.json` |
| codex | not yet | (hooks ship as a marketplace plugin + trust) | deferred |

`cline` and `cline-cli` are split because the two consume hooks differently. The
**VS Code extension** (`cline`) runs the per-event hook scripts and injects
`contextModification` into the conversation each turn (gated by its `hooksEnabled`
setting). The **CLI** (`cline-cli`) cannot: its file hooks are observe-only
(`prompt_submit`/`agent_start` are fire-and-forget; only `cancel`/`overrideInput`
on `tool_call` are applied, and `context`/`contextModification` are parsed then
ignored). So for the CLI, den does not install a hook; instead it writes the
imprint and memory as **`.clinerules/` rule files** (`den-imprint.md`,
`den-memory.md`), which cline loads as always-on context at session start. `den
memory` keeps `den-memory.md` in sync (`save`, `add`, `clear`, `restore`,
`checkpoint`, and every `den hook run` in the workspace refresh it), so a direct
edit to `.den/memory.md` reaches cline-cli at the next of those; the imprint rule
tells the agent to run `den hook memory checkpoint` after one. The mirror runs
only when cline-cli is installed here
(detected by the `den-imprint.md` marker) -- so the extension's own
`.clinerules/hooks/` does not trigger a memory mirror. That gate is what keeps the
extension from double-delivering memory (it would otherwise inject via the hook
AND read the `.clinerules` rule), and it is why den refuses to install both.

For `cline` (extension), `install` writes one script per event, named for the
platform Cline expects: extensionless `<Event>` (executable bash) on macOS/Linux,
`<Event>.ps1` (PowerShell) on Windows. Either way the script just calls `den hook
run`, so `den` must be on PATH where Cline runs the hook.

claude, copilot, and the macOS/Linux cline extension path were verified
end to end. gemini support is retired: gemini-cli hit upstream end-of-life
for individual accounts (2026-06), and its successor (Antigravity) reads
the cross-tool `~/.agents/skills` + `AGENTS.md` that den already deploys -
a tool-specific entry returns only after verification against the real
CLI. `den uninstall` sweeps legacy `~/.gemini/skills` copies. The cline-cli `.clinerules` delivery was validated manually against
the real CLI (a seeded rule reached the model); CI is Linux-only and does not run
the cline CLI runtime. The Windows cline `.ps1` path follows Cline's documented
contract; verify against a live Windows install. codex is scaffolded but disabled
(`verified=False`).

## `den verify`

One entry point the skills call after writing a Python file:

```
den verify path/to/file.py
```

It runs `ruff format --check`, `ruff check`, and `ty check` on that one file and
prints line-oriented `PASS`/`FAIL`/`SKIP` results plus a summary. The design rule
is "discover like the tools do, make the discovery visible, never override":

- **ruff**: den re-walks ruff's own nearest-wins discovery (`.ruff.toml` >
  `ruff.toml` > `pyproject.toml` with `[tool.ruff]`, walking up from the file's
  directory) only to *report* which config wins, on the `config: ruff <- ...`
  line. ruff itself runs with no config flags, so the project's settings are
  never stomped - the historical failure mode where a wrapper's injected flags
  made `pyproject.toml` look ignored. Only when no config exists anywhere up the
  tree does den add its defaults (`D101,D102,D103`, missing public docstrings).
- **ty**: import resolution needs a real environment, so den passes the project
  root explicitly (`--project <nearest pyproject.toml/ty.toml ancestor>`) and
  the `config: ty` line reports the venv ty will see (`VIRTUAL_ENV`, else
  `<root>/.venv`, else a hint to run `uv sync`).

Exit codes: 0 = no failures (skips allowed), 1 = a stage failed, 2 = usage.
Missing tools are `SKIP` lines naming the install command, never failures.
Both tools are resolved through `PATH` alone and run by absolute path, so one
that resolves to the working directory itself - a cloned repo shipping its own
`ruff.exe`, which Windows would otherwise prefer over the installed one - is
refused and counted as a `SKIP`, never executed; a tool from the project's own
`.venv` is unaffected.
Python only; other languages go through the coding skill's `run-checks.sh`.

## Architecture

`cli.py` is the dispatcher; each command is a sibling `_xxx.py` module
(`_memory`, `_hook`, `_install`, `_uninstall`, `_upgrade`, `_verify`) with a
`main(argv)`
entry point and relative imports (`_shell`/`_ui` are shared helpers).
`_content.py`
locates bundled content (wheel `den/_data/`, or the repo root from a checkout).
`den hook` registers a per-format installer (`settings_json`, `copilot_json`,
`cline_scripts`) and a per-tool output emitter; `den install` is one
cross-platform implementation of the skill and shell-environment installers.

## Tests

```
python3 -m pytest tests/den     # cli, hook, memory, install, uninstall, shell
```

CI runs these alongside `ruff check agents den tests hatch_build.py` and a `packaging` job
that builds the wheel and smoke-tests a sourceless install.
