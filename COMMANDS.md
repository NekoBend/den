# den command reference

Every command den's shell environment adds, grouped by task, with where each one
is available. This is a map of the surface; for the how and why (the wrapper
dispatch model, toggles, install flags) see [`shell/README.md`](shell/README.md)
and, for the `den` CLI, [`den/README.md`](den/README.md).

## How to read this

- **bash/zsh** = the POSIX shell config (`shell/posix/*.sh`), **pwsh** = the
  PowerShell port (`shell/pwsh/*.ps1`), **cmd** = the Windows Command Prompt /
  Clink port (`shell/cmd/`).
- `✓` provided, `—` not provided, `native` the OS already ships it (den does not
  add its own). cmd is a deliberately thinner subset; a `—` in the cmd column is
  usually intentional, not an oversight.
- These are shell-sourced commands (aliases/functions/wrappers). In **bash/zsh**
  they are all interactive-only. In **pwsh** only the native-command-shadowing
  wrappers/aliases/coreutils/completion are interactive-gated; the additive helpers
  (functions, python, ffmpeg, parallel, snippet, cheat, proxy, hwinfo) load whenever
  the profile is sourced. Many commands also load only when their tool is present
  (uv, ffmpeg, zoxide, fzf, lsd/bat/fd/rg). The one exception is the standalone
  `fixids` executable (below), which lives on `PATH` and runs from any context.
- Modern-tool wrappers obey the `_DEN_WRAPPERS` toggle (`toggle-wrapper`) and the
  uv redirects obey `_DEN_UV_OVERRIDE` (`toggle-uv`). The `toggle-*` commands are
  pure flips on bash/zsh/pwsh (arguments are ignored); the cmd shims also accept
  `on` / `off`.

## Navigation and directories

| Command | Does | bash/zsh | pwsh | cmd |
|---|---|:---:|:---:|:---:|
| `cd <dir>` | zoxide smart-jump when wrappers are ON, else plain cd | ✓ | ✓ | `z` |
| `cdi` | interactive zoxide jump (fzf picker) | ✓ | ✓ | `zi` |
| `zd` / `zdi` | always jump via zoxide, ignoring the wrapper toggle | ✓ | ✓ | ✓ |
| `up [N]` | go up N directories (default 1) | ✓ | ✓ | ✓ |
| `..`, `.1`–`.9` | go up 1..9 levels (`..` = one) | ✓ | ✓ | ✓ |
| `mkcd <dir>` | `mkdir -p` then cd into it | ✓ | ✓ | ✓ |
| `cdf` | fuzzy-find a subdirectory (fd + fzf) and cd into it | ✓ | ✓ | — |
| `back` | cd to the previous directory (N=1 only) | ✓ | ✓ | ✓ |
| `y` | launch the yazi file manager, cd to its exit directory | ✓ | ✓ | — |
| `c` | clear the screen | ✓ | ✓ | ✓ |

den initializes zoxide with `--no-cmd` in bash/zsh/pwsh, so bare `z` / `zi` do not
exist there — you jump through den's toggle-aware `cd` / `cdi` or the always-on
`zd` / `zdi`. Only cmd runs `zoxide init cmd` without `--no-cmd`, so there `z` / `zi`
work directly (with `zd` / `zdi` as doskey aliases for them).

## Git shortcuts

Identical names across all three shells (posix/pwsh aliases and functions, cmd
doskey macros).

| Command | Does | bash/zsh | pwsh | cmd |
|---|---|:---:|:---:|:---:|
| `g` | `git` | ✓ | ✓ | ✓ |
| `ga` / `gaa` | `git add` / `git add --all` | ✓ | ✓ | ✓ |
| `gb` | `git branch` | ✓ | ✓ | ✓ |
| `gc` / `gcm` | `git commit` / `git commit -m` | ✓ | ✓ | ✓ |
| `gco` / `gsw` | `git checkout` / `git switch` | ✓ | ✓ | ✓ |
| `gd` / `gds` | `git diff` / `git diff --staged` | ✓ | ✓ | ✓ |
| `gf` | `git fetch --all --prune` | ✓ | ✓ | ✓ |
| `gl` | `git log --oneline --graph` | ✓ | ✓ | ✓ |
| `gpl` / `gps` | `git pull` / `git push` | ✓ | ✓ | ✓ |
| `gst` | `git status -sb` | ✓ | ✓ | ✓ |
| `gu` | launch the gitui terminal UI | ✓ | ✓ | ✓ |

On cmd, `gu` maps unconditionally to `gitui` (no "not installed" guard); posix/pwsh
fall back with a message.

## Docker shortcuts

| Command | Does | bash/zsh | pwsh | cmd |
|---|---|:---:|:---:|:---:|
| `d` | `docker` | ✓ | ✓ | ✓ |
| `dc` | `docker compose` | ✓ | ✓ | ✓ |
| `dcb` / `dcu` / `dcd` | compose `build` / `up` / `down` | ✓ | ✓ | ✓ |
| `dce` / `dcl` | compose `exec` / `logs` | ✓ | ✓ | ✓ |
| `di` / `dps` | `docker images` / `docker ps` | ✓ | ✓ | ✓ |
| `dri` / `drir` | `docker run -it` / `docker run -it --rm` | ✓ | ✓ | ✓ |

## Modern-tool wrappers (ls / cat / grep / find)

Each prefers a modern tool when installed and falls back to the native command;
all obey `_DEN_WRAPPERS` (flip with `toggle-wrapper`). The `*w` names always use
the modern tool, bypassing the toggle.

| Command | Does | bash/zsh | pwsh | cmd |
|---|---|:---:|:---:|:---:|
| `ls` | `lsd` → native `ls` / `dir` | ✓ | ✓ | ✓ |
| `la` / `ll` / `lla` | all / long / long-all listings | ✓ | ✓ | ✓ |
| `lt` / `llt` | tree / long tree | ✓ | ✓ | ✓ |
| `cat` | `bat` → native `cat` / `type` | ✓ | ✓ | ✓ |
| `grep` | `rg` → native `grep` / `findstr` | ✓ | ✓ | ✓ |
| `find` | `fd` → native `find` | ✓ | ✓ | ✓ |
| `ripgrep` | `rg` passthrough (no fallback) | ✓ | ✓ | — |
| `catw` / `findw` / `grepw` / `lsw` | always bat / fd / rg / lsd | ✓ | ✓ | — |
| `toggle-wrapper` | flip the wrappers on/off (`_DEN_WRAPPERS`) | ✓ | ✓ | ✓ |

On Windows, `cp` / `mv` / `rm` / `mkdir` / `rmdir` gain Unix-flag behavior via
microsoft/coreutils when it is installed (pwsh only); otherwise they keep the stock
PowerShell cmdlet behavior.

## Unix coreutils (Windows fills a gap)

pwsh and cmd add these because Windows lacks them; bash/zsh already have the real
tools. The cmd shims are positional-only (no GNU flags, no pipe input).

| Command | Does | bash/zsh | pwsh | cmd |
|---|---|:---:|:---:|:---:|
| `head` / `tail` | first / last N lines | native | ✓ | ✓ (positional) |
| `wc` | line / word / char counts | native | ✓ | ✓ (positional) |
| `which` | locate a command on PATH | native | ✓ | ✓ |
| `touch` | create / update-timestamp a file | native | ✓ | ✓ |
| `df` | disk free space | native | ✓ | — |
| `env` | print env / run with VAR=val overrides | native | ✓ | — |
| `split` | split a file into chunks | native | ✓ | — |

## File utilities

| Command | Does | bash/zsh | pwsh | cmd |
|---|---|:---:|:---:|:---:|
| `digest {md5\|sha256\|sha512} <file>` | file hash | ✓ | ✓ | ✓ |
| `mkfile <size> <path>` | create a dummy file of a given size | ✓ | ✓ | — |
| `extract <archive>` | auto-detect archive type and extract | ✓ | ✓ | — |
| `archive <out> <in>...` | create an archive (format from the output name) | ✓ | ✓ | — |
| `path` | print `$PATH`, one entry per line | ✓ | ✓ | ✓ |
| `ports` | list listening TCP ports | ✓ | ✓ | — |

## Python and uv

The `python` / `pip` family transparently routes through `uv` (unless uv is absent
or `_DEN_UV_OVERRIDE=0`). Inside an active venv, `pip` / `pip3` use the venv's own
pip directly, while `python` / `python3` / `py` still run through
`uv run --python <venv version>`. Flip the redirect with `toggle-uv`.

| Command | Does | bash/zsh | pwsh | cmd |
|---|---|:---:|:---:|:---:|
| `python` / `python3` / `py` | `uv run -- python`, else system python | ✓ | ✓ | ✓ (no `py`) |
| `pip` / `pip3` | `uv pip`, else system pip | ✓ | ✓ | ✓ (no `pip3`) |
| `uv` | injects `--python` for `uv run` inside an active venv | ✓ | ✓ | ✓ |
| `va [name]` | activate a venv (default `.venv`) | ✓ | ✓ | — |
| `vd` | deactivate the active venv | ✓ | ✓ | — |
| `vv [args]` | `uv venv` (create only) | ✓ | ✓ | — |
| `vva [name]` | `uv venv` then activate | ✓ | ✓ | — |
| `toggle-uv` | flip the uv redirect (`_DEN_UV_OVERRIDE`) | ✓ | ✓ | ✓ |

The uv redirects load only when uv is installed.

## Media (ffmpeg)

Loads only when ffmpeg is installed. pwsh has the same set; cmd has none.

| Command | Does | bash/zsh | pwsh | cmd |
|---|---|:---:|:---:|:---:|
| `tomp4` / `towebm` | convert to H.264/AAC mp4 / VP9/Opus webm | ✓ | ✓ | — |
| `tomp3` / `towav` / `toflac` | convert audio to mp3 / wav / flac | ✓ | ✓ | — |
| `togif` | convert to GIF (2-pass palette) | ✓ | ✓ | — |
| `minfo` | media info via ffprobe | ✓ | ✓ | — |
| `clip` | cut a video segment (stream copy by default) | ✓ | ✓ | — |
| `strip-audio` | remove the audio track | ✓ | ✓ | — |
| `thumbnail` | extract a single frame as an image | ✓ | ✓ | — |

## Parallel operations

pwsh runs `pcp`/`pmv`/`prm` via PowerShell 7's `-Parallel`; bash/zsh use background
jobs / xargs. `ptar` is threaded on bash/zsh (pigz/pbzip2/pxz when installed) but a
plain `tar` wrapper on pwsh.

| Command | Does | bash/zsh | pwsh | cmd |
|---|---|:---:|:---:|:---:|
| `pcp` / `pmv` | parallel copy / move (last arg = destination) | ✓ | ✓ | — |
| `prm` | parallel remove (y/N confirm; `-f`/`-Force` to skip) | ✓ | ✓ | — |
| `ptar` | compress an archive; threaded (pigz/pbzip2/pxz) on bash/zsh, plain `tar` on pwsh | ✓ | ✓ | — |
| `pxargs` | `xargs -P nproc` | ✓ | — | — |

## Snippets, cheatsheets, proxy

| Command | Does | bash/zsh | pwsh | cmd |
|---|---|:---:|:---:|:---:|
| `snippet` / `snip` | save/ls/show/run/rm/pick named command snippets | ✓ | ✓ | — |
| `cheat [name\|ls]` | browse den's bundled cheatsheets (fzf + bat) | ✓ | ✓ | — |
| `proxy <add\|rm\|ls\|on\|off\|status>` | named proxy profiles (session env vars) | ✓ | ✓ | — |

Cheatsheets are deployed by `den install cheatsheets`; snippets and proxy profiles
live under `$XDG_CONFIG_HOME`.

## Hardware / prompt

| Command | Does | bash/zsh | pwsh | cmd |
|---|---|:---:|:---:|:---:|
| `toggle-hwinfo` | show/hide CPU/GPU info in the starship prompt | ✓ | ✓ | ✓ |
| `refresh-hwinfo` | clear the per-boot hardware cache so it re-detects | ✓ | ✓ | — |

## History, session, editor

| Command | Does | bash/zsh | pwsh | cmd |
|---|---|:---:|:---:|:---:|
| `again [N]` | re-run the Nth previous command after a confirm | ✓ | ✓ | ✓ (N=1) |
| `sagain [N]` | `again` with sudo | ✓ | ✓ | — |
| `reload` | clear den's shell caches and reload the config (re-exec on bash/zsh, re-source in place on pwsh) | ✓ | ✓ | — |
| `code` | launch VS Code (prefers code-insiders) | ✓ | ✓ | ✓ |
| `open <path>` | open a file/dir with the default app | — | ✓ | — |

On cmd, `code` maps unconditionally to `code-insiders` (no fallback to stable
`code`); posix/pwsh fall back.

## Standalone helper

| Command | Does | Where |
|---|---|---|
| `fixids` | fast, filtered, parallel `chown` (a faster fixuid) | `shell/posix/bin/fixids`, deployed to `~/.local/bin` (bash script) |

## The `den` CLI

`den` is the installer/deployer. Full flags are in [`den/README.md`](den/README.md);
this is the shape.

| Command | Does |
|---|---|
| `den install [skills\|shell\|hook\|cheatsheets]` | deploy a component (no target on a TTY = interactive); `skills --profile weak\|frontier` picks the parent-prompt profile (frontier default) |
| `den uninstall [skills\|shell\|hook\|cheatsheets]` | remove den-identical files for a component |
| `den upgrade [--refresh]` | upgrade den via uv; `--refresh` redeploys skills + shell with the new binary (alias: `den update`) |
| `den install shell` | the command in this reference — deploys bash/zsh/pwsh/cmd config |
| `den hook <install\|remove\|list\|run\|imprint>` | per-workspace per-turn agent imprint hooks (runtime plumbing) |
| `den hook memory <show\|save\|add\|checkpoint\|log\|restore\|diff\|clear\|path>` | workspace session memory (also `den memory ...`) |
| `den verify <file.py>` | format/lint/typecheck one Python file, honoring the project's own ruff/ty config (runtime plumbing for skills) |
| `den --help` / `den --version` | top-level usage / version |

Run `den <command> --help` for a component's flags.
