# docker - the dev container image

`docker/ubuntu/Dockerfile` builds the development container this repo is worked
on in: Ubuntu 26.04 with an unprivileged `dev` user, the language toolchains,
the coding-agent CLIs, and den with its shell setup, skills and parent prompts.
The build fetches den's `main` branch from GitHub, so it reads nothing from the
checkout.

## What the image contains

The build runs in five stages. Earlier stages change least, so an update near
the end (a new den, a new installer release) does not recompile the Rust tools.

| Stage | Contents |
| --- | --- |
| `system` | apt base (build-essential, git, curl, zsh, tmux, fzf, python3, openssh-client, ...) and the `dev` user (login shell zsh, password locked) |
| `rust-tools` | rustup (minimal profile + rustfmt, clippy) and cargo-built CLIs: bat, bottom, broot, du-dust, eza, fd-find, git-delta, gitui, grex, hyperfine, lsd, procs, ripgrep, sd, tealdeer, xh, zoxide, yazi |
| `tools` | starship, uv, ruff, ty, nvm + Node, acpx (plus its Claude skill), and the claude, codex, grok, muse and antigravity (`agy`) CLIs |
| `utilities` | gh, bubblewrap, bats, shellcheck, lua5.4, jq, 7z, unrar-free, pigz, pbzip2, zstd, parallel, ffmpeg; rsync built from source; rclone |
| `workspace` | den (`uv tool install` from a BuildKit git source of `main`), then `den install shell --force --bin --zsh-plugins` and `den install skills --tool claude --tool codex --with-parent --force`; tzdata, GNU coreutils for the entrypoint, and the entrypoint itself |

User tools live under `/home/dev` (`~/.local/bin`, `~/.cargo/bin`,
`~/.nvm/current/bin`). They are on `dev`'s `PATH`, not the image's: see
[Run](#run).

PowerShell and opencode are left out on purpose; install them in the container
when you need them.

## Build

The Dockerfile needs BuildKit: it uses `RUN` heredocs and `--mount=type=cache`.
`docker buildx build` always uses BuildKit. Keep the file's LF line endings, as
its header asks: the heredoc scripts run in bash, which chokes on CR characters.

From the repository root:

```sh
docker buildx build --load -t den-dev -f docker/ubuntu/Dockerfile docker/ubuntu
```

The context directory is never read, so any small directory works. To give
`dev` your host IDs at build time, so the container never has to remap them,
add `--build-arg USER_UID="$(id -u)" --build-arg USER_GID="$(id -g)"`. Do this
when your UID or GID is not 1000 (macOS, LDAP and second accounts): remapping
at run time re-owns everything in `/home/dev`, and on overlayfs that copies
about 2 GB into each new container before the shell starts.

Downloads and compile outputs for cargo, npm and uv go to BuildKit cache
mounts, so a rebuild reuses them. Most installers fetch the latest release, and
layer caching keeps whichever release was fetched first. Add `--no-cache` when
you want every tool refreshed.

den is the exception: each build resolves den's `main` to a commit, so a
rebuild after `main` moves redoes the `workspace` stage and nothing before it.
To redo that stage when `main` has not moved, for example to fetch new zsh
plugins, add `--no-cache-filter workspace`; the Rust tools are not recompiled.

### Build ARGs

Override any of these with `--build-arg NAME=value`.

| ARG | Default | Meaning |
| --- | --- | --- |
| `BASE_IMAGE` | `ubuntu:26.04` | Base image. The apt steps assume Ubuntu (`ubuntu.sources`). |
| `USERNAME` | `dev` | Account name. The entrypoint reads it from `/etc/container-user`. |
| `USER_UID` | `1000` | Nonzero UID for the account. On Ubuntu, UID 1000 reuses the stock `ubuntu` account and renames it. The build fails if any other account already has the UID. |
| `USER_GID` | `1000` | Nonzero primary GID. An existing group with this GID is reused. |
| `RUSTUP_USE_CURL` | `0` | `1` selects rustup's deprecated curl backend as a TLS workaround. |
| `NVM_VERSION` | `v0.40.7` | Exact nvm release, including the `v` prefix. |
| `NODE_MAJOR` | `22` | Node major version; nvm installs it and makes it the default. |
| `ACPX_VERSION` | `0.19` | acpx version series for `npm install -g`. |
| `GH_VERSION` | `latest` | `latest`, or an exact apt version of gh from GitHub's repository. |
| `RSYNC_VERSION` | `3.5.1` | Exact rsync release, built from source into `~/.local`. |
| `RCLONE_VERSION` | `current` | `current`, or an exact rclone release including the `v` prefix. |
| `TZ` | `Asia/Tokyo` | IANA time zone name. The container also exports it as `TZ`. |

`TARGETARCH` comes from BuildKit (`--platform`); do not set it. A stage built
`FROM` another stage inherits that stage's build args, which is why later
stages use `TARGETARCH`, `USER_UID` and `USER_GID` without declaring them again.

## Run

```sh
docker run -dit --name den-dev \
  -e HOST_UID="$(id -u)" -e HOST_GID="$(id -g)" \
  -v "$PWD:/workspace" \
  den-dev
docker exec -it --user dev den-dev zsh
```

The container starts as root, but only its entrypoint
(`/usr/local/bin/container-entrypoint`) runs as root. The entrypoint applies
the runtime variables below, then drops to `dev` and runs the command (`zsh`
by default). `-dit` keeps that shell open in the background, and you work in
shells from `docker exec`. `docker exec` does not go through the entrypoint and
runs as root unless told otherwise, so always pass `--user dev`. A root zsh
prints a warning that shows this command.

| Variable | Default | Effect |
| --- | --- | --- |
| `HOST_UID` | the build's `USER_UID` | UID `dev` runs as. Must be nonzero and not used by another account. If it differs from the build's UID, the entrypoint changes it, re-owns the files in `/home/dev` that had the old IDs, and prints one line to stderr saying so. On overlayfs the re-owning copies about 2 GB into each new container; build with `--build-arg USER_UID/USER_GID` instead (see [Build](#build)). |
| `HOST_GID` | the build's `USER_GID` | GID `dev` runs as. The group is created if it does not exist. A GID other than the build's re-owns `/home/dev` the same way. |
| `FIX_WORKSPACE_OWNERSHIP` | `0` | Set to `1` to also re-own files under `/workspace` that had `dev`'s old UID or GID when the IDs change. Files with other owners are left alone, symlinks are not followed, and the walk does not cross into other file systems. |

On a root start, the entrypoint also makes `dev` the owner of `/workspace`
when nothing is mounted there. Changing IDs needs the root start: do not pass
a non-root `--user` to `docker run`. With a non-root `--user`, the entrypoint
rejects `FIX_WORKSPACE_OWNERSHIP=1` and refuses to start unless the IDs
already match.

### PATH and HOME in `docker exec`

`docker exec` starts every process, root's included, with the image's
environment. Its `PATH` holds only root-owned system directories, so a
command that a root exec looks up by name never comes from a directory `dev`
can write. `dev`'s tool directories (`~/.nvm/current/bin`, `~/.local/bin`,
`~/.cargo/bin`) are added by the entrypoint and, for users other than root,
by `/etc/zsh/zshenv` and `/etc/bash.bashrc`. So
`docker exec -it --user dev den-dev zsh` works as it is, but a `dev` command
run without a shell needs one, or its full path:

```sh
docker exec --user dev den-dev zsh -lc 'claude --version'
docker exec --user dev den-dev /home/dev/.local/bin/claude --version
```

A root zsh or interactive bash also gets `HOME=/root` back instead of the
image's `/home/dev`, so it reads root's startup files, not `dev`'s. A root
command run without a shell keeps `HOME=/home/dev`; pass `-e HOME=/root` to
`docker exec` for those.

### zsh completion

For `dev`, `/etc/zsh/zshenv` sets `skip_global_compinit=1`: den's
`init.zsh` runs `compinit` itself, so Ubuntu's second, full `compinit` would
only add about 12 ms to every shell. den's `compinit -C` reuses `~/.zcompdump`
as it is, so after you add completion functions (an apt package, a new tool),
delete `~/.zcompdump` and start a new shell. A new container starts without
one.

## Keeping state across rebuilds

`/home/dev` lives in the container's writable layer. It survives
`docker restart` but not `docker rm`, and moving to a rebuilt image means a new
container. Logins and history go with it (`~/.claude`, `~/.claude.json`,
`~/.codex`, `~/.config/gh`), so log in again in the new container.
