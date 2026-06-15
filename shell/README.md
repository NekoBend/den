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

On a POSIX host with zsh + git, `den install shell` clones them into
`~/.config/zsh/plugins/` (clone-if-missing); pass `--no-zsh-plugins` to skip.
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
(each falls back to the PowerShell builtin when coreutils is absent, so the
no-coreutils baseline is unchanged). Install it with `den install shell
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
behavior.

Because the modern tools take different flags and produce different output than
the native commands, a command written for the native tool can misbehave when a
wrapper substitutes the modern one. To make that visible, a dim notice prints on
**every** wrapped call:

```
[den] ls -> lsd  | native one-off: command ls ...  | disable: run toggle-wrapper, or export _DEN_WRAPPERS=0
```

Ways to get the native command:

- **One-off (POSIX):** prefix `command`, e.g. `command ls -la --color=never`.
  This bypasses the wrapper for that single call.
- **This session:** run `toggle-wrapper` (flips `_DEN_WRAPPERS`), or
  `export _DEN_WRAPPERS=0` (PowerShell: `$env:_DEN_WRAPPERS = '0'`).
- **Silence the notice** (without changing behavior): `_DEN_WRAPPER_LOG=0`.

The `w`-suffix forms (`catw`, `findw`, `grepw`, `lsw`) always use the modern
tool, ignoring the toggle.

On PowerShell, piping objects into a wrapper that resolves to a modern tool,
microsoft/coreutils, or a native exe (e.g. `Get-ChildItem | wc -l`) sends the
formatted text representation of those objects, not the objects themselves, so
counts and matches reflect the rendered output. Use file arguments, or the
native PowerShell cmdlets, when you need object-accurate results.

## Command reference

### Navigation
| Command | What it does |
|---------|--------------|
| `cd` | zoxide jump when wrappers are ON, `builtin cd` when OFF |
| `cdi` | zoxide interactive pick |
| `zd` / `zdi` | always zoxide (ignore the toggle) |
| `back [N]` | go back to the Nth previous directory (default 1) |
| `up [N]`, `.1`..`.9` | go up N directories (`..` = up 1) |
| `mkcd DIR` | `mkdir -p` then `cd` |
| `cdf` | fuzzy-find a subdirectory and cd into it (needs `fd` + `fzf`) |
| `c` | clear the screen |

### Files
| Command | What it does |
|---------|--------------|
| `digest {md5\|sha256\|sha512} FILE` | hash a file |
| `mkfile SIZE PATH` | create a dummy file (e.g. `mkfile 10M test.bin`) |
| `extract ARCHIVE` | auto-detect and extract |
| `archive OUT FILES...` | create an archive (format from `OUT` extension) |
| `y` | yazi file manager (returns you to the dir you exit in) |
| `again [N]` / `sagain` | re-run the Nth previous command (`sagain` = with sudo) |

### Python / uv
| Command | What it does |
|---------|--------------|
| `py` `python` `python3` | `uv run python` (uses the active venv's version) |
| `pip` `pip3` | `uv pip` (bypassed inside an active venv) |
| `uv` | injects `--python` for `uv run` when a venv is active |
| `va [DIR]` | activate a venv (default `.venv`) |
| `vd` | deactivate |
| `vv` / `vva` | `uv venv` (create / create + activate) |
| `toggle-uv` | flip the uv override (`_DEN_UV_OVERRIDE`) |

### Parallel file ops
| Command | What it does |
|---------|--------------|
| `pcp` `pmv` | parallel copy / move (last arg is the destination) |
| `prm` | parallel remove (interactive confirm by default) |
| `ptar` | parallel compress (`pigz`/`pbzip2`/`pxz` when available) |
| `pxargs` | `xargs` with parallel jobs (POSIX shells only) |

Backed by GNU `parallel` when present, otherwise `xargs -P`. `pcp`/`pmv`/`prm`/
`ptar` exist in bash/zsh, PowerShell, and CMD; `pxargs` is bash/zsh only.

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
in `_DEN_PROXY_ACTIVE` and never disagrees with another shell. bash/zsh
only. `localhost,127.0.0.1,::1` are always excluded; a profile's own `no_proxy`
entries (comma-separated, e.g. `.corp.example.com,10.0.0.0/8`) are added on top.
The one exception is `no_proxy = *`, which stays standalone (bypass everything).

## Hardware info in the prompt

The starship prompt shows your CPU and GPU. `hwinfo.sh` detects them once and
exports `STARSHIP_CPU_*` / `STARSHIP_GPU_*`.

- Detection is cached **machine-locally and per-boot**: POSIX writes
  `$XDG_RUNTIME_DIR/den-hwinfo.<machine-id>.sh` (mode 600); PowerShell
  caches under LocalAppData keyed by `$COMPUTERNAME`. This keeps a shared or
  synced `$HOME` from showing one machine's hardware on another.
- `toggle-hwinfo` shows/hides the info in the prompt.
- `refresh-hwinfo` clears the cache so the next shell re-detects.

## Layout

```
shell/
  posix/       core config for bash/zsh (sh-compatible)
    _helpers.sh   wrapper generator (_wrap), PATH, cache init, toggle-wrapper
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
- `reload` rebuilds the caches and re-execs the shell.

## Toggles and environment

| Variable | Effect |
|----------|--------|
| `_DEN_WRAPPERS=0` | use native commands instead of modern tools |
| `_DEN_WRAPPER_LOG=0` | silence the one-time wrapper hint |
| `_DEN_COREUTILS=<path>` | use a specific microsoft/coreutils binary, e.g. `C:\Program Files\coreutils\coreutils.exe` (Windows) |
| `_DEN_COREUTILS=0` | disable the microsoft/coreutils tier (Windows) |
| `_DEN_UV_OVERRIDE` | uv python/pip override state (via `toggle-uv`) |
| `_DEN_HWINFO_HIDDEN` | hardware info hidden in the prompt (via `toggle-hwinfo`) |
