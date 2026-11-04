# docker - the dev container image

`docker/ubuntu/Dockerfile` builds the development container this repo is worked
on in: Ubuntu 26.04 with an unprivileged `dev` user, the language toolchains,
command-line tools, and den with its shell setup. It ships no coding-agent CLI
and no den skills: add those in an image of your own (see
[Adding your own tools](#adding-your-own-tools)). The build fetches den's
`main` branch from GitHub, so it reads nothing from the checkout.

## What the image contains

The build runs in five stages. Earlier stages change least, so an update near
the end (a new den, a new installer release) does not recompile the Rust tools.

| Stage | Contents |
| --- | --- |
| `system` | apt base (build-essential, git, curl, zsh, tmux, python3, openssh-client, ...) and the `dev` user (login shell zsh, password locked) |
| `rust-tools` | rustup and Rust (minimal profile + rustfmt, clippy) and cargo-built CLIs: bat, bottom, du-dust, fd-find, git-delta, gitui, grex, hyperfine, lsd, procs, ripgrep, sd, tealdeer, xh, zoxide, yazi |
| `tools` | starship, uv, ruff, ty, fzf, nvm + Node |
| `utilities` | gh, bats, shellcheck, lua5.4, jq, 7z, unrar-free, pigz, pbzip2, zstd, parallel, ffmpeg, rsync; PowerShell (`pwsh`); rclone |
| `workspace` | den (`uv tool install` from a BuildKit git source of `main`), then `den install shell --force --bin --zsh-plugins`; tzdata, GNU coreutils for the entrypoint, and the entrypoint itself |

User tools live under `/home/dev` (`~/.local/bin`, `~/.cargo/bin`,
`~/.nvm/current/bin`). They are on `dev`'s `PATH`, not the image's, and the
image's `HOME` is `/root`: see
[PATH and HOME in `docker exec`](#path-and-home-in-docker-exec).

PowerShell (`pwsh`) is installed for every user, and den's shell setup wires
den into `dev`'s pwsh profile. Its telemetry and its update check at startup
are off: the image's environment, the entrypoint and the zsh and bash startup
files set `POWERSHELL_TELEMETRY_OPTOUT=1` and `POWERSHELL_UPDATECHECK=Off`.
A newer pwsh comes with a new `PWSH_VERSION` (see [Versions](#versions)).
opencode is left out on purpose; install it in the container when you need it.

rustup comes from its release archive, fzf, gh and PowerShell from their
GitHub releases and rclone from its release folder; each download is checked
against that release's checksums file before it is installed. uv, ty and ruff
come from the installer each of their releases publishes, which checks the
archive it downloads against the checksum it carries. rsync is Ubuntu's
package, so its security fixes come as Ubuntu package updates, which a
refresh build brings in (see [Build](#build)).

## Build

The Dockerfile needs BuildKit: it uses `RUN` heredocs and `--mount=type=cache`.
`docker buildx build` always uses BuildKit. Keep the file's LF line endings, as
its header asks: the heredoc scripts run in bash, which chokes on CR characters.

From the repository root:

```sh
docker buildx build --pull --load -t den-dev -f docker/ubuntu/Dockerfile docker/ubuntu
```

The context directory is never read, so any small directory works. To give
`dev` your host IDs at build time, so the container never has to remap them,
add `--build-arg USER_UID="$(id -u)" --build-arg USER_GID="$(id -g)"`. Do this
when your UID or GID is not 1000 (macOS, LDAP and second accounts): remapping
at run time re-owns everything in `/home/dev`, and on overlayfs that copies
all of it, the toolchains included, into each new container before the shell
starts.

Downloads and compile outputs for cargo and uv go to BuildKit cache
mounts, so a rebuild reuses them. The base image and every tool are pinned to
exact versions (see [Versions](#versions)), so a rebuild installs the same
releases, with `--no-cache` too; a fix in one of them arrives as a version
update. After a security fix in an apt package, rebuild with the
`--no-cache-filter workspace` below. Either way, start a new container from
the new image: a running container keeps the binaries it started with. What
a new container keeps is in
[Keeping state across rebuilds](#keeping-state-across-rebuilds).

den is the exception: each build resolves den's `main` to a commit, so a
rebuild after `main` moves redoes the `workspace` stage and nothing before it.
To redo that stage when `main` has not moved, for example to pick up new
releases of den's Python dependencies or updates of the apt packages, add
`--no-cache-filter workspace`; the Rust tools are not recompiled. The stage
runs `apt-get upgrade`, so this also brings the updates for the apt packages
that the earlier stages installed. The zsh plugins den installs are pinned to
commits in den itself, so they change only when `main` does.

### Versions

`docker/ubuntu/Dockerfile` pins every version the image installs: the base
image by tag and digest (`BASE_IMAGE`), the Dockerfile syntax image on its
first line by version and digest, and each tool by a `*_VERSION` build arg.
apt packages are not pinned: they come from Ubuntu's archive as it is when
the build runs, and the `workspace` stage's `apt-get upgrade` brings their
updates. den is `main` (see above). yazi follows its own releases: yazi-build,
pinned by `YAZI_BUILD_VERSION`, builds the release yazi's `shipped` tag names
when the step runs.

[Renovate](https://docs.renovatebot.com/) keeps the pins current, with the
settings in `renovate.json` at the repository root:

- It opens a pull request for each update: the base image, the syntax image,
  each `*_VERSION` build arg and each GitHub Action the workflows use (those
  are pinned to commit SHAs, with the version in a comment). A new major
  version gets a pull request of its own.
- It proposes a release only once it has been out for 7 days
  (`minimumReleaseAge`), so a release that is withdrawn or found broken in its
  first week never reaches the image. Its Dependency Dashboard issue lists the
  updates still waiting.
- It merges nothing: every pull request waits for a review. One that
  changes the Dockerfile runs the `dev image` workflow, which builds the
  image with the new version.

Each `*_VERSION` build arg has a `# renovate:` comment on the line right
above it, which names where Renovate looks up the releases (a datasource and
a package name); keep the two together. To bump a version by hand, change the
build arg's default in the Dockerfile, in the form the table below gives.
To try another version without a commit, pass it as a build arg, for example
`--build-arg RIPGREP_VERSION=15.2.0`. For the base image, keep the tag and
take the digest from the `Digest:` line of
`docker buildx imagetools inspect ubuntu:26.04`.

### Build ARGs

Override any of these with `--build-arg NAME=value`. A version build arg's
default is the release pinned in the Dockerfile (see [Versions](#versions)).

| ARG | Default | Meaning |
| --- | --- | --- |
| `BASE_IMAGE` | `ubuntu:26.04` with its digest | Base image, by tag and digest. The apt steps assume Ubuntu (`ubuntu.sources`). |
| `APT_HTTP_PIPELINING` | `1` | `1` leaves apt's HTTP pipelining on, as apt ships it. `0` turns it off for every `apt-get` in the build, and in the container too (`/etc/apt/apt.conf.d/90-no-http-pipelining`): on some networks `apt-get update` fails with `Hash Sum mismatch` while the same files download intact without pipelining. |
| `USERNAME` | `dev` | Account name. The entrypoint reads it from `/etc/container-user`. |
| `USER_UID` | `1000` | Nonzero UID for the account. On Ubuntu, UID 1000 reuses the stock `ubuntu` account and renames it. The build fails if any other account already has the UID. |
| `USER_GID` | `1000` | Nonzero primary GID. An existing group with this GID is reused. |
| `RUSTUP_USE_CURL` | `0` | `1` selects rustup's deprecated curl backend as a TLS workaround. |
| `RUSTUP_VERSION` | pinned | Exact rustup release, such as `1.29.2`. |
| `RUST_VERSION` | pinned | Exact Rust release, such as `1.99.1`; rustup makes it the default toolchain. |
| `BUILD_JOBS` | empty | The most compile jobs each cargo build runs at once (cargo's `CARGO_BUILD_JOBS`), a positive number. Empty leaves cargo's default, one per logical CPU. Lower it when the Rust tools' compile runs out of memory; cargo is the only compiler the build runs. Changing it rebuilds the Rust tools. |
| `BAT_VERSION`, `BOTTOM_VERSION`, `DU_DUST_VERSION`, `FD_FIND_VERSION`, `GIT_DELTA_VERSION`, `GITUI_VERSION`, `GREX_VERSION`, `HYPERFINE_VERSION`, `LSD_VERSION`, `PROCS_VERSION`, `RIPGREP_VERSION`, `SD_VERSION`, `TEALDEER_VERSION`, `XH_VERSION`, `ZOXIDE_VERSION`, `YAZI_BUILD_VERSION` | pinned | Exact release of each cargo-built crate (`du-dust`, `fd-find`, `git-delta` and `yazi-build` are crate names), such as `15.2.0`. |
| `STARSHIP_VERSION` | pinned | Exact starship release without the `v` prefix. |
| `UV_VERSION`, `TY_VERSION`, `RUFF_VERSION` | pinned | Exact uv, ty and ruff releases. |
| `FZF_VERSION` | pinned | Exact fzf release without the `v` prefix. |
| `NVM_VERSION` | pinned | Exact nvm release, including the `v` prefix. |
| `NODE_VERSION` | pinned | Exact Node.js release, such as `22.23.4`; nvm installs it and makes it the default. A major version, such as `24`, takes that line's newest release. |
| `GH_VERSION` | pinned | Exact gh release without the `v` prefix. |
| `PWSH_VERSION` | pinned | Exact PowerShell release without the `v` prefix. |
| `RCLONE_VERSION` | pinned | Exact rclone release including the `v` prefix. |
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
| `HOST_UID` | the build's `USER_UID` | UID `dev` runs as. Must be nonzero and not used by another account. If it differs from the build's UID, the entrypoint changes it, re-owns the files in `/home/dev` that had the old IDs, and prints one line to stderr saying so (with `-d`, see it with `docker logs den-dev`). On overlayfs the re-owning copies the whole home, the toolchains included, into each new container; build with `--build-arg USER_UID/USER_GID` instead (see [Build](#build)). |
| `HOST_GID` | the build's `USER_GID` | GID `dev` runs as. The group is created if it does not exist. A GID other than the build's re-owns `/home/dev` the same way. |
| `FIX_WORKSPACE_OWNERSHIP` | `0` | Set to `1` to also re-own files under `/workspace` that had `dev`'s old UID or GID when the IDs change. Files with other owners are left alone, symlinks are not followed, and the walk does not cross into other file systems. |

On a root start, the entrypoint also makes `dev` the owner of `/workspace`
when nothing is mounted there. Changing IDs needs the root start: do not pass
a non-root `--user` to `docker run`. With a non-root `--user`, the entrypoint
rejects `FIX_WORKSPACE_OWNERSHIP=1` and refuses to start unless the IDs
already match.

### PATH and HOME in `docker exec`

`docker exec` starts every process, root's included, with the image's
environment: `HOME=/root` and a `PATH` that holds only root-owned system
directories. A root command, run with or without a shell, therefore reads
its configuration from `/root`, not from files `dev` can write (dpkg's
`~/.dpkg.cfg`, git's `~/.gitconfig`, or the `.pth` files in the Python user
site-packages under `~/.local`, which `python3` runs when package scripts
start it, for example through `py3compile`), and a command it looks up by
name never comes from a directory `dev` can write. Root execs start in
`/workspace`, which `dev` owns, and `python3 -c` or `-m` imports from the
current directory first, so pass `-w /` when root runs Python there. The
image keeps no package lists, so update them first:

```sh
docker exec den-dev sh -c 'apt-get update && apt-get install -y <package>'
```

`dev` gets its home and its tool directories (`~/.nvm/current/bin`,
`~/.local/bin`, `~/.cargo/bin`) back from the entrypoint and from the shell
startup files: `/etc/zsh/zshenv`, which every zsh reads, and
`/etc/bash.bashrc`, which only an interactive bash reads, set both, and
`/etc/profile.d/00-container-home.sh`, which login shells (`bash -l`,
`sh -l`) read, sets the home. So `docker exec -it --user dev den-dev zsh`
works as it is. A `dev` command run without a shell, or through `bash -c` or
`sh -c`, keeps `HOME=/root`, which `dev` cannot read, and the system `PATH`.
Run it through zsh (`zsh -c` or `zsh -lc`), or pass `dev`'s home and the
command's full path:

```sh
docker exec --user dev den-dev zsh -lc 'den --version'
docker exec --user dev -e HOME=/home/dev den-dev /home/dev/.local/bin/den --version
```

`.github/workflows/docker-dev-image.yml` builds the image when `docker/`
changes, checks the `HOME` and `PATH` that root gets with and without a
shell, and runs `dev`'s two forms above against it.

### zsh completion

For `dev`, `/etc/zsh/zshenv` sets `skip_global_compinit=1`, so den's quick
`compinit` runs. Without it, Ubuntu's `/etc/zsh/zshrc` would run a full one
before `init.zsh` (which then runs none of its own), a few ms more for every
shell. den's `compinit -C` reuses `~/.zcompdump` as it is while the dump is
less than a day old and `compaudit` finds nothing wrong in `fpath`; otherwise
the full `compinit -i` runs, which takes in completion functions added since
(an apt package, a new tool) and leaves out those in directories others may
write to ([zsh completion](../shell/README.md#zsh-completion) in
`shell/README.md` has the rules). To have new functions at once, run `reload`,
which deletes the dump. A new container starts without one.

## Adding your own tools

The image leaves out the coding-agent CLIs (Claude Code, Codex and the like)
and den's skills. Add those, and any other tool you want, in an image of your
own built `FROM` this one:

```dockerfile
# syntax=docker/dockerfile:1
FROM den-dev

# Tools for dev, installed as dev with its home and tool directories.
USER dev
ENV HOME=/home/dev \
    PATH=/home/dev/.nvm/current/bin:/home/dev/.local/bin:/home/dev/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN npm install -g --no-audit --no-fund <package>

# System packages, as root with root's home and the system PATH.
USER root
ENV HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN apt-get update && \
    apt-get install -y --no-install-recommends <package> && \
    rm -rf /var/lib/apt/lists/*
```

- Before a root step that follows a `dev` step, set `HOME=/root` and the
  system `PATH` again, as den's Dockerfile does. A `dev` step can leave files
  in `dev`'s home that root's tools read (`~/.curlrc`, `~/.dpkg.cfg`), or a
  program named like `curl` or `apt-get` in a directory on `dev`'s `PATH`.
- End the image as root with that `HOME` and `PATH`, as den's image does:
  `docker exec` starts every process with the image's environment (see
  [PATH and HOME in `docker exec`](#path-and-home-in-docker-exec)), and the
  entrypoint starts as root before it drops to `dev`.
- If you built den's image with another `USERNAME`, use that name and its home
  in the `dev` steps.

Build den's image first (see [Build](#build)), then yours with the default
`docker` builder, which finds the local `den-dev` image. Leave out `--pull`
there: it makes the build pull every base image from a registry, and
`den-dev` exists only on your machine.

```sh
docker buildx build --load -t my-dev -f Dockerfile .
```

## Keeping state across rebuilds

`/home/dev` lives in the container's writable layer. It survives
`docker restart` but not `docker rm`, and moving to a rebuilt image means a new
container. Logins and history go with it (`~/.config/gh`, `~/.zsh_history`,
and whatever the tools you add keep there), so log in again in the new
container.
