# syntax=docker/dockerfile:1.27.1@sha256:4edf897a3ffa55b89f906fc8cc78afdb3f1834cc9c7083565e611a8a7d5fe99e
# Development image. Save with LF line endings; usage: docker/README.md.
# ARG settings: override with --build-arg NAME=value.
# HOST_UID/HOST_GID and FIX_WORKSPACE_OWNERSHIP: runtime settings, passed with -e.
# Every version below is an exact pin, and Renovate (renovate.json) proposes
# each update as a pull request; apt packages (Ubuntu's archive) and den (its
# main branch) are not pinned. The "# renovate:" comment above a *_VERSION
# build arg says where Renovate looks up its releases; keep it on the line
# right above the ARG, which is where Renovate reads it.

# Build setting: the base image, by tag and digest. The apt steps assume Ubuntu.
ARG BASE_IMAGE=ubuntu:26.04@sha256:c098726dd9b9733f3e885f8de0ef375206a311b0a317eadc40d347b1115fb944
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
ARG TY_VERSION=0.0.94
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
# Initialize user IDs, optional workspace ownership, /tmp and the state
# volume, then drop root.
set -eu

inherited_path=$PATH
PATH=/usr/sbin:/usr/bin:/sbin:/bin
export PATH
# The state volume's mount point (docker/README.md, "What survives where").
state_dir=/state

fail() { printf '%s\n' "$*" >&2; exit 2; }
warn() { printf 'container-entrypoint: %s\n' "$*" >&2; }
valid_id() {
    case "$1" in ''|0|0*|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 10 ] && [ "$1" -le 2147483647 ]
}
# Succeed when DIR is a mount point of its own, not a symbolic link to one.
own_mount() { [ ! -L "$1" ] && mountpoint -q "$1"; }

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
den_state=${DEN_STATE:-1}
case "$den_state" in
    0|1) ;;
    *) fail 'DEN_STATE must be 0 or 1' ;;
esac
clean_tmp=${DEN_CLEAN_TMP:-0}
case "$clean_tmp" in
    0|1) ;;
    *) fail 'DEN_CLEAN_TMP must be 0 or 1' ;;
esac
# The state step runs unless DEN_STATE=0, and only for a mount point at
# /state: the image's own /state directory is in the container's layer.
use_state=0
if [ "$den_state" = 1 ] && own_mount "$state_dir"; then
    use_state=1
fi

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
        # The state volume holds the user's files with the old IDs too; the
        # same walk, which a failure does not stop the start for.
        if [ "$use_state" = 1 ]; then
            find "$state_dir" -xdev \( -uid "$old_uid" -o -gid "$old_gid" \) \
                -exec /usr/bin/gnuchown -h --from="$old_uid" "$target_uid" {} + \
                -exec /usr/bin/gnuchown -h --from=":$old_gid" ":$target_gid" {} + \
                || warn "re-owning $state_dir from $old_uid:$old_gid failed part way"
        fi
    fi
    # A bare workspace needs an owner even when recursive adjustment is disabled.
    if ! mountpoint -q /workspace; then
        /usr/bin/gnuchown -h "$target_uid:$target_gid" /workspace
    fi
    # /tmp is emptied only on request, and only when it is a mount point of
    # its own (a volume or a tmpfs): anywhere else it is the image's /tmp or a
    # host directory, whose files this would delete. No process of the user's
    # runs yet. find does not follow symbolic links, and -xdev keeps it out of
    # file systems mounted below /tmp.
    if [ "$clean_tmp" = 1 ]; then
        if own_mount /tmp; then
            find /tmp -xdev -mindepth 1 -delete \
                || warn 'some entries under /tmp were left in place'
        else
            warn 'DEN_CLEAN_TMP=1 empties /tmp only when it is a mount point of its own; it is left as it is'
        fi
    fi
    # The state volume. Root only makes /state/home and gives /state and
    # /state/home, not what they hold, to the user, after checking that
    # neither is a symbolic link (chown -h would not follow one either).
    # state-link then links the home's paths into it as the user, so it never
    # reaches a file the user could not reach already. Its failures are
    # warnings: the start goes on.
    if [ "$use_state" = 1 ]; then
        if [ -L "$state_dir/home" ]; then
            warn "$state_dir/home is a symbolic link; the home is not linked into $state_dir"
        elif { [ -d "$state_dir/home" ] || (umask 077 && /usr/bin/gnumkdir "$state_dir/home"); } \
            && [ ! -L "$state_dir/home" ] \
            && /usr/bin/gnuchown -h "$target_uid:$target_gid" "$state_dir" "$state_dir/home"; then
            /usr/bin/setpriv --reuid "$target_uid" --regid "$target_gid" --init-groups \
                /usr/bin/env -i HOME="$user_home" PATH=/usr/sbin:/usr/bin:/sbin:/bin \
                /usr/local/lib/den/state-link \
                || warn "some paths of $user_home were not linked into $state_dir (see above)"
        else
            warn "could not prepare $state_dir/home; the home is not linked into $state_dir"
        fi
    fi
    export HOME="$user_home" USER="$username" LOGNAME="$username" SHELL="$login_shell"
    exec /usr/bin/setpriv --reuid "$target_uid" --regid "$target_gid" --init-groups \
        /usr/bin/env PATH="$runtime_path" "$@"
fi

[ "$fix_workspace" = 0 ] \
    || fail 'FIX_WORKSPACE_OWNERSHIP requires root initialization; omit --user or use --user 0'
[ "$(id -u):$(id -g)" = "$target_uid:$target_gid" ] \
    || fail 'UID/GID adjustment requires root initialization; omit --user or rebuild with matching USER_UID/USER_GID'
if [ "$use_state" = 1 ]; then
    warn "$state_dir is mounted, but only a root start links the home into it; omit --user, or set DEN_STATE=0"
fi
if [ "$clean_tmp" = 1 ]; then
    warn 'DEN_CLEAN_TMP=1 needs a root start; /tmp is left as it is'
fi
export PATH="$runtime_path" HOME="$user_home" USER="$username" LOGNAME="$username" SHELL="$login_shell"
exec "$@"
ENTRYPOINT
chmod 0755 /usr/local/bin/container-entrypoint

# The state volume (docker/README.md, "What survives where"). /state is a
# mount point the user owns. There is no VOLUME instruction: an image built
# FROM this one could never take one away.
install -d -o "$USER_UID" -g "$USER_GID" -m 0700 /state
install -d -m 0755 /etc/den /etc/den/state-paths.d /usr/local/lib/den
cat > /etc/den/state-paths.d/den.list <<'STATE_PATHS'
# The image's paths of the user's home kept in the state volume at
# /state/home, one "<kind> <path>" per line, the path relative to the home:
#   d  a directory, created in the volume when missing
#   F  a file, created empty in the volume when missing
#   f  a file, linked only once the volume or the home has one
# An image built FROM this one adds its own in a <name>.list file here; one
# environment adds its own in ~/.config/den/state-paths, in the volume.
d .ssh
F .gitconfig
F .zsh_history
F .bash_history
d .config/gh
d .config/rclone
d .local/share/zoxide
d .local/share/powershell/PSReadLine
d .config/den
STATE_PATHS
chmod 0644 /etc/den/state-paths.d/den.list
cat > /usr/local/lib/den/state-link <<'STATE_LINK'
#!/bin/sh
# Ubuntu's /bin/sh is dash, which has test -O.
# shellcheck shell=dash
# state-link - keep paths of the user's home in the state volume.
# container-entrypoint runs it as the user at each root start, once /state/home
# is the user's; run by hand, it applies the lists again. For each
# "<kind> <path>" line of the lists it links ~/<path> to /state/home/<path>
# (kinds: /etc/den/state-paths.d/den.list). The lists are every
# /etc/den/state-paths.d/*.list, then the environment's own
# /state/home/.config/den/state-paths. A path the home has and the volume
# does not moves into the volume; when both have one, the volume's stays and
# the home's moves to /state/home/.den-set-aside/<UTC time>/<path>. Nothing is
# deleted but an empty directory, and nothing is done through a symbolic link:
# an entry with one on its way, in the home or in the volume, is skipped. A
# bad line and an entry that fails are warnings, and the next line goes on;
# the exit status is 1 when there was one.
# HOME, DEN_STATE_ROOT (default /state) and DEN_STATE_LISTS (default
# /etc/den/state-paths.d) name the trees, so tests can run it elsewhere.
set -u
export LC_ALL=C
umask 077

home=${HOME:-}
volume=${DEN_STATE_ROOT:-/state}/home
lists_dir=${DEN_STATE_LISTS:-/etc/den/state-paths.d}
env_list=$volume/.config/den/state-paths
stamp=$(date -u +%Y%m%dT%H%M%SZ)
aside=
where=
status=0

warn() { printf 'state-link: %s\n' "$*" >&2; status=1; }

# Succeed when DIR is an absolute path to a directory this user owns, not a
# symbolic link.
own_dir() {
    case "$1" in /*) ;; *) return 1 ;; esac
    [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ]
}

# Succeed when REL is a relative path of names made of letters, digits, '.',
# '_' and '-', none of them '.' or '..': no empty name, no leading or trailing
# slash.
valid_rel() {
    case "$1" in '' | /* | */ | *//*) return 1 ;; esac
    vr_rest=$1
    while :; do
        case "${vr_rest%%/*}" in . | .. | *[!A-Za-z0-9._-]*) return 1 ;; esac
        case "$vr_rest" in
            */*) vr_rest=${vr_rest#*/} ;;
            *) return 0 ;;
        esac
    done
}

# Succeed when no part of ROOT/SUB that exists is a symbolic link or anything
# but a directory. SUB may be empty.
clear_path() {
    cp_path=$1
    cp_rest=$2
    while [ -n "$cp_rest" ]; do
        cp_path=$cp_path/${cp_rest%%/*}
        case "$cp_rest" in
            */*) cp_rest=${cp_rest#*/} ;;
            *) cp_rest= ;;
        esac
        [ -L "$cp_path" ] && return 1
        if [ -e "$cp_path" ] && [ ! -d "$cp_path" ]; then
            return 1
        fi
    done
    return 0
}

# Make the missing directories of ROOT/SUB, 0700; fail on a symbolic link
# or anything but a directory on the way.
make_dirs() {
    md_path=$1
    md_rest=$2
    while [ -n "$md_rest" ]; do
        md_path=$md_path/${md_rest%%/*}
        case "$md_rest" in
            */*) md_rest=${md_rest#*/} ;;
            *) md_rest= ;;
        esac
        if [ ! -e "$md_path" ] && [ ! -L "$md_path" ]; then
            mkdir -m 0700 -- "$md_path" || return 1
        fi
        if [ -L "$md_path" ] || [ ! -d "$md_path" ]; then
            return 1
        fi
    done
    return 0
}

# Succeed when PATH, not a link, is what KIND names: a directory for d, a
# regular file for F and f.
is_kind() {
    case "$1" in
        d) [ -d "$2" ] && [ ! -L "$2" ] ;;
        *) [ -f "$2" ] && [ ! -L "$2" ] ;;
    esac
}

kind_name() {
    case "$1" in
        d) printf 'directory' ;;
        *) printf 'regular file' ;;
    esac
}

# Rename SRC to DST, which must not exist: -T never moves SRC into a
# directory at DST, and -n never replaces anything there. mv -n skips an
# existing DST and still succeeds, so SRC must be gone afterwards.
move() {
    mv -T -n -- "$1" "$2" || return 1
    if [ -e "$1" ] || [ -L "$1" ]; then
        printf 'state-link: %s: %s appeared first\n' "$1" "$2" >&2
        return 1
    fi
    return 0
}

# The directory this run sets the home's copies aside in, made on first use:
# /state/home/.den-set-aside/<UTC time>, with .<n> added to the time when that
# name is taken. mkdir makes a new directory or fails, also on a link.
make_aside() {
    [ -n "$aside" ] && return 0
    ma_root=$volume/.den-set-aside
    if [ ! -e "$ma_root" ] && [ ! -L "$ma_root" ]; then
        mkdir -m 0700 -- "$ma_root" || return 1
    fi
    if [ -L "$ma_root" ] || [ ! -d "$ma_root" ]; then
        printf 'state-link: %s is not a directory\n' "$ma_root" >&2
        return 1
    fi
    ma_try=$ma_root/$stamp
    ma_n=0
    while ! ma_err=$(mkdir -m 0700 -- "$ma_try" 2>&1); do
        # Only a name that is taken gets another try.
        if [ ! -e "$ma_try" ] && [ ! -L "$ma_try" ]; then
            printf '%s\n' "$ma_err" >&2
            return 1
        fi
        ma_n=$((ma_n + 1))
        [ "$ma_n" -le 99 ] || return 1
        ma_try=$ma_root/$stamp.$ma_n
    done
    aside=$ma_try
    return 0
}

# Link ~/REL to the volume's REL for one entry of KIND, or warn and skip it.
link_entry() {
    le_kind=$1
    le_rel=$2
    le_home=$home/$le_rel
    le_vol=$volume/$le_rel
    case "$le_rel" in
        */*) le_sub=${le_rel%/*} ;;
        *) le_sub= ;;
    esac
    if ! clear_path "$home" "$le_sub" || ! clear_path "$volume" "$le_sub"; then
        warn "$where: skipped $le_rel: a symbolic link or a file is on its way in $home or $volume"
        return
    fi
    if [ -L "$le_vol" ]; then
        warn "$where: skipped $le_rel: $le_vol is a symbolic link"
        return
    fi
    if [ -e "$le_vol" ]; then
        if ! is_kind "$le_kind" "$le_vol"; then
            warn "$where: skipped $le_rel: $le_vol is not a $(kind_name "$le_kind")"
            return
        fi
    elif [ -e "$le_home" ] && [ ! -L "$le_home" ]; then
        # The volume has none yet: the home's moves into it.
        if ! is_kind "$le_kind" "$le_home"; then
            warn "$where: skipped $le_rel: $le_home is not a $(kind_name "$le_kind")"
            return
        fi
        if ! make_dirs "$volume" "$le_sub" || ! move "$le_home" "$le_vol"; then
            warn "$where: skipped $le_rel: could not move $le_home into $volume"
            return
        fi
    else
        case "$le_kind" in
            f) return ;;
            d) make_dirs "$volume" "$le_sub" && mkdir -m 0700 -- "$le_vol" ;;
            F) make_dirs "$volume" "$le_sub" && (set -C && : > "$le_vol") ;;
        esac || {
            warn "$where: skipped $le_rel: could not make $le_vol"
            return
        }
    fi
    if [ -L "$le_home" ]; then
        [ "$(readlink -- "$le_home")" = "$le_vol" ] && return
        # -n replaces a link to a directory instead of linking inside it.
        ln -sfnT -- "$le_vol" "$le_home" \
            || warn "$where: skipped $le_rel: could not replace the link $le_home"
        return
    fi
    if [ -e "$le_home" ]; then
        # Both have one: the volume's stays. An empty directory holds nothing
        # to keep; anything else goes aside in the volume, which outlives the
        # container's layer.
        if ! { [ -d "$le_home" ] && rmdir -- "$le_home" 2>/dev/null; }; then
            if ! make_aside || ! make_dirs "$aside" "$le_sub" \
                || ! move "$le_home" "$aside/$le_rel"; then
                warn "$where: skipped $le_rel: could not set $le_home aside"
                return
            fi
            warn "$where: $le_vol and $le_home both existed: kept $le_vol, moved $le_home to $aside/$le_rel"
        fi
    fi
    if ! make_dirs "$home" "$le_sub" || ! ln -snT -- "$le_vol" "$le_home"; then
        warn "$where: skipped $le_rel: could not link $le_home to $le_vol"
    fi
}

# Apply LIST a line at a time, its last line too when it has no newline.
apply_list() {
    al_n=0
    while IFS= read -r al_line <&3 || [ -n "$al_line" ]; do
        al_n=$((al_n + 1))
        where=$1:$al_n
        case "$al_line" in
            '' | '#'*) continue ;;
            [dFf]' '*) al_why= ;;
            *) al_why="not '<kind> <path>' with a kind of d, F or f" ;;
        esac
        if [ -z "$al_why" ] && ! valid_rel "${al_line#? }"; then
            al_why="the path must be relative, with names of letters, digits, '.', '_' and '-' that are not '.' or '..'"
        fi
        if [ -n "$al_why" ]; then
            # The line as the log shows it: a control character becomes '?'.
            warn "$where: skipped '$(printf '%s' "$al_line" | tr -c '[:print:]' '?')': $al_why"
            continue
        fi
        link_entry "${al_line%% *}" "${al_line#? }"
    done 3< "$1"
}

if ! own_dir "$home"; then
    warn "HOME ($home) is not a directory of this user's; nothing is linked"
    exit 1
fi
if ! own_dir "$volume"; then
    warn "$volume is not a directory of this user's; nothing is linked"
    exit 1
fi
for list in "$lists_dir"/*.list; do
    if [ -f "$list" ] && [ -r "$list" ]; then
        apply_list "$list"
    elif [ -e "$list" ] || [ -L "$list" ]; then
        warn "skipped $list: not a readable regular file"
    fi
done
# The environment's own list is read from the volume, where the user keeps
# it: only a regular file of the user's, with no symbolic link on its way.
if [ -e "$env_list" ] || [ -L "$env_list" ]; then
    if clear_path "$volume" .config/den && [ ! -L "$env_list" ] && [ -f "$env_list" ] \
        && [ -O "$env_list" ] && [ -r "$env_list" ]; then
        apply_list "$env_list"
    else
        warn "skipped $env_list: not a readable regular file of this user's, or a symbolic link is on its way"
    fi
fi
exit "$status"
STATE_LINK
chmod 0755 /usr/local/lib/den/state-link
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
        # A ~/.zsh_history that is a link into the state volume is rewritten
        # in place: by default zsh writes a new file beside the link and
        # renames it over the link, which leaves the history in the
        # container's layer. Without the link, zsh keeps its default, under
        # which an interrupted save loses no history.
        if [[ -L $HOME/.zsh_history ]]; then
            setopt no_hist_save_by_copy
        fi
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
