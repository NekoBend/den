# syntax=docker/dockerfile:1
# Development image. Save with LF line endings; usage: docker/README.md.
# ARG settings: override with --build-arg NAME=value.
# HOST_UID/HOST_GID and FIX_WORKSPACE_OWNERSHIP: runtime settings, passed with -e.

ARG BASE_IMAGE=ubuntu:26.04
FROM ${BASE_IMAGE} AS system

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

# 1. OS packages and user. Compilers remain available for development.
# fzf is not taken from apt: Ubuntu's package trails fzf's releases, so the
# tools stage installs fzf's own release.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl git less libssl-dev \
        openssh-client pkg-config procps python3 tmux unzip util-linux wget xz-utils zip zsh \
    && rm -rf /var/lib/apt/lists/*

# Build settings: account name and nonzero Linux user/group IDs.
ARG USERNAME=dev
ARG USER_UID=1000
ARG USER_GID=1000

# Ubuntu can already own UID 1000. Reuse only its default account; never
# silently take over a system account. UID/GID zero are deliberately rejected.
RUN <<'SETUP_USER'
[[ "$USERNAME" =~ ^[a-z_][a-z0-9_-]{0,30}$ ]] || { echo 'Invalid USERNAME' >&2; exit 2; }
for identifier in "$USER_UID" "$USER_GID"; do
    [[ "$identifier" =~ ^[1-9][0-9]{0,9}$ ]] && ((identifier <= 2147483647)) \
        || { echo 'USER_UID and USER_GID must be nonzero numeric IDs' >&2; exit 2; }
done
if ! getent group "$USER_GID" >/dev/null; then
    groupadd --gid "$USER_GID" "$USERNAME"
fi
if account=$(getent passwd "$USER_UID"); then
    account_name=${account%%:*}
    [[ "$account_name" == ubuntu && "$USER_UID" == 1000 ]] \
        || { echo 'USER_UID already belongs to another account' >&2; exit 2; }
    if [[ "$account_name" != "$USERNAME" ]]; then
        usermod --login "$USERNAME" "$account_name"
    fi
    usermod --gid "$USER_GID" --home "/home/$USERNAME" --move-home --shell /bin/zsh "$USERNAME"
else
    useradd --uid "$USER_UID" --gid "$USER_GID" --create-home --shell /bin/zsh "$USERNAME"
fi
usermod --password '!' "$USERNAME"
install -d -o "$USER_UID" -g "$USER_GID" -m 0755 \
    /workspace "/home/$USERNAME/.local" "/home/$USERNAME/.local/bin" "/home/$USERNAME/.cache"
chmod 0750 "/home/$USERNAME"
SETUP_USER

# Tool installations run as the user, outside the root initialization steps.
USER ${USER_UID}:${USER_GID}
ENV HOME=/home/${USERNAME}
ENV PATH="${HOME}/.local/bin:${HOME}/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
WORKDIR ${HOME}

# 2. Rust tools. Keep expensive compiles before frequently updated installers.
FROM system AS rust-tools
# TARGETARCH is supplied by BuildKit from --platform, not set manually.
ARG TARGETARCH
# Build setting: 1 selects the deprecated curl backend as a TLS workaround.
ARG RUSTUP_USE_CURL=0
RUN curl --proto '=https' --tlsv1.2 -fsSL --retry 3 https://sh.rustup.rs -o /tmp/rustup.sh && \
    sh /tmp/rustup.sh -y --no-modify-path --profile minimal --component rustfmt,clippy && \
    rm /tmp/rustup.sh

# Put expensive compiles before frequently changed tools. Cache downloads and
# compilation outputs outside the image; keep installed binaries in ~/.cargo/bin.
RUN --mount=type=cache,id=cargo-registry-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.cargo/registry,uid=${USER_UID},gid=${USER_GID},sharing=locked \
    --mount=type=cache,id=cargo-git-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.cargo/git,uid=${USER_UID},gid=${USER_GID},sharing=locked \
    --mount=type=cache,id=cargo-target-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.cache/cargo-target,uid=${USER_UID},gid=${USER_GID},sharing=locked \
    CARGO_TARGET_DIR="$HOME/.cache/cargo-target" cargo install --locked \
        bat bottom du-dust fd-find git-delta gitui grex hyperfine \
        lsd procs ripgrep sd tealdeer xh zoxide

# yazi-build installs yazi/ya from its build script. Reusing its compiled target
# skips that side effect, so cache downloads and the Docker layer, not its target.
RUN --mount=type=cache,id=cargo-registry-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.cargo/registry,uid=${USER_UID},gid=${USER_GID},sharing=locked \
    --mount=type=cache,id=cargo-git-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.cargo/git,uid=${USER_UID},gid=${USER_GID},sharing=locked \
    cargo install --locked yazi-build && \
    command -v yazi && command -v ya && \
    rm -rf /tmp/yazi-build-*

# 3. User-installed language tools.
FROM rust-tools AS tools
# Download each official installer completely before executing it as the user.
RUN curl --proto '=https' --tlsv1.2 -fsSL --retry 3 https://starship.rs/install.sh -o /tmp/starship.sh && \
    sh /tmp/starship.sh --yes --bin-dir "$HOME/.local/bin" && rm /tmp/starship.sh
RUN curl --proto '=https' --tlsv1.2 -fsSL --retry 3 https://astral.sh/uv/install.sh -o /tmp/uv.sh && \
    sh /tmp/uv.sh && rm /tmp/uv.sh && \
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 https://astral.sh/ty/install.sh -o /tmp/ty.sh && \
    sh /tmp/ty.sh && rm /tmp/ty.sh && \
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 https://astral.sh/ruff/install.sh -o /tmp/ruff.sh && \
    sh /tmp/ruff.sh && rm /tmp/ruff.sh

# fzf from its GitHub release, checked against the release's checksums file.
# Build setting: latest, or an exact fzf release without the v prefix.
ARG FZF_VERSION=latest
RUN <<'INSTALL_FZF'
version=$FZF_VERSION
if [[ "$version" == latest ]]; then
    # GitHub redirects releases/latest to the newest release's tag.
    latest_url=$(curl --proto '=https' --tlsv1.2 -fsSLI --retry 3 -o /dev/null -w '%{url_effective}' \
        https://github.com/junegunn/fzf/releases/latest)
    version=${latest_url##*/v}
fi
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected fzf version: '$version'" >&2; exit 1; }
release=https://github.com/junegunn/fzf/releases/download/v${version}
archive=fzf-${version}-linux_${TARGETARCH}.tar.gz
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$release/$archive" -o "$work_dir/$archive"
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$release/fzf_${version}_checksums.txt" -o "$work_dir/checksums.txt"
# One "<sha256>  <file>" line per release file; check the archive's own line.
# A missing line fails too: sha256sum -c rejects an empty list.
(cd "$work_dir" && awk -v name="$archive" '$2 == name' checksums.txt | sha256sum -c -)
tar -xzf "$work_dir/$archive" -C "$work_dir" fzf
install -m 0755 "$work_dir/fzf" "$HOME/.local/bin/fzf"
"$HOME/.local/bin/fzf" --version
INSTALL_FZF

ENV NVM_DIR="${HOME}/.nvm"
# Build setting: exact nvm release, including the v prefix.
ARG NVM_VERSION=v0.40.7
RUN curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" -o /tmp/nvm.sh && \
    bash /tmp/nvm.sh && rm /tmp/nvm.sh
# Build setting: project-selected version series, not an exact patch version.
ARG NODE_MAJOR=22
RUN source "$NVM_DIR/nvm.sh" && \
    nvm install "$NODE_MAJOR" && \
    nvm alias default "$NODE_MAJOR" && \
    ln -sfn "$NVM_DIR/versions/node/$(nvm version default)" "$NVM_DIR/current" && \
    nvm cache clear
ENV PATH="${NVM_DIR}/current/bin:${PATH}"

# 4. System utilities and file-transfer tools, before workspace configuration.
FROM tools AS utilities
USER root
# The installers above ran as the user and could leave files in its home that
# root's tools read (~/.curlrc for curl, ~/.dpkg.cfg for dpkg's hooks), or a
# program named like one this step runs (curl, dpkg, apt-get) in the user's
# PATH directories (~/.local/bin, ~/.cargo/bin, ~/.nvm/current/bin), so this
# root step uses root's home and a PATH of root-owned system directories.
ENV HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Build setting: latest, or an exact package version from the official repository.
ARG GH_VERSION=latest
RUN <<'INSTALL_UTILITIES_DEPS'
install -d -m 0755 /etc/apt/keyrings
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 \
    https://cli.github.com/packages/githubcli-archive-keyring.gpg \
    -o /etc/apt/keyrings/githubcli-archive-keyring.gpg
chmod 0644 /etc/apt/keyrings/githubcli-archive-keyring.gpg
printf 'deb [arch=%s signed-by=/etc/apt/keyrings/githubcli-archive-keyring.gpg] https://cli.github.com/packages stable main\n' \
    "$(dpkg --print-architecture)" > /etc/apt/sources.list.d/github-cli.list
sed -i 's,http://,https://,g' /etc/apt/sources.list.d/ubuntu.sources
apt-get update
gh_package=gh
if [[ "$GH_VERSION" != latest ]]; then
    gh_package="gh=$GH_VERSION"
fi
apt-get install -y --no-install-recommends "$gh_package"
# The workspace stage's apt-get upgrade moves every package that is not held
# to the newest version its repository has, and GitHub's stays enabled, so
# an exact GH_VERSION is held.
if [[ "$GH_VERSION" != latest ]]; then
    apt-mark hold gh
fi
# Test, lint and review tools (bats runs tests/agents; shellcheck, lua5.4, jq),
# the archive and media tools den's shell functions wrap, and rsync. rsync is
# Ubuntu's package: its security fixes arrive as package updates, which the
# workspace stage's apt-get upgrade brings in.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bats ffmpeg jq lua5.4 p7zip-full parallel pbzip2 pigz rsync shellcheck unrar-free zstd
rm -rf /var/lib/apt/lists/*
INSTALL_UTILITIES_DEPS

# PowerShell from its GitHub release, checked against the release's
# hashes.sha256, installed for every user. With pwsh present, den's shell
# setup in the workspace stage also wires den into dev's pwsh profile.
# pwsh sends telemetry unless POWERSHELL_TELEMETRY_OPTOUT is set when it
# starts. The image ENV sets it for the build steps from here on and for every
# docker exec; the entrypoint and the zsh and bash startup files below set it
# again.
ENV POWERSHELL_TELEMETRY_OPTOUT=1
# Build setting: latest, or an exact PowerShell release without the v prefix.
ARG PWSH_VERSION=latest
RUN <<'INSTALL_PWSH'
version=$PWSH_VERSION
if [[ "$version" == latest ]]; then
    # GitHub redirects releases/latest to the newest release's tag.
    latest_url=$(curl --proto '=https' --tlsv1.2 -fsSLI --retry 3 -o /dev/null -w '%{url_effective}' \
        https://github.com/PowerShell/PowerShell/releases/latest)
    version=${latest_url##*/v}
fi
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected PowerShell version: '$version'" >&2; exit 1; }
release=https://github.com/PowerShell/PowerShell/releases/download/v${version}
package=powershell_${version}-1.deb_${TARGETARCH}.deb
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$release/$package" -o "$work_dir/$package"
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$release/hashes.sha256" -o "$work_dir/hashes.sha256"
# hashes.sha256 is UTF-16 text with CRLF line ends and one "<sha256> *<file>"
# line per release file; check the package's own line.
(cd "$work_dir" && iconv -f UTF-16 -t UTF-8 hashes.sha256 | tr -d '\r' \
    | awk -v name="*$package" '$2 == name' | sha256sum -c -)
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$work_dir/$package"
rm -rf /var/lib/apt/lists/*
pwsh --version
INSTALL_PWSH

USER ${USER_UID}:${USER_GID}
ENV HOME=/home/${USERNAME}
# The user's tool directories again, as before the root step: the workspace
# stage runs uv and den by name.
ENV PATH="${NVM_DIR}/current/bin:${HOME}/.local/bin:${HOME}/.cargo/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
# Build setting: current, or an exact rclone release including the v prefix.
ARG RCLONE_VERSION=current
RUN <<'INSTALL_RCLONE'
archive_dir=$(mktemp -d)
trap 'rm -rf "$archive_dir"' EXIT
version=$RCLONE_VERSION
if [[ "$version" == current ]]; then
    # version.txt names the current release ("rclone v1.2.3"). Only a
    # release's own folder has a SHA256SUMS file, so download from there.
    version=$(curl --proto '=https' --tlsv1.2 -fsSL --retry 3 https://downloads.rclone.org/version.txt)
    version=${version#rclone }
fi
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected rclone version: '$version'" >&2; exit 1; }
release=https://downloads.rclone.org/$version
archive=rclone-${version}-linux-${TARGETARCH}.zip
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$release/$archive" -o "$archive_dir/$archive"
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$release/SHA256SUMS" -o "$archive_dir/SHA256SUMS"
# One "<sha256>  <file>" line per release file; check the archive's own line.
(cd "$archive_dir" && awk -v name="$archive" '$2 == name' SHA256SUMS | sha256sum -c -)
unzip -q -j "$archive_dir/$archive" '*/rclone' -d "$archive_dir"
install -m 0755 "$archive_dir/rclone" "$HOME/.local/bin/rclone"
"$HOME/.local/bin/rclone" version
INSTALL_RCLONE

# den's main branch as a BuildKit git source. Every build resolves main to a
# commit, so the den step below reruns exactly when main moves; a RUN that
# cloned den itself would stay cached on the first build's den.
FROM scratch AS den-src
ADD https://github.com/NekoBend/den.git#main /

# 5. Workspace configuration. Updating den does not rebuild the utilities.
FROM utilities AS workspace
RUN --mount=type=bind,from=den-src,target=/tmp/den \
    --mount=type=cache,id=uv-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.cache/uv,uid=${USER_UID},gid=${USER_GID},sharing=locked \
    uv tool install --python /usr/bin/python3 --link-mode copy /tmp/den && \
    den install shell --force --bin --zsh-plugins

# 6. Runtime entrypoint and defaults.
USER root
# Every docker exec, root's included, starts with the image's ENV. Give it
# root's HOME and a PATH of root-owned system directories, so a root exec, with
# or without a shell, never reads configuration from dev's home or resolves a
# command from a directory dev can write. dev's HOME and tool directories come
# from the entrypoint and from the non-root branches of the startup files below;
# the build steps above that run as dev keep HOME=/home/dev.
ENV HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
# Build setting: IANA timezone name; also exported to application processes.
ARG TZ=Asia/Tokyo
ENV TZ=${TZ}
# apt-get upgrade runs in this last stage, which a refresh build redoes on its
# own (--no-cache-filter workspace), so a refresh also brings the updates for
# the packages that the earlier stages installed. It runs before the next step
# appends to /etc/zsh/zshenv, /etc/bash.bashrc and /etc/zsh/zshrc: those are
# package conffiles, and an upgrade that met them changed would stop at
# dpkg's question about keeping them.
RUN apt-get update && \
    DEBIAN_FRONTEND=noninteractive apt-get upgrade -y && \
    DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends tzdata gnu-coreutils && \
    test -f "/usr/share/zoneinfo/$TZ" && \
    ln -snf "/usr/share/zoneinfo/$TZ" /etc/localtime && \
    printf '%s\n' "$TZ" > /etc/timezone && \
    rm -rf /var/lib/apt/lists/*

RUN <<'INSTALL_ENTRYPOINT'
# Do not inherit administrative/device groups from Ubuntu's default account.
usermod --groups '' "$USERNAME"
printf '%s\n' "$USERNAME" > /etc/container-user
chmod 0644 /etc/container-user
cat > /usr/local/bin/container-entrypoint <<'ENTRYPOINT'
#!/bin/sh
# Initialize user IDs and optional workspace ownership, then drop root.
set -eu

inherited_path=$PATH
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH

fail() { printf '%s\n' "$*" >&2; exit 2; }
valid_id() {
    case "$1" in ''|0|0*|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 10 ] && [ "$1" -le 2147483647 ]
}

IFS= read -r username < /etc/container-user
record=$(getent passwd "$username")
IFS=: read -r name password old_uid old_gid gecos user_home login_shell <<EOF
$record
EOF
[ "$user_home" = "/home/$username" ] && [ ! -L "$user_home" ] \
    || fail 'Unexpected or symlinked user home'
# The image PATH holds system directories only; the command runs as the user
# with the user's tool directories first (the same list as /etc/zsh/zshenv).
runtime_path="$user_home/.nvm/current/bin:$user_home/.local/bin:$user_home/.cargo/bin:$inherited_path"
# pwsh sends no telemetry, as in the image ENV, whatever docker run -e passed.
export POWERSHELL_TELEMETRY_OPTOUT=1

target_uid=${HOST_UID:-$old_uid}
target_gid=${HOST_GID:-$old_gid}
valid_id "$target_uid" && valid_id "$target_gid" \
    || fail 'HOST_UID and HOST_GID must be nonzero numeric IDs'
fix_workspace=${FIX_WORKSPACE_OWNERSHIP:-0}
case "$fix_workspace" in
    0|1) ;;
    *) fail 'FIX_WORKSPACE_OWNERSHIP must be 0 or 1' ;;
esac

if [ "$(id -u)" -eq 0 ]; then
    if [ "$target_uid:$target_gid" != "$old_uid:$old_gid" ]; then
        if [ "$target_uid" != "$old_uid" ] && getent passwd "$target_uid" >/dev/null; then
            fail 'HOST_UID already belongs to another account'
        fi
        # On overlayfs, re-owning a file copies it into the container's layer.
        printf '%s\n' "container-entrypoint: remapping $username from $old_uid:$old_gid to $target_uid:$target_gid re-owns $user_home, which on overlayfs copies all of it into each new container; build with --build-arg USER_UID=$target_uid --build-arg USER_GID=$target_gid to skip this." >&2
        # Change only matching IDs. Do this before usermod so a failed workspace
        # traversal leaves the original account IDs available for a retry.
        if [ "$fix_workspace" = 1 ]; then
            [ -d /workspace ] && [ ! -L /workspace ] \
                || fail 'Workspace must be a directory, not a symlink'
            # uutils 0.8.0 chown -h follows directory symlinks; use GNU chown.
            find /workspace -xdev \( -uid "$old_uid" -o -gid "$old_gid" \) \
                -exec /usr/bin/gnuchown -h --from="$old_uid" "$target_uid" {} + \
                -exec /usr/bin/gnuchown -h --from=":$old_gid" ":$target_gid" {} + \
                || fail 'Workspace ownership adjustment failed'
        fi
        if ! getent group "$target_gid" >/dev/null; then
            groupadd --gid "$target_gid" "$username-$target_gid"
        fi
        usermod --uid "$target_uid" --gid "$target_gid" "$username"
        # Do not follow symlinks or descend into other filesystems. Handle
        # user/group ownership independently; preserve unrelated owners.
        find "$user_home" -xdev \( -uid "$old_uid" -o -gid "$old_gid" \) \
            -exec /usr/bin/gnuchown -h --from="$old_uid" "$target_uid" {} + \
            -exec /usr/bin/gnuchown -h --from=":$old_gid" ":$target_gid" {} +
    fi
    # A bare workspace needs an owner even when recursive adjustment is disabled.
    if ! mountpoint -q /workspace; then
        /usr/bin/gnuchown -h "$target_uid:$target_gid" /workspace
    fi
    export HOME="$user_home" USER="$username" LOGNAME="$username" SHELL="$login_shell"
    exec /usr/bin/setpriv --reuid "$target_uid" --regid "$target_gid" --init-groups \
        /usr/bin/env PATH="$runtime_path" "$@"
fi

[ "$fix_workspace" = 0 ] \
    || fail 'FIX_WORKSPACE_OWNERSHIP requires root initialization; omit --user or use --user 0'
[ "$(id -u):$(id -g)" = "$target_uid:$target_gid" ] \
    || fail 'UID/GID adjustment requires root initialization; omit --user or rebuild with matching USER_UID/USER_GID'
export PATH="$runtime_path" HOME="$user_home" USER="$username" LOGNAME="$username" SHELL="$login_shell"
exec "$@"
ENTRYPOINT
chmod 0755 /usr/local/bin/container-entrypoint
cat >> /etc/zsh/zshenv <<'CONTAINER_ZSH_ENV'

# docker exec --user changes identity but retains the image's HOME (/root)
# and PATH (system directories only). The container user gets its own HOME
# back, non-root shells add the user's tool directories (the entrypoint's
# list), and a root shell given the user's HOME (-e HOME=...) gets /root.
# Every zsh, root's included, keeps pwsh's telemetry off as the image ENV
# does, also one started with an emptied environment (env -i, su -).
export POWERSHELL_TELEMETRY_OPTOUT=1
if [[ "$EUID" == 0 ]]; then
    if [[ "$HOME" == "/home/$(</etc/container-user)" ]]; then
        export HOME=/root USER=root LOGNAME=root
    fi
else
    if [[ "$USERNAME" == "$(</etc/container-user)" ]]; then
        if [[ "$HOME" == /root ]]; then
            export HOME="/home/$USERNAME" USER="$USERNAME" LOGNAME="$USERNAME"
        fi
        # den's init.zsh runs a quick compinit when none ran before it; skip
        # the full one /etc/zsh/zshrc would run instead.
        skip_global_compinit=1
    fi
    () {
        local dir
        for dir in "$HOME/.cargo/bin" "$HOME/.local/bin" "$HOME/.nvm/current/bin"; do
            [[ ":$PATH:" == *":$dir:"* ]] || PATH="$dir:$PATH"
        done
    }
    export PATH
fi
CONTAINER_ZSH_ENV
cat >> /etc/bash.bashrc <<'CONTAINER_BASH_RC'

# The /etc/zsh/zshenv block for interactive bash. It runs before ~/.bashrc,
# so each bash reads its own user's ~/.bashrc. bash set HISTFILE from the HOME
# it started with before it read this file.
export POWERSHELL_TELEMETRY_OPTOUT=1
_container_user=$(< /etc/container-user)
if [ "$EUID" -eq 0 ]; then
    if [ "$HOME" = "/home/$_container_user" ]; then
        export HOME=/root USER=root LOGNAME=root
        if [ "${HISTFILE-}" = "/home/$_container_user/.bash_history" ]; then
            HISTFILE=/root/.bash_history
        fi
    fi
else
    if [ "$HOME" = /root ] && [ "$(id -un 2>/dev/null)" = "$_container_user" ]; then
        export HOME="/home/$_container_user" USER="$_container_user" LOGNAME="$_container_user"
        if [ "${HISTFILE-}" = /root/.bash_history ]; then
            HISTFILE=$HOME/.bash_history
        fi
    fi
    for _container_dir in "$HOME/.cargo/bin" "$HOME/.local/bin" "$HOME/.nvm/current/bin"; do
        case ":$PATH:" in
            *":$_container_dir:"*) ;;
            *) PATH="$_container_dir:$PATH" ;;
        esac
    done
    unset _container_dir
    export PATH
fi
unset _container_user
CONTAINER_BASH_RC
cat > /etc/profile.d/00-container-home.sh <<'CONTAINER_PROFILE'
# A login shell (bash -l, sh -l) finds ~/.profile through HOME, and
# /etc/profile runs this file first: the container user gets its own HOME
# back from the image's /root, and a root shell given the user's HOME /root.
_container_user=$(cat /etc/container-user)
if [ "$(id -u)" -eq 0 ]; then
    if [ "$HOME" = "/home/$_container_user" ]; then
        export HOME=/root USER=root LOGNAME=root
    fi
elif [ "$HOME" = /root ] && [ "$(id -un 2>/dev/null)" = "$_container_user" ]; then
    export HOME="/home/$_container_user" USER="$_container_user" LOGNAME="$_container_user"
fi
unset _container_user
CONTAINER_PROFILE
chmod 0644 /etc/profile.d/00-container-home.sh
cat >> /etc/zsh/zshrc <<'ROOT_ZSH_WARNING'

# Keep root access available, but make accidental root sessions visible.
if [[ -o interactive && "$EUID" == 0 ]]; then
    if [[ -t 2 && "${TERM:-dumb}" != dumb && -z "${NO_COLOR:-}" ]]; then
        printf '\033[1;33mWARNING: This shell is running as root.\033[0m\n' >&2
        printf 'For normal development, run this on the host:\n' >&2
        printf '\033[1;36m  docker exec -it --user %s <container-name> zsh\033[0m\n' "$(</etc/container-user)" >&2
    else
        printf 'WARNING: This shell is running as root.\n' >&2
        printf 'For normal development, run this on the host:\n' >&2
        printf '  docker exec -it --user %s <container-name> zsh\n' "$(</etc/container-user)" >&2
    fi
fi
ROOT_ZSH_WARNING
INSTALL_ENTRYPOINT
WORKDIR /workspace
# Only the entrypoint starts as root. docker exec must explicitly select dev.
USER root
ENTRYPOINT ["/usr/local/bin/container-entrypoint"]
CMD ["zsh"]
