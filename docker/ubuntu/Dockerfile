# syntax=docker/dockerfile:1.28.0@sha256:bb22d9815c728170f72750f4e5b0d672e06176142e1d602c7e66c050100b7e5b
# Development image. Save with LF line endings; usage: docker/README.md.
# ARG settings: override with --build-arg NAME=value.
# HOST_UID/HOST_GID and FIX_WORKSPACE_OWNERSHIP: runtime settings, passed with -e.
# Every version below is an exact pin, and Renovate (renovate.json) proposes
# each update as a pull request; apt packages (Ubuntu's archive) and den (its
# main branch) are not pinned. The "# renovate:" comment above a *_VERSION
# build arg says where Renovate looks up its releases; keep it on the line
# right above the ARG, which is where Renovate reads it.

# Build setting: the base image, by tag and digest. The apt steps assume Ubuntu.
ARG BASE_IMAGE=ubuntu:26.04@sha256:6a06111c3b0a8600feadb270aec771dc239bf407b25625f93f44ab00e11f4d3c
FROM ${BASE_IMAGE} AS system

SHELL ["/bin/bash", "-euo", "pipefail", "-c"]
ENV LANG=C.UTF-8 LC_ALL=C.UTF-8

# Build setting: 1 leaves apt's HTTP pipelining on, as apt ships it; 0 turns
# it off for every apt-get in the build and in the container. On some
# networks apt-get update fails with "Hash Sum mismatch" while the same files
# download intact without pipelining. https sources take the http setting
# (apt-transport-https(1)).
ARG APT_HTTP_PIPELINING=1
RUN <<'CONFIGURE_APT'
case "$APT_HTTP_PIPELINING" in
    1) ;;
    0) printf 'Acquire::http::Pipeline-Depth "0";\n' > /etc/apt/apt.conf.d/90-no-http-pipelining ;;
    *) echo "APT_HTTP_PIPELINING must be 0 or 1, not '$APT_HTTP_PIPELINING'" >&2; exit 2 ;;
esac
CONFIGURE_APT

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
# rustup-init from rustup's release archive, checked against the .sha256 file
# next to it, installs rustup and the Rust release RUST_VERSION names. rustup
# reads RUSTUP_VERSION as the rustup release to download, which is the one
# this build arg names.
# Build setting: an exact rustup release.
# renovate: datasource=github-tags depName=rust-lang/rustup
ARG RUSTUP_VERSION=1.29.2
# Build setting: an exact Rust release.
# renovate: datasource=rust-version depName=rust
ARG RUST_VERSION=1.99.1
RUN <<'INSTALL_RUST'
case "$TARGETARCH" in
    amd64) triple=x86_64-unknown-linux-gnu ;;
    arm64) triple=aarch64-unknown-linux-gnu ;;
    *) echo "Unsupported TARGETARCH: '$TARGETARCH'" >&2; exit 1 ;;
esac
[[ "$RUSTUP_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected rustup version: '$RUSTUP_VERSION'" >&2; exit 1; }
[[ "$RUST_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected Rust version: '$RUST_VERSION'" >&2; exit 1; }
release=https://static.rust-lang.org/rustup/archive/${RUSTUP_VERSION}/${triple}
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$release/rustup-init" -o "$work_dir/rustup-init"
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$release/rustup-init.sha256" -o "$work_dir/rustup-init.sha256"
# One "<sha256> *./rustup-init" line. A missing line fails too: sha256sum -c
# rejects an empty list.
(cd "$work_dir" && awk '$2 == "*./rustup-init"' rustup-init.sha256 | sha256sum -c -)
chmod 0755 "$work_dir/rustup-init"
"$work_dir/rustup-init" -y --no-modify-path --profile minimal \
    --default-toolchain "$RUST_VERSION" --component rustfmt,clippy
INSTALL_RUST

# Build setting: the most compile jobs each cargo build below runs at once
# (cargo's CARGO_BUILD_JOBS), for a machine whose memory cannot hold one job
# per CPU. Empty leaves cargo's default, one per logical CPU. These cargo
# builds are the image's only compiles; the cargo that yazi-build starts
# inherits the limit.
ARG BUILD_JOBS=
# One build arg per crate, so Renovate proposes each crate's update on its own.
# renovate: datasource=crate depName=bat versioning=semver
ARG BAT_VERSION=0.26.1
# renovate: datasource=crate depName=bottom versioning=semver
ARG BOTTOM_VERSION=0.14.9
# renovate: datasource=crate depName=du-dust versioning=semver
ARG DU_DUST_VERSION=1.2.6
# renovate: datasource=crate depName=fd-find versioning=semver
ARG FD_FIND_VERSION=10.5.0
# renovate: datasource=crate depName=git-delta versioning=semver
ARG GIT_DELTA_VERSION=0.20.1
# renovate: datasource=crate depName=gitui versioning=semver
ARG GITUI_VERSION=0.28.1
# renovate: datasource=crate depName=grex versioning=semver
ARG GREX_VERSION=1.4.6
# renovate: datasource=crate depName=hyperfine versioning=semver
ARG HYPERFINE_VERSION=2.0.0
# renovate: datasource=crate depName=lsd versioning=semver
ARG LSD_VERSION=1.2.0
# renovate: datasource=crate depName=procs versioning=semver
ARG PROCS_VERSION=0.14.12
# renovate: datasource=crate depName=ripgrep versioning=semver
ARG RIPGREP_VERSION=15.2.0
# renovate: datasource=crate depName=sd versioning=semver
ARG SD_VERSION=1.0.0
# renovate: datasource=crate depName=tealdeer versioning=semver
ARG TEALDEER_VERSION=1.9.1
# renovate: datasource=crate depName=xh versioning=semver
ARG XH_VERSION=0.26.3
# renovate: datasource=crate depName=zoxide versioning=semver
ARG ZOXIDE_VERSION=0.10.0
# Put expensive compiles before frequently changed tools. Cache downloads and
# compilation outputs outside the image; keep installed binaries in ~/.cargo/bin.
# cargo install installs exactly the version after @, with the crate's own
# Cargo.lock (--locked).
RUN --mount=type=cache,id=cargo-registry-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.cargo/registry,uid=${USER_UID},gid=${USER_GID},sharing=locked \
    --mount=type=cache,id=cargo-git-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.cargo/git,uid=${USER_UID},gid=${USER_GID},sharing=locked \
    --mount=type=cache,id=cargo-target-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.cache/cargo-target,uid=${USER_UID},gid=${USER_GID},sharing=locked <<'INSTALL_CRATES'
[[ -z "$BUILD_JOBS" || "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "BUILD_JOBS must be empty or a positive number, not '$BUILD_JOBS'" >&2; exit 2; }
[[ -z "$BUILD_JOBS" ]] || export CARGO_BUILD_JOBS=$BUILD_JOBS
CARGO_TARGET_DIR="$HOME/.cache/cargo-target" cargo install --locked \
    "bat@$BAT_VERSION" "bottom@$BOTTOM_VERSION" "du-dust@$DU_DUST_VERSION" \
    "fd-find@$FD_FIND_VERSION" "git-delta@$GIT_DELTA_VERSION" "gitui@$GITUI_VERSION" \
    "grex@$GREX_VERSION" "hyperfine@$HYPERFINE_VERSION" "lsd@$LSD_VERSION" \
    "procs@$PROCS_VERSION" "ripgrep@$RIPGREP_VERSION" "sd@$SD_VERSION" \
    "tealdeer@$TEALDEER_VERSION" "xh@$XH_VERSION" "zoxide@$ZOXIDE_VERSION"
INSTALL_CRATES

# yazi-build installs yazi/ya from its build script. Reusing its compiled target
# skips that side effect, so cache downloads and the Docker layer, not its target.
# The build script builds yazi's "shipped" tag, which yazi moves to each new
# release: YAZI_BUILD_VERSION pins the installer, and the yazi it builds is the
# release that tag names when this step runs.
# renovate: datasource=crate depName=yazi-build versioning=semver
ARG YAZI_BUILD_VERSION=26.9.1
RUN --mount=type=cache,id=cargo-registry-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.cargo/registry,uid=${USER_UID},gid=${USER_GID},sharing=locked \
    --mount=type=cache,id=cargo-git-${TARGETARCH}-${USER_UID}-${USER_GID},target=${HOME}/.cargo/git,uid=${USER_UID},gid=${USER_GID},sharing=locked <<'INSTALL_YAZI'
[[ -z "$BUILD_JOBS" || "$BUILD_JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "BUILD_JOBS must be empty or a positive number, not '$BUILD_JOBS'" >&2; exit 2; }
[[ -z "$BUILD_JOBS" ]] || export CARGO_BUILD_JOBS=$BUILD_JOBS
cargo install --locked "yazi-build@$YAZI_BUILD_VERSION"
command -v yazi && command -v ya
rm -rf /tmp/yazi-build-*
INSTALL_YAZI

# 3. User-installed language tools.
FROM rust-tools AS tools
# Download each official installer completely before executing it as the user.
# starship's installer from the release's tag, told to install that release.
# Build setting: an exact starship release without the v prefix.
# renovate: datasource=github-releases depName=starship/starship extractVersion=^v(?<version>.+)$
ARG STARSHIP_VERSION=1.27.0
RUN curl --proto '=https' --tlsv1.2 -fsSL --retry 3 \
        "https://raw.githubusercontent.com/starship/starship/v${STARSHIP_VERSION}/install/install.sh" -o /tmp/starship.sh && \
    sh /tmp/starship.sh --yes --version "v${STARSHIP_VERSION}" --bin-dir "$HOME/.local/bin" && rm /tmp/starship.sh
# Each uv, ty and ruff release publishes its own installer, which checks the
# archive it downloads against the checksum it carries.
# Build settings: exact uv, ty and ruff releases.
# renovate: datasource=github-releases depName=astral-sh/uv
ARG UV_VERSION=0.13.6
# renovate: datasource=github-releases depName=astral-sh/ty
ARG TY_VERSION=0.0.95
# renovate: datasource=github-releases depName=astral-sh/ruff
ARG RUFF_VERSION=0.17.3
RUN curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "https://astral.sh/uv/${UV_VERSION}/install.sh" -o /tmp/uv.sh && \
    sh /tmp/uv.sh && rm /tmp/uv.sh && \
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "https://astral.sh/ty/${TY_VERSION}/install.sh" -o /tmp/ty.sh && \
    sh /tmp/ty.sh && rm /tmp/ty.sh && \
    curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "https://astral.sh/ruff/${RUFF_VERSION}/install.sh" -o /tmp/ruff.sh && \
    sh /tmp/ruff.sh && rm /tmp/ruff.sh

# fzf from its GitHub release, checked against the release's checksums file.
# Build setting: an exact fzf release without the v prefix.
# renovate: datasource=github-releases depName=junegunn/fzf extractVersion=^v(?<version>.+)$
ARG FZF_VERSION=0.74.5
RUN <<'INSTALL_FZF'
version=$FZF_VERSION
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
# renovate: datasource=github-releases depName=nvm-sh/nvm
ARG NVM_VERSION=v0.40.8
RUN curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh" -o /tmp/nvm.sh && \
    bash /tmp/nvm.sh && rm /tmp/nvm.sh
# Build setting: an exact Node.js release, which nvm installs and makes the
# default. It comes after nvm's installer, which installs the Node.js release
# a NODE_VERSION in its environment names.
# renovate: datasource=node-version depName=node versioning=node
ARG NODE_VERSION=26.13.0
RUN source "$NVM_DIR/nvm.sh" && \
    nvm install "$NODE_VERSION" && \
    nvm alias default "$NODE_VERSION" && \
    ln -sfn "$NVM_DIR/versions/node/$(nvm version default)" "$NVM_DIR/current" && \
    nvm cache clear
ENV PATH="${NVM_DIR}/current/bin:${PATH}"
# npm, installed over the one that comes with Node.js: npm ships its own
# dependencies, and their fixes come with npm releases, which the npm in a
# Node.js release trails.
# Build setting: an exact npm release.
# renovate: datasource=npm depName=npm
ARG NPM_VERSION=12.2.2
RUN <<'INSTALL_NPM'
[[ "$NPM_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected npm version: '$NPM_VERSION'" >&2; exit 1; }
npm install -g --no-audit --no-fund "npm@$NPM_VERSION"
# The npm that dev's PATH finds is the one the build arg names.
installed=$(npm --version)
[[ "$installed" == "$NPM_VERSION" ]] || { echo "npm on PATH is $installed, not $NPM_VERSION" >&2; exit 1; }
npm cache clean --force
INSTALL_NPM

# 4. System utilities and file-transfer tools, before workspace configuration.
FROM tools AS utilities
USER root
# The installers above ran as the user and could leave files in its home that
# root's tools read (~/.curlrc for curl, ~/.dpkg.cfg for dpkg's hooks), or a
# program named like one this step runs (curl, dpkg, apt-get) in the user's
# PATH directories (~/.local/bin, ~/.cargo/bin, ~/.nvm/current/bin), so this
# root step uses root's home and a PATH of root-owned system directories.
ENV HOME=/root PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
RUN <<'INSTALL_UTILITIES_DEPS'
sed -i 's,http://,https://,g' /etc/apt/sources.list.d/ubuntu.sources
apt-get update
# Test, lint and review tools (bats runs tests/agents; shellcheck, lua5.4, jq),
# the archive and media tools den's shell functions wrap, and rsync. rsync is
# Ubuntu's package: its security fixes arrive as package updates, which the
# workspace stage's apt-get upgrade brings in.
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
    bats ffmpeg jq lua5.4 p7zip-full parallel pbzip2 pigz rsync shellcheck unrar-free zstd
rm -rf /var/lib/apt/lists/*
INSTALL_UTILITIES_DEPS

# gh from its GitHub release, checked against the release's checksums file,
# as a package for every user. GitHub's apt repository lists only its newest
# gh, so a pinned release would stop installing from there when the next one
# came out.
# Build setting: an exact gh release without the v prefix.
# renovate: datasource=github-releases depName=cli/cli extractVersion=^v(?<version>.+)$
ARG GH_VERSION=2.103.3
RUN <<'INSTALL_GH'
version=$GH_VERSION
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected gh version: '$version'" >&2; exit 1; }
release=https://github.com/cli/cli/releases/download/v${version}
package=gh_${version}_linux_${TARGETARCH}.deb
work_dir=$(mktemp -d)
trap 'rm -rf "$work_dir"' EXIT
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$release/$package" -o "$work_dir/$package"
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$release/gh_${version}_checksums.txt" -o "$work_dir/checksums.txt"
# One "<sha256>  <file>" line per release file; check the package's own line.
(cd "$work_dir" && awk -v name="$package" '$2 == name' checksums.txt | sha256sum -c -)
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends "$work_dir/$package"
rm -rf /var/lib/apt/lists/*
gh --version
INSTALL_GH

# PowerShell from its GitHub release, checked against the release's
# hashes.sha256, installed for every user. With pwsh present, den's shell
# setup in the workspace stage also wires den into dev's pwsh profile.
# pwsh sends telemetry unless POWERSHELL_TELEMETRY_OPTOUT is set when it
# starts, and POWERSHELL_UPDATECHECK=Off stops its update check at startup
# (a new PWSH_VERSION updates this image's pwsh). The image ENV sets both for
# the build steps from here on and for every docker exec; the entrypoint and
# the zsh and bash startup files below set them again.
ENV POWERSHELL_TELEMETRY_OPTOUT=1 POWERSHELL_UPDATECHECK=Off
# Build setting: an exact PowerShell release without the v prefix.
# renovate: datasource=github-releases depName=PowerShell/PowerShell extractVersion=^v(?<version>.+)$
ARG PWSH_VERSION=7.6.9
RUN <<'INSTALL_PWSH'
version=$PWSH_VERSION
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
# rclone from its release's own folder, the one with a SHA256SUMS file.
# Build setting: an exact rclone release including the v prefix.
# renovate: datasource=github-releases depName=rclone/rclone
ARG RCLONE_VERSION=v1.75.2
RUN <<'INSTALL_RCLONE'
archive_dir=$(mktemp -d)
trap 'rm -rf "$archive_dir"' EXIT
version=$RCLONE_VERSION
[[ "$version" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "Unexpected rclone version: '$version'" >&2; exit 1; }
release=https://downloads.rclone.org/$version
archive=rclone-${version}-linux-${TARGETARCH}.zip
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$release/$archive" -o "$archive_dir/$archive"
curl --proto '=https' --tlsv1.2 -fsSL --retry 3 "$release/SHA256SUMS" -o "$archive_dir/SHA256SUMS"
# One "<sha256>  <file>" line per release file; check the archive's own line.
(cd "$archive_dir" && awk -v name="$archive" '$2 == name' SHA256SUMS | sha256sum -c -)
unzip -q -j "$archive_dir/$archive" '*/rclone' -d "$archive_dir"
install -m 0755 "$archive_dir/rclone" "$HOME/.local/bin/rclone"
# rclone reads every RCLONE_<FLAG> environment variable as that flag's value,
# so the RCLONE_VERSION build arg would be its --version flag, and a release
# name is not a valid value for it.
env -u RCLONE_VERSION "$HOME/.local/bin/rclone" version
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
# pwsh sends no telemetry and skips its update check, as in the image ENV,
# whatever docker run -e passed.
export POWERSHELL_TELEMETRY_OPTOUT=1 POWERSHELL_UPDATECHECK=Off

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
# Every zsh, root's included, keeps pwsh's telemetry and update check off as
# the image ENV does, also one started with an emptied environment (env -i,
# su -).
export POWERSHELL_TELEMETRY_OPTOUT=1 POWERSHELL_UPDATECHECK=Off
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
export POWERSHELL_TELEMETRY_OPTOUT=1 POWERSHELL_UPDATECHECK=Off
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
