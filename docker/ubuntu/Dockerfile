# syntax=docker/dockerfile:1
# Development image. Save with LF line endings; usage: docker/README.md.
# ARG settings: override with --build-arg NAME=value.
# HOST_UID/HOST_GID and FIX_WORKSPACE_OWNERSHIP: runtime settings, passed with -e.

ARG BASE_IMAGE=ubuntu:26.04
FROM ${BASE_IMAGE} AS system

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

# 1. OS packages and user. Compilers remain available for development.
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        build-essential ca-certificates curl fzf git less libssl-dev \
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
RUN curl --proto '=https' --tlsv1.2 -fsSL https://sh.rustup.rs -o /tmp/rustup.sh && \
    sh /tmp/rustup.sh -y --no-modify-path --profile minimal --component rustfmt,clippy && \
    rm /tmp/rustup.sh

# Put expensive compiles before frequently changed tools. Cache downloads and
# compilation outputs outside the image; keep installed binaries in ~/.cargo/bin.
RUN --mount=type=cache,id=cargo-registry-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.cargo/registry,uid=${USER_UID},gid=${USER_GID},sharing=locked \
    --mount=type=cache,id=cargo-git-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.cargo/git,uid=${USER_UID},gid=${USER_GID},sharing=locked \
    --mount=type=cache,id=cargo-target-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.cache/cargo-target,uid=${USER_UID},gid=${USER_GID},sharing=locked \
    CARGO_TARGET_DIR="$HOME/.cache/cargo-target" cargo install --locked \
        bat bottom broot du-dust eza fd-find git-delta gitui grex hyperfine \
        lsd procs ripgrep sd tealdeer xh zoxide

# yazi-build installs yazi/ya from its build script. Reusing its compiled target
# skips that side effect, so cache downloads and the Docker layer, not its target.
RUN --mount=type=cache,id=cargo-registry-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.cargo/registry,uid=${USER_UID},gid=${USER_GID},sharing=locked \
    --mount=type=cache,id=cargo-git-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.cargo/git,uid=${USER_UID},gid=${USER_GID},sharing=locked \
    cargo install --locked yazi-build && \
    command -v yazi && command -v ya && \
    rm -rf /tmp/yazi-build-*

# 3. User-installed language tools and AI CLIs.
FROM rust-tools AS tools
# Download each official installer completely before executing it as the user.
RUN curl -fsSL https://starship.rs/install.sh -o /tmp/starship.sh && \
    sh /tmp/starship.sh --yes --bin-dir "$HOME/.local/bin" && rm /tmp/starship.sh
RUN curl -fsSL https://astral.sh/uv/install.sh -o /tmp/uv.sh && \
    sh /tmp/uv.sh && rm /tmp/uv.sh && \
    curl -fsSL https://astral.sh/ty/install.sh -o /tmp/ty.sh && \
    sh /tmp/ty.sh && rm /tmp/ty.sh && \
    curl -fsSL https://astral.sh/ruff/install.sh -o /tmp/ruff.sh && \
    sh /tmp/ruff.sh && rm /tmp/ruff.sh

ENV NVM_DIR="${HOME}/.nvm"
# Build setting: exact nvm release, including the v prefix.
ARG NVM_VERSION=v0.40.7
RUN curl -fsSL "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" -o /tmp/nvm.sh && \
    bash /tmp/nvm.sh && rm /tmp/nvm.sh
# Build settings: project-selected version series, not exact patch versions.
ARG NODE_MAJOR=22
ARG ACPX_VERSION=0.16
RUN source "$NVM_DIR/nvm.sh" && \
    nvm install "$NODE_MAJOR" && \
    nvm alias default "$NODE_MAJOR" && \
    ln -sfn "$NVM_DIR/versions/node/$(nvm version default)" "$NVM_DIR/current" && \
    nvm cache clear
ENV PATH="${NVM_DIR}/current/bin:${PATH}"

RUN --mount=type=cache,id=npm-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.npm,uid=${USER_UID},gid=${USER_GID},sharing=locked \
    npm install -g --no-audit --no-fund "acpx@${ACPX_VERSION}" && \
    acpx --skill install acpx --agent claude --scope user

RUN curl -fsSL https://claude.ai/install.sh -o /tmp/claude.sh && \
    bash /tmp/claude.sh && rm /tmp/claude.sh
RUN curl -fsSL https://chatgpt.com/codex/install.sh -o /tmp/codex.sh && \
    sh /tmp/codex.sh && rm /tmp/codex.sh
RUN curl -fsSL https://x.ai/cli/install.sh -o /tmp/grok.sh && \
    GROK_BIN_DIR="$HOME/.local/bin" bash /tmp/grok.sh && rm /tmp/grok.sh
RUN curl -fsSL https://dev.meta.ai/install.sh -o /tmp/muse.sh && \
    bash /tmp/muse.sh && rm /tmp/muse.sh
RUN curl -fsSL https://antigravity.google/cli/install.sh -o /tmp/agy.sh && \
    bash /tmp/agy.sh && rm /tmp/agy.sh

# 4. System utilities and file-transfer tools, before workspace configuration.
FROM tools AS utilities
USER root
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
apt-get install -y --no-install-recommends "$gh_package" bubblewrap \
    libacl1-dev libattr1-dev libidn2-dev liblz4-dev libpopt-dev \
    libxxhash-dev libzstd-dev zlib1g-dev
# Test, lint and review tools (bats runs tests/agents; shellcheck, lua5.4, jq)
# plus the archive and media tools den's shell functions wrap.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bats ffmpeg jq lua5.4 p7zip-full parallel pbzip2 pigz shellcheck unrar-free zstd
rm -rf /var/lib/apt/lists/*
INSTALL_UTILITIES_DEPS

USER ${USER_UID}:${USER_GID}
# Build setting: exact official rsync release.
ARG RSYNC_VERSION=3.5.1
RUN <<'INSTALL_RSYNC'
build_dir=$(mktemp -d)
trap 'rm -rf "$build_dir"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 \
    "https://download.samba.org/pub/rsync/src/rsync-${RSYNC_VERSION}.tar.gz" \
    -o "$build_dir/rsync.tar.gz"
tar -xzf "$build_dir/rsync.tar.gz" -C "$build_dir"
cd "$build_dir/rsync-${RSYNC_VERSION}"
./configure --prefix="$HOME/.local"
make -j "$(nproc)"
make install
"$HOME/.local/bin/rsync" --version
INSTALL_RSYNC

# Build setting: current, or an exact rclone release including the v prefix.
ARG RCLONE_VERSION=current
RUN <<'INSTALL_RCLONE'
archive_dir=$(mktemp -d)
trap 'rm -rf "$archive_dir"' EXIT
download_base=https://downloads.rclone.org
if [[ "$RCLONE_VERSION" != current ]]; then
    download_base="$download_base/$RCLONE_VERSION"
fi
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 \
    "$download_base/rclone-${RCLONE_VERSION}-linux-${TARGETARCH}.zip" \
    -o "$archive_dir/rclone.zip"
unzip -q -j "$archive_dir/rclone.zip" '*/rclone' -d "$archive_dir"
install -m 0755 "$archive_dir/rclone" "$HOME/.local/bin/rclone"
INSTALL_RCLONE

# 5. Workspace configuration. Updating den does not rebuild the utilities.
FROM utilities AS workspace
RUN --mount=type=cache,id=uv-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.cache/uv,uid=${USER_UID},gid=${USER_GID},sharing=locked \
    git clone --depth 1 https://github.com/NekoBend/den.git /tmp/den && \
    uv tool install --python /usr/bin/python3 --link-mode copy /tmp/den && \
    den install shell --force --bin && \
    den install skills --tool claude --tool codex --force && \
    rm -rf /tmp/den

# 6. Runtime entrypoint and defaults.
USER root
# Build setting: IANA timezone name; also exported to application processes.
ARG TZ=Asia/Tokyo
ENV TZ=${TZ}
RUN apt-get update && \
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

runtime_path=$PATH
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
cat >> /etc/zsh/zshenv <<'ROOT_ZSH_ENV'

# docker exec --user changes identity but retains the image's HOME.
if [[ "$EUID" == 0 && "$HOME" == "/home/$(</etc/container-user)" ]]; then
    export HOME=/root USER=root LOGNAME=root
fi
ROOT_ZSH_ENV
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
