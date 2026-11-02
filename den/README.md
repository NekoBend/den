# den - the unified CLI

A small CLI for LLM-assisted development. It bundles the deployable content
(skills, shared resources, parent prompts, shell sources, cheatsheets) into its
wheel and installs it, plus a verification helper the skills call and a
per-project report board.

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
den install   [skills|shell|cheatsheets]        interactive setup, or one target
den uninstall [skills|shell|hook|cheatsheets]   remove den files, keeping your edits
den upgrade   [--refresh] [--force]             upgrade den via uv (alias: update)
den board     [--port N] [--open] [--dir PATH]  serve the project's report board

# runtime plumbing (not everyday commands):
den verify <file.py...>               format/lint/typecheck each file, config-faithfully
den hook run ...                      a no-op left for hooks an older den installed
```

`den install` never silently clobbers local edits: files that already exist and
differ from the bundled version are listed and you are asked once before
overwriting (default no, so your changes are kept). A yes covers the files as
they were listed: one you save again or delete while that prompt is open
stays as you left it, and the run exits non-zero.
Pass `--force` to overwrite without asking; each file it overwrites is first
copied to `<file>.den.bak` (`.den.bak.1`, `.2`, ... when an earlier backup
holds something else; the copy takes the file's owner, group and, on Linux,
its ACL and extended attributes, and its permissions minus execute, and a file
it cannot copy that way is not overwritten).
Non-interactive runs skip the changed files and exit non-zero,
so a scripted install cannot mistake a full skip for success.

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
empty. An rc file is rewritten through a new copy that replaces it, so one
with a second hard link (a dotfiles repo) is left as it is, block included,
and named for you to edit by hand: a new copy would split it from its other
names. The copy takes the file's owner, group and permission bits and, on
Linux, its extended attributes and ACLs; a file whose owner, group or
attributes it cannot take is left and named the same way. It lists the
plan and asks once before deleting (`--yes` to skip,
`--dry-run` to preview only; non-interactive runs require `--yes`). Each file
is compared again right before it is deleted, so one you save, or replace
with something else (a directory, say), while that prompt is open is kept
and named. A `--target` directory gets the same symlink rule as on install:
a path that reaches a symlink below it is refused and reported, never
removed through. The run exits non-zero when it refuses such a path, keeps
a file changed while the prompt was open, or cannot read or remove a file,
or read or rewrite an rc file (each one is named, and the closing count
holds only what was really removed). Hooks an older den installed are
per workspace, so `den uninstall` does not touch them; use
`den uninstall hook` (below).

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
`reports.jsonl` (or ask the agent to) when a session is done. The page's
task answers come from one full read of `reports.jsonl` and then only from
what is appended to it, so after a hand edit that keeps the file's size
(`task-done` changed to `task-cant`, say), a task can show its old answer
until you restart `den board`. Agents read the file itself and see the
edit at once.

den never follows a symlink at or under `.den/`: a cloned repository ships
the layout of `.den/`, and a symlink there would make the board read, serve
or append to a file outside the project. A refused read yields nothing and
says so once on stderr; a refused write fails.

## Hooks and memory (removed)

den no longer installs per-turn hooks or keeps a workspace memory: the agent
tools keep a memory of their own now. `den memory`, `den hook memory`,
`den hook install` / `den install hook`, `den hook list`, `den hook imprint`
and `den hook remove` were removed. Each one now prints one line on stderr
that names the removal and [`MIGRATIONS.md`](../MIGRATIONS.md), and exits 1
(not 2, which a Claude Code hook reads as "block the prompt").
MIGRATIONS.md, section 9, says how to clean a workspace up.

Two commands stay for the workspaces an older den set up:

- `den hook run`, which those hooks still call, is a no-op. It takes any
  arguments an installed hook passes, reads nothing (no `.den`, no stdin),
  writes nothing, prints nothing on stderr, and exits 0 with the response
  each tool takes for "nothing to add":

  | Tool | stdout |
  |------|--------|
  | claude | nothing |
  | copilot | `{}` |
  | cline (the VS Code extension) | `{"cancel": false}` |
  | cline-cli, or a tool den does not know | nothing |

- `den uninstall hook [--tool T]... [--all-tools] [--config PATH]` takes
  den's hooks out of the current workspace (every tool when none is named):

  | Tool | What it removes |
  |------|-----------------|
  | claude | den's entries in `.claude/settings.local.json` and in the `.claude/settings.json` earlier dens wrote |
  | copilot | den's entries in `.github/hooks/den.json` |
  | cline | den's scripts in `.clinerules/hooks/` (`<Event>` or `<Event>.ps1`) |
  | cline-cli | `.clinerules/den-imprint.md` and `den-memory.md`, beside the nearest `.den` |

  An entry is den's when its command carries `den hook run`. Everything else
  stays: a foreign hook in a group den wrote, other keys, and shapes den never
  wrote; a file with nothing of den's in it is left byte-identical. A settings
  file is rewritten through a new copy that replaces it in one step, so a
  write that fails part-way leaves it as it was; the copy takes the file's
  owner, group and permissions (and, on Linux, its extended attributes and
  ACLs), and a file with a second hard link is left as it is and named for
  you to edit by hand (exit 1). The workspace-relative paths must stay in the
  workspace: a symlinked `.claude`, `.github`, `.clinerules` or config file is
  refused (exit 1), so a checked-out repo cannot redirect the removal into
  your own settings; an explicit `--config PATH` is taken as given.

  cline loads every `.clinerules/*.md` as an always-on rule, so den's stale
  imprint and memory copies there keep reaching the model until they go.
  Each goes only when it starts with den's `<!-- den-managed` header; a file
  under one of those names that does not is left as it is and named. A
  regular file at `.clinerules` (cline's single-file rules) means cline-cli
  was never installed there, and is left alone.

`den uninstall hook` never creates `.den/` and does not touch what is in it:
`.den/imprint.md`, `.den/memory.md` and `.den/history/` are yours to delete,
and `.den/board/` belongs to `den board`.

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
Files reach both tools after `--`, and a name starting with `@` as `./@name`,
so a file named like an option (`--output-file=x.py`, which a `*.py` glob can
expand to) or like a response file (`@x.py`) is checked as a file, never read
as more arguments.
Python only; for other languages the coding and code-audit skills name each language's standard tools.

## Architecture

`cli.py` is the dispatcher; each command is a sibling `_xxx.py` module
(`_board`, `_hook`, `_install`, `_uninstall`, `_upgrade`, `_verify`) with a
`main(argv)`
entry point and relative imports (`_shell`/`_ui` are shared helpers, and
`_fsafe` holds the symlink guard and the guarded reads and writes).
`_content.py`
locates bundled content (wheel `den/_data/`, or the repo root from a checkout).
`_hook` keeps one remover per format an older den installed (`settings_json`,
`copilot_json`, `cline_scripts`, `clinerules`) and the `den hook run` no-op;
`den install` is one cross-platform implementation of the skill and
shell-environment installers.

## Tests

```
python3 -m pytest tests/den     # cli, hook, install, uninstall, shell, board
```

CI runs these alongside `ruff check agents den tests hatch_build.py` and a `packaging` job
that builds the wheel and smoke-tests a sourceless install.
