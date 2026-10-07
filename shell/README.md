# shell

The interactive shell environment: one POSIX-first configuration for bash and
zsh, a PowerShell port, and a set of Windows CMD shims. It adds modern-tool
wrappers (with graceful fallback), navigation and file helpers, a Python/uv
workflow, parallel file operations, and CPU/GPU info in the starship prompt.

## Install

Deployed by the `den` CLI (see `../den/README.md`):

```
den install shell             # bash/zsh -> ~/.config/shell, PowerShell -> profile dir,
                              # starship, and (on Windows) cmd/Clink shims; wires rc files
den install shell --dry-run   # preview
den install shell --no-extras # skip the optional helper modules
```

It copies the config into `~/.config/shell/` (POSIX) or the `$PROFILE` dir
(PowerShell) and adds a source line to your `~/.bashrc` / `~/.zshrc`.

### zsh plugins

`init.zsh` uses zsh's own `compinit` plus two standalone plugins instead of a
framework like oh-my-zsh (the framework's theme is overridden by starship and
its git aliases duplicate `aliases.sh`, so it was dead weight):

- [`zsh-autosuggestions`](https://github.com/zsh-users/zsh-autosuggestions) --
  the fish-style grey suggestion as you type.
- [`zsh-syntax-highlighting`](https://github.com/zsh-users/zsh-syntax-highlighting)
  -- colors the command line as you type (sourced last, as it requires).

`den install shell --zsh-plugins` clones them into `~/.config/zsh/plugins/`,
pinned to reviewed release commits (v0.7.1 / 0.8.0): the clone checks out the
release tag and is deleted if HEAD does not match the pinned commit. Without
the flag nothing is fetched -- code sourced at shell startup is opt-in.
Pre-existing clones are left untouched (the pin applies to new clones only).
`init.zsh` guards each source, so a missing plugin just turns that feature off.

## The wrapper system

Commands like `ls`, `cat`, `grep`, `find` dispatch through tiers, in order:

1. **modern** tool if installed (`lsd`, `bat`, `rg`, `fd`),
2. else **microsoft/coreutils** on Windows when installed (one multi-call binary
   that provides the Unix commands),
3. else the **native** command (`ls`/`cat`/`grep`/`find`, including the GNU tools
   from Git for Windows when present). The exception is names whose Windows
   System32 namesake behaves differently: those skip the native lookup on Windows
   so it never resolves to the DOS command. Of the wrapped commands that is only
   `find`; the skip list (`find`, `sort`, `more`) reserves the other two for any
   future wrapper with the same collision,
4. else a **PowerShell fallback** (Windows, when none of the above is present).

| Command | modern | native | notes |
|---------|--------|--------|-------|
| `ls` `la` `ll` `lla` | `lsd` | `ls` | listing |
| `lt` `llt` | `lsd --tree` | - | tree view |
| `cat` | `bat` | `cat` | |
| `grep` | `rg` | `grep` | |
| `find` | `fd` | `find` | |

On Windows the pwsh side also routes the no-modern-tool commands through
microsoft/coreutils when it is installed: `head`, `tail`, `wc`, `touch`,
`split`, `df`, `env`, and the destructive `cp`, `mv`, `rm`, `mkdir`, `rmdir`
(each falls back to the PowerShell builtin when coreutils is absent, with the
same arguments and piped input, so `Get-ChildItem *.log | rm` works as with the
stock alias). Install it with `den install shell
--coreutils` (or answer yes when `den install shell` asks; it is admin/all-user
only). microsoft/coreutils also inlines a `PSConsoleHostReadLine` rewriter into
your PowerShell profile that retargets typed `ls`/`cat`/... to coreutils before
the wrappers run, which would defeat the modern-first order; `den install shell`
removes that block (backing the profile up to `<profile>.den.bak` first, and
keeping the binary to drive through the tier above), so re-run `den install shell`
after updating coreutils if the block comes back. The
wrappers resolve the binary at its fixed install path
`%ProgramFiles%\coreutils\coreutils.exe` (the installer does not add it to PATH);
point them elsewhere with `_DEN_COREUTILS=<path>`, or disable the tier with
`_DEN_COREUTILS=0`. The tier is Windows + pwsh 7 only (Windows PowerShell 5.1
skips it); on Linux/macOS these commands keep their native / PowerShell-builtin
behavior, and den does not define `head`, `tail`, `wc`, `touch`, `split`, `df`,
`env` or `which` there at all.

On PowerShell, a den command that took over a name the session already had
(`ls`, `cat`, `grep`, `cd`, `rm`, `gc`, `python`, ...) is den's only when typed
at the prompt. A script, a module, a function or a script block run from the
session gets what the name meant before den loaded, with the same arguments and
pipeline input: on Windows a script's `ls dist | Remove-Item` gets
`Get-ChildItem`'s objects, and its `rm -Recurse` is `Remove-Item`'s. Names den
adds, such as `ll`, `la`, `lt` and the w-suffix wrappers, work in scripts too
(COMMANDS.md, "How to read this").

Piped input reaches the tool a wrapper picks as it arrives. At the end of a line
typed at the prompt the tool writes to the console itself, as when it runs bare:
`Get-Content -Wait log | grep x` prints each match as rg finds it, in rg's
colors. Further down a line, PowerShell passes on what the tool printed as it
does for any program, when the next object goes in and at the end. With nothing
piped in, the tool's stdin stays the console's. On PowerShell 7.3 and later, a
line that stops early (`| Select-Object -First 1`, or a host's stop) also ends
the tool; Windows PowerShell 5.1 and pwsh 7.0 to 7.2 have no clean block, so
there a line that a host stops while the tool waits for input can leave the tool
running until PowerShell exits.

Because the modern tools take different flags and produce different output than
the native commands, a command written for the native tool can misbehave when a
wrapper substitutes the modern one. To make that visible, a dim notice prints on
**every** wrapped call that runs the modern tool:

```
[den] ls -> lsd  (native: command ls, off: tgl-wr)
```

`native:` is the native command for a one-off call (it keeps the wrapper's own
fallback flags, e.g. `command ls -A` for `la`, minus presentation-only ones such
as `--color=auto`, and is left out when
the wrapper has no native equivalent); `off:` turns the wrappers off for the
session (`tgl-wr` is short for `toggle-wrapper`). PowerShell prints only the
second hint: `[den] ls -> lsd  (off: tgl-wr)`.

One difference is easy to miss when you are vetting code you did not write: `rg`
and `fd` honor a repository's own `.gitignore`, `.ignore`, `.rgignore` and
`.fdignore` files and skip hidden paths, so anything an untrusted checkout lists
there is silently absent from your `grep` and `find` results. Reach for
`command grep` / `command find` (or `export _DEN_WRAPPERS=0`) when auditing such
a tree, or pass the tools' own overrides, `rg --no-ignore --hidden` and
`fd --no-ignore --hidden`.

Ways to get the native command:

- **One-off (POSIX):** prefix `command`, e.g. `command ls -la --color=never`.
  This bypasses the wrapper for that single call.
- **This session:** run `toggle-wrapper` or its short name `tgl-wr` (flips
  `_DEN_WRAPPERS`), or `export _DEN_WRAPPERS=0` (PowerShell:
  `$env:_DEN_WRAPPERS = '0'`).
- **Silence the notice** (without changing behavior): `_DEN_WRAPPER_LOG=0`.

The `w`-suffix forms (`catw`, `findw`, `grepw`, `lsw`) always use the modern
tool, ignoring the toggle, and print no notice.

On bash/zsh a wrapper that replaces a native command (`ls`, `cat`, `grep`,
`find`) runs the modern tool only when typed at the prompt (`eval` and `$(...)`
typed there, a line a typed `again` replays, and a snippet a typed `snippet
run` or `snippet pick` runs count as typed). Run by a function, your own
included, or by a sourced file, it runs the native command that code was
written for, and den's `cd` is `builtin cd` there too. A function that relied
on such a wrapper now gets the native tool; call the modern tool by name or
through its `w`-suffix form. den's own names (`la`, `ll`, `lla`, `lt`, `llt`,
`ripgrep`) replace nothing and stay modern anywhere. The check is bash's
`FUNCNAME` / zsh's `funcstack` call stack (`_den_typed` in `_helpers.sh`).

On PowerShell, piping objects into a wrapper that resolves to a modern tool,
microsoft/coreutils, or a native exe (e.g. `Get-ChildItem | wc -l`) sends the
formatted text representation of those objects, not the objects themselves, so
counts and matches reflect the rendered output. Use file arguments, or the
native PowerShell cmdlets, when you need object-accurate results.

## Command reference

### Navigation
| Command | What it does |
|---------|--------------|
| `cd` | zoxide jump when wrappers are ON, `builtin cd` when OFF; zoxide only for a `cd` typed at the prompt (on bash/zsh, and with no option) |
| `cdi` | zoxide interactive pick |
| `zd` / `zdi` | always zoxide (ignore the toggle) |
| `back [N]` / `fwd [N]` | go N entries back / forward in this session's directory history, browser-style (default 1) |
| `back -l` / `back -i` | list the history / pick an entry with fzf (no `-i` on cmd); see COMMANDS.md |
| `up [N]`, `.1`..`.9` | go up N directories (`..` = up 1; no `.1`..`.9` on pwsh, which reads `.1` as the number 0.1) |
| `mkcd DIR` | `mkdir -p` then `cd` |
| `cdf` | fuzzy-find a subdirectory and cd into it (needs `fd` + `fzf`) |
| `c` | clear the screen |

### Files
| Command | What it does |
|---------|--------------|
| `dg [ALGO] FILE...` | hash files; ALGO is md5/sha256/sha512 or 5/256/512, default sha256 (several: hash and name per line) |
| `dg [ALGO] FILE HASH` | check FILE against an expected hash (the algo follows the hash's length) |
| `dg -e [ALGO] A B` | do A and B have the same content? |
| `dg -c SUMSFILE...` | verify checksum files, GNU or BSD lines, like `sha256sum -c` |
| `digest ...` | the older name of `dg`, same forms |
| `mkfile SIZE PATH` | create a dummy file (e.g. `mkfile 10M test.bin`) |
| `extract ARCHIVE...` / `xt` | auto-detect and extract each archive; a failure is reported and the rest still run (exit 1 if any failed). Formats: tar.gz/tgz, tar.bz2/tbz2, tar.xz/txz, tar.zst/tzst, tar, zip, 7z, rar; single file: gz, bz2, xz, zst |
| `archive OUT FILES...` / `pk` | create an archive (format from `OUT` extension); every argument after `OUT` is a source, never an option. Formats: tar.gz/tgz, tar.bz2/tbz2, tar.xz/txz, tar.zst/tzst, tar, zip, 7z; single file: gz, bz2, xz, zst (one source) |
| `y` | yazi file manager (returns you to the dir you exit in) |
| `again [N]` / `sagain` | re-run the Nth previous command (`sagain` = with sudo) |

### Python / uv
| Command | What it does |
|---------|--------------|
| `py` `python` `python3` | `uv run python` (uses the active venv's version) |
| `pip` `pip3` | `uv pip` (an active venv's own pip when it has one) |
| `uv` | injects `--python` for `uv run` when a venv is active |
| `va [DIR]` | activate a venv (default `.venv`) |
| `vd` | deactivate |
| `vv` / `vva` | `uv venv` (create / create + activate) |
| `toggle-uv` / `tgl-uv` | flip the uv override (`_DEN_UV_OVERRIDE`) |

### Parallel file ops
| Command | What it does |
|---------|--------------|
| `pcp` `pmv` | parallel copy / move (last arg is the destination) |
| `prm` | parallel remove (interactive confirm by default) |
| `ptar` | parallel compress (`pigz`/`pbzip2`/`pxz` when available) |
| `pxargs` | `xargs` with parallel jobs (POSIX shells only) |

Backed by GNU `parallel` when present, otherwise `xargs -P`. `pcp`/`pmv`/`prm`/
`ptar` exist in bash/zsh and PowerShell (cmd has no parallel file ops); `pxargs`
is bash/zsh only.

### System / editor
| Command | What it does |
|---------|--------------|
| `path` | print PATH entries one per line |
| `ports` | listening TCP ports with the owning process |
| `code` | `code-insiders`, falling back to `code` |
| `gu` | gitui (terminal git UI) |
| `g`, `ga`, `gc`, `gco`, ... | git aliases (see `posix/aliases.sh`) |

PowerShell additionally provides `df`, `env`, `head`, `tail`, `wc`, `which`,
`touch`, `split` as functions (these are native on Unix). Media helpers live in
`posix/ffmpeg.sh` / `pwsh/ffmpeg.ps1` (e.g. `strip-audio`); see those files.

### Proxy profiles
| Command | What it does |
|---------|--------------|
| `proxy add <name> <url> [no_proxy]` | register / overwrite a named profile |
| `proxy rm <name>` | remove a profile |
| `proxy ls` | list profiles (`*` marks the one active in this shell) |
| `proxy on <name>` | export `http(s)_proxy` / `all_proxy` / `no_proxy` (lower + upper case) from the profile |
| `proxy off` | unset those env vars |
| `proxy` / `proxy status` | show the active profile and current values |

Profiles are stored in `$XDG_CONFIG_HOME/den/proxy.conf`. `on` / `off` only set
or clear environment variables in the **current shell** (no global tool config
such as `~/.gitconfig` is touched), so the active profile is tracked per-shell
in `_DEN_PROXY_ACTIVE` and never disagrees with another shell. bash/zsh and
PowerShell (a machine's pwsh and bash share the profile store).
`localhost,127.0.0.1,::1` are always excluded; a profile's own `no_proxy`
entries (comma-separated, e.g. `.corp.example.com,10.0.0.0/8`) are added on top.
The one exception is `no_proxy = *`, which stays standalone (bypass everything).

A url may carry a password (`http://user:password@host:port`). `add`, `on`,
`ls` and `status` print it as `user:***@host:port`; `proxy.conf` and the
exported variables keep the real value. On Linux and macOS `proxy.conf` is
`0600` and `$XDG_CONFIG_HOME/den` `0700`, whatever the umask: each write sets
them, so a store an older den left readable is tightened too. A `proxy.conf`
that is a symlink stays one: `add` and `rm` write through it in both shells.

The line that typed such a url (`proxy add corp http://al:S3cr3t@p.corp:8080`)
stays out of the shell's history file; a `proxy add` line without a password
is saved as usual. den finds the line by its text, with the quotes left out:
the word `proxy` (not part of a name or a path such as `~/proxy`, `myproxy` or
`$wc.Proxy`; on pwsh in upper or lower case), blanks, the word `add`, and
after it a `:` before the last `@` once each `://` is taken out. So on zsh and
pwsh a line that only looks like one (`echo proxy add c http://al:pw@p`) is
left out too, and in every shell `proxy add` behind an alias is not seen. den
changes no history setting, so the ones in effect still apply: `HISTIGNORE` /
`HISTCONTROL` (init.bash sets both as it loads, so a value set before it is
replaced), `HISTORY_IGNORE` and a `zshaddhistory` of your own, and an
`AddToHistoryHandler` set before init.ps1 (den's handler chains to it, and a
line it leaves out stays out).

- **bash**: `proxy add` takes the line out of the history list (`history -d`)
  before bash writes `$HISTFILE` (at exit, or from a `history -a` in
  `PROMPT_COMMAND`). In a subshell (a pipe, `$(...)`) it cannot: it prints the
  `history -d N` that takes the line out of the list, and a history file
  written after each command (`history -a` in `PROMPT_COMMAND`) has the line
  by then, so take it out of that file by hand. A setup that writes the
  history before a command runs (`history -a` in `PS0` or a DEBUG trap) has
  written the line already, and with `shopt -u cmdhist` a `proxy add` inside a
  command of several lines is not found (each line is an entry of its own, and
  the last one is not it).
- **zsh**: a `zshaddhistory` hook (added with `add-zsh-hook`, next to yours)
  does not save the line; it can still be recalled until the next line runs.
  The hook answers 1, not 2 (memory only), because `fc -W`, which `reload`
  runs, and `fc -A` write a line kept in memory only to the file.
- **pwsh**: init.ps1's history handler keeps the line in PSReadLine's memory
  only (`MemoryOnly`, PSReadLine 2.2+), so it can be recalled in this session;
  PSReadLine 2.0 (Windows PowerShell 5.1's) has no such answer, and there the
  line is not kept at all.

### Command snippets
Save favorite commands by name and run them later, instead of `history | grep`.

| Command | What it does |
|---------|--------------|
| `snippet save <name> '<command>'` | save a command exactly as typed (or pipe it via stdin, first line only); alias `snip` |
| `snippet save <name> <word...>` | save the words, each quoted again if it needs it, and print the saved line |
| `snippet ls` | list saved snippets |
| `snippet show <name>` | print a snippet's command (no run) |
| `snippet run <name>` | run a snippet |
| `snippet rm <name>` | delete a snippet |
| `snippet pick` / `snippet` | fzf-select a snippet and run it |

Snippets are stored in `$XDG_CONFIG_HOME/den/snippets` (`name<TAB>command`; the
name is `[A-Za-z0-9_-]`, the command may contain anything on one line). `run` and
`pick` echo the command, then `eval` it in the **current shell** (you saved it,
so it is trusted), which lets it `cd`, set vars, and use the current environment.
`pick` needs `fzf`; without it, use `snippet run <name>`. bash/zsh and PowerShell
(a machine's pwsh and bash share the snippet store).

`save` takes the command in one of these forms:
- **One argument** (`snippet save cnt 'grep -c ">" seqs.fa | tee n.txt'`) or
  **stdin** (`echo 'make -j8 test' | snippet save t`): stored exactly as given.
  A snippet is one line: from stdin `save` reads only the first line and drops
  the rest, and it refuses one argument that holds a newline. This is the form
  for pipes, redirections, `;` and `&&`.
- **Several words** (`snippet save clean rm "My File.txt"`): the shell has
  already taken the quotes off each word, so `save` puts single quotes back
  around each word that holds a blank or a character the shell would read
  (`$ ; | & > < ' " * ? ~`, ...) and prints the line it saved
  (`snippet: saved 'clean' -> rm 'My File.txt'`); `run` then sees the same
  words. bash/zsh write a `'` inside as `'\''`, pwsh as `''`. pwsh hands
  `snippet` values, not text: a first word that needs quotes is saved as
  `& '<path>'`, so it still runs as a command; a quoted word that starts like
  a number (`'007'`, `'1kb'`) or with a dash (`'-Verbose'`, `'--'`) stays a
  string, while a parameter typed bare (`-Recurse`) is saved bare (pwsh takes
  a bare `--` itself, so it never reaches `save`: quote it); `$true`,
  `$false`, a `{ ... }` block and a list `a,b` come back as they were; any
  other value (a hashtable, say) is saved as its text. A `$var` or `$(...)`
  you did not quote was expanded by the shell before `snippet` ran, so the
  saved line holds its value from that moment, and one you quoted is saved as
  literal text. bash/zsh do the same with a glob (`*.txt`) or `~` you did not
  quote, against the files there at that moment (a glob that matches nothing
  reaches `save` as is in bash, and is saved quoted). pwsh leaves globs and
  `~` to the command it runs, so they reach `save` as typed and are saved
  quoted like the other characters above: on pwsh `snippet save l ls *.txt`
  saves `ls '*.txt'`, which looks for a file named `*.txt` when it runs. To
  have any of these expanded each time the snippet runs, use the one-argument
  form (`snippet save h 'echo $HOME'`, `snippet save l 'ls *.txt'`).

The store is shared, but a snippet is saved in the syntax of the shell that
saved it, so one saved in bash/zsh may not run in pwsh, or the other way round.
On Linux and macOS the store is `0600` in a `0700` `$XDG_CONFIG_HOME/den`, like
`proxy.conf` (a saved command may hold a token). A store that is a symlink, into
a dotfiles repo say, stays one: `save` and `rm` write through it in both shells.

### Cheatsheets
Browse den's bundled cheatsheets offline. Deploy them first with
`den install cheatsheets`.

| Command | What it does |
|---------|--------------|
| `cheat` | fzf-pick a cheatsheet and render it (needs `fzf`) |
| `cheat ls` | list available cheatsheets |
| `cheat <name>` | render the cheatsheet whose path matches `<name>` (fzf-picks when several match) |

Cheatsheets live under `$XDG_DATA_HOME/den/cheatsheets` (default
`~/.local/share/den/cheatsheets`), rendered with `bat` when available, else
`cat`. The `<sheet>.den.bak` (and `.den.bak.N`) copies `den install
cheatsheets --force` keeps of sheets it replaced are not listed; any other
name is. bash/zsh and PowerShell.

## Hardware info in the prompt

The starship prompt shows your CPU and GPU. `hwinfo.sh` detects them once and
exports `STARSHIP_CPU_*` / `STARSHIP_GPU_*`.

- Detection is cached **machine-locally and per-boot**: POSIX writes
  `$XDG_RUNTIME_DIR/den-hwinfo.<machine-id>.sh` (mode 600); PowerShell
  caches under LocalAppData keyed by `$COMPUTERNAME`. This keeps a shared or
  synced `$HOME` from showing one machine's hardware on another.
- `toggle-hwinfo` (short: `tgl-hw`) shows/hides the info in the prompt.
- `refresh-hwinfo` clears the cache so the next shell re-detects.

## Tab completion (pwsh)

`completion.ps1` brings bash-like Tab completion to PowerShell (pwsh only; an
extra, installed with `den install shell`):

- **Tab shows a menu** (`Set-PSReadLineKeyHandler -Key Tab MenuComplete`), like
  the zsh menu-select on Linux, for everything PowerShell completes natively
  (cmdlets, parameters, paths, module argument completers).
- **Per-tool completers** for `docker`, `gh`, `uv`, `rustup`: each tool's
  generated PowerShell completion script (the subcommand varies per tool) is
  cached under LocalAppData (via the shared `Initialize-Cache`, validated by
  `Test-CacheSafe`) and sourced, so `docker run <Tab>` etc. complete. Each is
  skipped when the tool is absent.
- **git** branch/remote completion comes from `posh-git`, but only when it is
  already installed (it is a heavy module, so it is never force-installed or
  imported when absent).

Add a tool by dropping one
`$_c = Initialize-Cache '<tool>' @('completion', 'powershell') 'completion'; if ($_c) { . $_c }`
line in `completion.ps1` (adjust the subcommand: `gh` uses `completion -s`, `uv`
uses `generate-shell-completion`, `rustup` uses `completions`). The dot-source
must stay at the file's top level (global scope), not inside a function, or some
completers (docker's) silently fail. Note that the completers are sourced eagerly
at startup, so a very large one (e.g. `kubectl`, `helm`) adds measurable startup
time each session.

## Layout

```
shell/
  posix/       core config for bash/zsh (sh-compatible)
    _helpers.sh   wrapper generator (_wrap), PATH, cache init, toggle-wrapper/tgl-wr
    wrappers.sh   the ls/cat/grep/find wrapper definitions
    functions.sh  file/navigation/history utilities
    aliases.sh    navigation / git / docker aliases
    python.sh     uv + venv workflow
    parallel.sh   pcp/pmv/prm/ptar
    ffmpeg.sh     media helpers
    hwinfo.sh     CPU/GPU detection for the prompt
    bin/          standalone POSIX executables (fixids: fast, filtered,
                  parallel chown -- a faster fixuid; self-documented, -h)
  pwsh/        PowerShell port (init.ps1 entry; coreutils.ps1 reimplements UNIX tools)
  cmd/         Windows CMD command shims (cmd/bin/*.cmd) + starship.lua
  bash/init.bash   entry point sourced from ~/.bashrc
  zsh/init.zsh     entry point sourced from ~/.zshrc
  starship/starship.toml   prompt configuration
```

`shell/posix/bin/` holds standalone executables (not sourced config).
`den install shell` offers to copy them to `~/.local/bin` (already on PATH via
`_init_path`): pass `--bin` to install without asking, `--no-bin` to skip, or
answer the y/N prompt on an interactive POSIX run (default no). They need GNU
coreutils/findutils and are never installed on Windows. `den uninstall shell`
removes them (keeping any you modified, and never deleting `~/.local/bin`
itself).

## Load flow and caches

`~/.bashrc` -> `init.bash` -> `_helpers.sh` -> `_init_path` -> `_source_all`
(wrappers, functions, aliases, hwinfo, python, ffmpeg, parallel) -> cached init
of zoxide and starship. zsh and PowerShell mirror this.

- `~/.cache/shell/` holds the zoxide/starship init caches. They regenerate when
  the tool binary is newer than the cache, and are sourced only if they are a
  regular file owned by you (symlink and owner guarded).
- `reload` clears the caches and restarts the shell, which rebuilds them.
  bash/zsh `exec` a new shell. pwsh cannot, so it starts the same pwsh with
  the same launch arguments (less `-WorkingDirectory`: it stays in the current
  directory), waits for it, and exits with its exit code; each reload nests one
  more pwsh process, up to 8 in a row (see `COMMANDS.md`).

## Toggles and environment

| Variable | Effect |
|----------|--------|
| `_DEN_WRAPPERS=0` | use native commands instead of modern tools |
| `_DEN_WRAPPER_LOG=0` | silence the wrapper notice (printed on every wrapped call that runs the modern tool) |
| `_DEN_COREUTILS=<path>` | use a specific microsoft/coreutils binary, e.g. `C:\Program Files\coreutils\coreutils.exe` (Windows) |
| `_DEN_COREUTILS=0` | disable the microsoft/coreutils tier (Windows) |
| `_DEN_UV_OVERRIDE` | uv python/pip override state (via `toggle-uv` / `tgl-uv`); a shell started with `0` loads no override |
| `_DEN_HWINFO_HIDDEN` | hardware info hidden in the prompt (via `toggle-hwinfo` / `tgl-hw`); a shell started with `1` keeps it hidden |
