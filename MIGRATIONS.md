# Migrations: what den leaves behind

`den uninstall` is stateless by design. It re-derives what the CURRENT
version installs and removes only the files that are byte-identical to it,
so your edits survive. The cost of that design: when den stops deploying
something (a retired tool, a renamed skill, a deleted script), the old copy
is no longer anything den knows about, and no den command will ever remove
it.

This file is the list of those leftovers. Nothing here is urgent - the
files are inert, not harmful - except where a note says otherwise. Run the
cleanup once per machine that has been running den for a while.

Check what a machine actually has before deleting. The `sh` recipes here
call `command find`: typed at a den prompt, `find` runs `fd`, which takes
none of these arguments.

```sh
ls -d ~/.gemini/skills ~/.cline/skills 2>/dev/null
ls -d ~/.claude/skills/code-review ~/.agents/skills/code-review \
      ~/.copilot/skills/code-review ~/.codex/skills/code-review 2>/dev/null
command find ~/.claude/skills ~/.agents/skills ~/.copilot/skills ~/.codex/skills \
             \( -name verify-imports.py -o -name doc-coverage.py \) 2>/dev/null
ls -d ~/.claude/skills/translate ~/.agents/skills/translate \
      ~/.copilot/skills/translate ~/.codex/skills/translate 2>/dev/null
command find ~/.claude/skills ~/.agents/skills ~/.copilot/skills ~/.codex/skills \
             \( -name go.md -o -name java.md -o -name csharp.md \) 2>/dev/null
```

On Windows, also check for the cmd shim that section 8 deletes:

```bat
dir "%LOCALAPPDATA%\clink\bin\find.cmd"
```

```powershell
Test-Path "$env:LOCALAPPDATA\clink\bin\find.cmd"
```

## 1. `code-review` renamed to `code-audit` (2026-08, #57)

The skill was renamed because `code-review` collided with Claude Code's
own `/code-review`, and den's skill won: typing the command loaded den's
five-dimension procedure instead of the built-in multi-agent review.

**This one matters more than the others**: leaving the old directory in
place keeps the collision alive, so the rename buys nothing until it is
removed.

```sh
rm -rf ~/.claude/skills/code-review ~/.agents/skills/code-review \
       ~/.copilot/skills/code-review ~/.codex/skills/code-review
```

```powershell
Remove-Item -Recurse -Force ~/.claude/skills/code-review, `
  ~/.agents/skills/code-review, ~/.copilot/skills/code-review, `
  ~/.codex/skills/code-review -ErrorAction SilentlyContinue
```

Codex additionally registers each skill by PATH, so its `config.toml`
still points at the old file. Re-print the block and replace the
`[[skills.config]]` section in `~/.codex/config.toml`:

```sh
den install skills --target ~/.codex --codex-config
```

## 2. gemini retired (2026-07, #52)

gemini-cli hit upstream end-of-life for individual accounts; its
successor reads the cross-tool `~/.agents/skills` that den already
deploys, so the gemini entry was removed from den entirely.

```sh
rm -rf ~/.gemini/skills          # skills only; GEMINI.md is yours to keep
```

`den uninstall skills` still sweeps this one for now, because the sweep
was added in #52 before the entry was dropped. Do not rely on it after
that sweep is eventually removed.

## 3. cline skills moved to `~/.agents/skills` (2026-06)

den used to deploy cline's skills to `~/.cline/skills` as well. That
double-loaded in the VS Code extension, so deployment moved to
`~/.agents/skills` only. Anything still under `~/.cline/skills` is a
pre-move copy and will be stale.

```sh
rm -rf ~/.cline/skills
```

## 4. The AST verifier scripts (2026-07, #45)

`verify-imports.py` and `doc-coverage.py` were replaced by standard tools
(`ty` resolves imports; ruff's docstring rules cover the doc check) and
deleted from the repository. Every skill deployed before that still
carries them under its own `shared/scripts/`.

```sh
command find ~/.claude/skills ~/.agents/skills ~/.copilot/skills ~/.codex/skills \
             \( -name verify-imports.py -o -name doc-coverage.py \) -delete
```

## 5. translate retired; Go / Java / C# references dropped (2026-08, #64)

Removed because the owner named their languages - Python (primary), Rust
(aspirational), and the shells - and has no translation work. That call,
not any property of this repository, is the criterion: the skills are
global, so what den's own tree happens to contain proves nothing either
way. (TypeScript stays, by the owner's explicit call.)
The `translate` skill and the three language references (plus their coding
examples) were removed; the translation rules survive as
`agents/src/shared/reference/translation.md`, a repo-only note that no skill
references, so it is never deployed.

Update (2026-10): translation is back as documenter's translate mode
(natural Japanese/English translation of documents), so
`shared/reference/translation.md` now deploys with documenter, under
`<skills dir>/documenter/shared/reference/`. The cleanup below still
applies: its `translate` paths are the old skill's directories, and no
command in it touches documenter's copy.

Deployed machines keep the old copies:

```sh
rm -rf ~/.claude/skills/translate ~/.agents/skills/translate \
       ~/.copilot/skills/translate ~/.codex/skills/translate
command find ~/.claude/skills ~/.agents/skills ~/.copilot/skills ~/.codex/skills \
             \( -name go.md -o -name java.md -o -name csharp.md \) -delete
```

Codex registers skills by path, so also re-print and replace the
`[[skills.config]]` block (drops the translate entry):

```sh
den install skills --target ~/.codex --codex-config
```

```powershell
Remove-Item -Recurse -Force ~/.claude/skills/translate, `
  ~/.agents/skills/translate, ~/.copilot/skills/translate, `
  ~/.codex/skills/translate -ErrorAction SilentlyContinue
Get-ChildItem ~/.claude/skills, ~/.agents/skills, ~/.copilot/skills, `
  ~/.codex/skills -Recurse -Include go.md, java.md, csharp.md | Remove-Item
```

## 6. claude hooks moved to `.claude/settings.local.json` (2026-10)

den used to write its claude hook commands, which pin this machine's
absolute `.den` path, into the committed `.claude/settings.json`. They then
went to Claude Code's personal `.claude/settings.local.json`. Since
section 9, den installs no hooks at all, so there is nothing to move them
to: `den uninstall hook --tool claude` takes den's entries out of both
files, and leaves everything else in them.

## 7. `clip` renamed to `mclip` (2026-10)

den's video cutter was named `clip`, which is also Windows' clipboard
command (`clip.exe`): in pwsh and Git Bash, a typed `... | clip` ran the
cutter and copied nothing. It is `mclip` now, on bash/zsh and pwsh, with the
same arguments, and `clip` is the system's again. Type `mclip` where you
typed `clip` to cut a video. Nothing is left on disk, but a shell that loaded
the older den keeps its `clip` until you replace it (a new terminal,
`exec "$SHELL"` on bash/zsh, `reload` on pwsh).

## 8. cmd's `find` is `find.exe` again; `fd` is `findw` (2026-10)

On cmd, `find` was an alias for den's `find.cmd`, which ran `fd` whenever it
was installed, after a `|` too, where `fd` ignores the piped text:
`netstat -ano | find "8080"` looked for file names instead and, with none
matching, printed nothing and exited 0. Typed `find` is Windows' `find.exe`
again, and `fd` is `findw`, as on the other shells: type `findw` where you
meant `fd`. A cmd window opened before the update keeps the old alias until
you close it.

The old shim stays in Clink's shim folder, where no alias reaches it:

```bat
del "%LOCALAPPDATA%\clink\bin\find.cmd"
```

```powershell
Remove-Item "$env:LOCALAPPDATA\clink\bin\find.cmd" -ErrorAction SilentlyContinue
```

## 9. `den memory` and the per-turn hook removed (2026-11)

den kept a workspace memory (`.den/memory.md`, with snapshots in
`.den/history/`) and installed per-turn hooks that put it, with
`.den/imprint.md`, in front of the model every turn. The agent tools keep a
memory of their own now, Cline among them, so both were removed:
`den memory` and `den hook memory`, `den install hook` (`den hook install`),
`den hook list`, `den hook imprint` and `den hook remove`. Each of these
now prints one line saying so, naming this file, and exits 1.

Two commands still run, so that old installs keep working while you clean
up:

- `den hook run`, which every installed hook calls, is a no-op: it reads
  nothing, writes nothing, and gives each tool its empty answer, so a hook
  still in place neither fails nor blocks a session. Nothing reaches the
  model through it any more.
- `den uninstall hook` takes those hooks out.

Both stay for now; a later den may drop them.

Left behind in each workspace where you ran `den install hook`:

- den's entries in `.claude/settings.local.json` (or, from older dens,
  `.claude/settings.json`) and `.github/hooks/den.json`, and its scripts in
  `.clinerules/hooks/`;
- for cline-cli, `.clinerules/den-imprint.md` and `.clinerules/den-memory.md`.
  **These matter more than the rest**: cline loads every `.clinerules/*.md`
  as an always-on rule, so the old imprint and memory keep reaching the
  model, and the imprint keeps telling it to run `den hook memory add`, which
  now fails;
- `.den/imprint.md`, `.den/memory.md` and `.den/history/`, which den no
  longer reads or writes;
- the `/.claude/settings.local.json` line den added to the repository's
  `.git/info/exclude`. It only keeps an untracked file out of git; leave it
  or delete it.

den keeps no list of those workspaces. This names every file den wrote
there, under the directory where you keep your projects (`~/src` here
stands for it):

```sh
command find ~/src \( -path '*/.claude/settings*.json' -o -path '*/.github/hooks/den.json' \
                     -o -path '*/.clinerules/*' \) -type f \
     -exec grep -l -e 'den hook run' -e '^<!-- den-managed' {} + 2>/dev/null
```

```powershell
Get-ChildItem ~/src -Recurse -Force -File -ErrorAction SilentlyContinue |
  Where-Object FullName -Match '[\\/](\.claude[\\/]settings(\.local)?\.json|\.github[\\/]hooks[\\/]den\.json|\.clinerules[\\/].+)$' |
  Select-String -List -Pattern 'den hook run', '^<!-- den-managed' |
  ForEach-Object Path
```

Run `den uninstall hook` in each directory that holds a `.claude`, `.github`
or `.clinerules` the list names. That directory is not always the one with
the `.den`: an install in a subdirectory wrote its hook config there but
used the nearest `.den` above it, and cline-cli's two files sit beside that
`.den`.

Then delete `.den` itself, by hand, in each place that has one. den reads
and writes nothing under `.den/` any more (section 10 removed `den board`,
the last command that did), and it deletes nothing there either. Where you
installed hooks, do it only after `den uninstall hook` has run: that command
looks for cline-cli's two files beside the nearest `.den`, so with `.den`
gone, a run from a subdirectory looks in the wrong place. Look inside first:
a file you kept there yourself goes with it. The recipes stop at once when
`.den`, or anything in it, is a link (a symlink or a junction): what it
leads to is not den's, so look at it by hand. They delete only inside the
directory you name, and nothing at all when they cannot go there, so a
mistyped path never removes the `.den` of the folder you happen to be in.

```sh
command find ~/src -name .den -prune 2>/dev/null   # where they are
d='<the directory holding that .den>'
case $d in /*) ;; *) d="./$d" ;; esac              # so cd never looks in CDPATH
ls -AlR -- "$d/.den"                               # anything of yours in it?
(
  cd -- "$d" || exit 1
  if [ -n "$(command find .den -type l -print -quit)" ]; then
    echo "$d/.den is or holds a link: look at it by hand" >&2
  else
    rm -rf .den
  fi
)
```

```powershell
Get-ChildItem ~/src -Recurse -Force -Filter .den -ErrorAction SilentlyContinue |
  ForEach-Object FullName                          # where they are
$d = '<the directory holding that .den>'
Get-ChildItem -Force -Recurse -LiteralPath (Join-Path $d .den)   # anything of yours in it?
& {
  Push-Location -LiteralPath $d -ErrorAction Stop   # nothing below runs if this fails
  try {
    $link = @(Get-Item -Force -LiteralPath .den) + @(Get-ChildItem -Force -Recurse -LiteralPath .den) |
      Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }
    if ($link) {
      Write-Warning "$($link.FullName -join ', ') is a link: look at it by hand"
    } else {
      Remove-Item -Recurse -Force -LiteralPath .den
    }
  } finally {
    Pop-Location
  }
}
```

`den uninstall hook` leaves a file under `.clinerules/` named
`den-imprint.md` or `den-memory.md` that does not start with den's
`<!-- den-managed` header, and says so: it is not a file den wrote.

Two older shapes live outside that layout:

- dens before section 2 (2026-07) also installed gemini hooks in
  `.gemini/settings.json`. gemini-cli is end-of-life, so they never run;
  the file has claude's format, so this takes den's entries out of it:

  ```sh
  den uninstall hook --tool claude --config .gemini/settings.json
  ```

- the first dens (June 2026, before den was a package) wrote user-level
  files instead of workspace ones. Check whether any of them holds a
  `den hook run` line:

  ```sh
  command grep -rl 'den hook run' ~/.claude/settings.json ~/.gemini/settings.json \
                ~/.copilot/hooks/den.json ~/.cline/hooks 2>/dev/null
  ```

  ```powershell
  Select-String -List -Pattern 'den hook run' -ErrorAction SilentlyContinue `
    -Path ~/.claude/settings.json, ~/.gemini/settings.json, `
          ~/.copilot/hooks/den.json, ~/.cline/hooks/*
  ```

  and take den's entries out of each one it names:

  ```sh
  den uninstall hook --tool claude --config ~/.claude/settings.json
  den uninstall hook --tool claude --config ~/.gemini/settings.json
  den uninstall hook --tool copilot --config ~/.copilot/hooks/den.json
  den uninstall hook --tool cline --config ~/.cline/hooks
  ```

## 10. `den board` removed (2026-11)

`den board` served a page on localhost, one per project, where you filed
reports (a button press and a note) that an agent read from
`.den/board/reports.jsonl`; `den board task` and `den board reply` let the
agent write back. It was the one den command that ran a network server, and
it was removed. `den board`, with any arguments, now prints one line saying
so, naming this file, and exits 1. The troubleshoot skill no longer looks
for `.den/board/`.

Left behind in each project where you ran it: `.den/board/`, with
`board.json` (the page's title and buttons), `reports.jsonl` (your
reports), `agent.jsonl` (the agent's tasks and replies) and, after a server
that did not stop cleanly, `server.json`. den reads none of them now. Copy
`reports.jsonl` somewhere else if you want to keep the reports, then delete
`.den` as a whole, as section 9 says.

## 11. Agent CLIs, eza and broot left out of the dev image (2026-11)

`docker/ubuntu/Dockerfile` no longer installs the coding-agent CLIs (claude,
codex, grok, muse and agy), acpx with its Claude skill, bubblewrap, eza or
broot, and no longer runs
`den install skills --tool claude --tool codex --with-parent --force`. nvm
and Node stay.

A container you already have keeps what it started with. A container from a
rebuilt image has none of these tools, and its new `/home/dev` holds none of
the old container's agent logins and settings (`~/.claude`, `~/.claude.json`,
`~/.codex`). Copy those out with `docker cp` before you remove the old
container if you want to keep them. To get the tools back, build an image of
your own `FROM` den's and install them there, den's skills included, with
the command above in a `dev` step: `docker/README.md` shows how, under
"Adding your own tools". den's eza cheatsheet stays, for machines that have
eza.

## Why there is no `den prune`

Deliberate: a prune command needs a durable record of everything den has
ever installed, which is the stateful design `den uninstall` was written
to avoid, and it would be maintained for a user base of one. A file that
says what to delete, and when it appeared, costs nothing to keep correct.

When a future change orphans something, add a section here in the same
commit.
