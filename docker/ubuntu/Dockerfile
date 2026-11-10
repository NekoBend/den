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
ARG RUSTUP_VERSION=1.29.3
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
ARG BOTTOM_VERSION=0.15.0
# renovate: datasource=crate depName=du-dust versioning=semver
ARG DU_DUST_VERSION=1.2.7
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

# den as a BuildKit git source, at DEN_REF: a branch, a tag or a commit. Every
# build resolves a branch to a commit, so the den step below reruns exactly when
# it moves; a RUN that cloned den itself would stay cached on the first build's
# den. A commit stays put, so a build can hold den at one it has reviewed.
FROM scratch AS den-src
ARG DEN_REF=main
ADD https://github.com/NekoBend/den.git#${DEN_REF} /

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
tmp_dir=/tmp
# The workspace, which FIX_WORKSPACE_OWNERSHIP=1 re-owns.
workspace_dir=/workspace
# The mount table, which names each mount point by its physical path.
mountinfo=/proc/self/mountinfo
# A home that cannot exist, as nothing can be below the character device
# /dev/null: the account has it while usermod gives it its new IDs.
no_home=/dev/null/no-home
# Fixed image paths, patched as literals by the script tests.
root_hooks=/etc/denbox/init.d
user_hooks=/etc/denbox/user-init.d
# shellcheck source=/dev/null
. /usr/local/lib/denbox/dropins.sh

fail() { printf '%s\n' "$*" >&2; exit 2; }
warn() { printf 'container-entrypoint: %s\n' "$*" >&2; }
valid_id() {
    case "$1" in ''|0|0*|*[!0-9]*) return 1 ;; esac
    [ "${#1}" -le 10 ] && [ "$1" -le 2147483647 ]
}
# Succeed when DIR is a mount point of its own, not a symbolic link to one.
own_mount() { [ ! -L "$1" ] && mountpoint -q "$1"; }
# The awk function that decodes a mount point as the mount table writes it:
# the table writes a space, tab, newline or backslash in one as a backslash
# and three octal digits.
unescape_awk='
    function unescape(s,    out, i, d) {
        out = ""
        while ((i = index(s, "\\")) > 0) {
            d = substr(s, i + 1, 3)
            if (d ~ /^[0-7][0-7][0-7]$/) {
                out = out substr(s, 1, i - 1) sprintf("%c", \
                    substr(d, 1, 1) * 64 + substr(d, 2, 1) * 8 + substr(d, 3, 1))
                s = substr(s, i + 4)
            } else {
                out = out substr(s, 1, i)
                s = substr(s, i + 1)
            }
        }
        return out s
    }
'
# Print the first mount point the mount table lists below DIR, and succeed;
# fail with 1 when there is none, and with 2 when the table cannot be read.
# find -xdev compares device numbers alone, and a mount of the same file
# system below DIR (a second named volume, or a bind mount) has the same one,
# so a walk of DIR as root asks this first.
mount_below() {
    mb_dir=$(cd -P -- "$1" && pwd -P) || return 2
    [ -r "$mountinfo" ] || return 2
    mb_dir=$mb_dir awk "$unescape_awk"'
        BEGIN {
            dir = ENVIRON["mb_dir"]
            below = (dir == "/") ? "/" : dir "/"
            found = 0
        }
        {
            m = unescape($5)
            if (m != dir && index(m, below) == 1) {
                print m
                found = 1
                exit
            }
        }
        END { exit (found ? 0 : 1) }
    ' "$mountinfo"
}
# Give what in DIR has the old UID the new one, and what has the old GID the
# new one, each on its own and leaving other owners alone, as chown -h does:
# no symbolic link is followed (uutils 0.8.0 chown -h follows directory links,
# so this is GNU chown), and -xdev keeps the walk on DIR's file system. For
# the reason above, the walk also leaves out each mount point the table lists
# below DIR, with all it holds, and a warning names them. When the table
# cannot be read, a warning says so and the walk goes on with -xdev alone.
# When cd cannot enter DIR, find cannot walk below it either, and there is
# nothing to leave out. When the operands that leave them out would pass
# 64 KiB, a warning says how many mount points there are, and nothing in DIR
# is re-owned: Linux can give exec as little as 128 KiB for a command's
# arguments and environment together, and find could not start. The
# environment the start inherited takes none of that: the function runs in
# a subshell, which keeps what it needs in its positional parameters and
# then unsets each variable of the environment, as awk names them, so that
# awk and find, and the gnuchown that find starts, get PATH (the
# entrypoint's own) and LC_ALL=C alone; and OPTIND=1 when the environment
# had OPTIND, which dash sets to 1 and cannot unset. (env -i in front of
# find would not do: its own exec would take the operands and the whole
# environment.) Return find's status, or 0 when there is no walk, or 1 when
# awk cannot name the variables.
reown() (
    set -- "$1" "$old_uid" "$old_gid" "$target_uid" "$target_gid" \
        "$mountinfo" "$unescape_awk"
    ro_unset=$(LC_ALL=C awk 'BEGIN {
        for (name in ENVIRON)
            if (name != "PATH" && name != "OPTIND" &&
                name ~ /^[A-Za-z_][A-Za-z0-9_]*$/)
                print "unset -v " name
    }') || exit 1
    eval "$ro_unset"
    ro_dir=$1 old_uid=$2 old_gid=$3 target_uid=$4 target_gid=$5
    ro_table=$6 ro_awk=$7 LC_ALL=C
    export LC_ALL
    ro_code=
    if ro_phys=$(cd -P -- "$ro_dir" 2>/dev/null && pwd -P); then
        # The awk program prints the shell commands that set the find
        # operands which leave each mount point out, and ro_left to their
        # names, or ro_many to how many there are when the operands would
        # pass the limit. -path takes a pattern: a backslash goes before each
        # backslash, *, ? and [ in a path, so that it matches the path alone.
        # LC_ALL=C, as set above, makes length count bytes.
        if ! { [ -r "$ro_table" ] && ro_code=$(ro_dir=$ro_dir ro_phys=$ro_phys awk "$ro_awk"'
            function quote(s,    out, i) {
                out = ""
                while ((i = index(s, "\047")) > 0) {
                    out = out substr(s, 1, i - 1) "\047\\\047\047"
                    s = substr(s, i + 1)
                }
                return "\047" out s "\047"
            }
            function literal(s,    out, c, i) {
                out = ""
                for (i = 1; i <= length(s); i++) {
                    c = substr(s, i, 1)
                    if (index("\\*?[", c) > 0)
                        out = out "\\"
                    out = out c
                }
                return out
            }
            BEGIN {
                phys = ENVIRON["ro_phys"]
                below = (phys == "/") ? "/" : phys "/"
                dir = ENVIRON["ro_dir"]
                under = (dir ~ /\/$/) ? dir : dir "/"
                n = 0
                size = 0
                limit = 65536
            }
            {
                m = unescape($5)
                if (m != phys && index(m, below) == 1 && !(m in seen)) {
                    seen[m] = 1
                    n++
                    # Past the limit, only the count goes on.
                    if (size <= limit) {
                        path = under substr(m, length(below) + 1)
                        pattern = literal(path)
                        # -o, -path and the pattern, each with its NUL and
                        # its 8-byte pointer.
                        size += length(pattern) + 34
                        prune = prune (n > 1 ? " -o" : "") " -path " quote(pattern)
                        left = left (n > 1 ? ", " : "") path
                    }
                }
            }
            END {
                if (size > limit)
                    print "ro_many=" n
                else if (n > 0) {
                    print "set -- \\(" prune " \\) -prune -o"
                    print "ro_left=" quote(left)
                }
            }
        ' "$ro_table"); }; then
            ro_code=
            warn "could not read the mount table $ro_table, so re-owning $ro_dir from $old_uid:$old_gid may go into a mount point below it of the same file system"
        fi
    fi
    ro_left=
    ro_many=
    set --
    eval "$ro_code"
    if [ -n "$ro_many" ]; then
        warn "re-owning $ro_dir from $old_uid:$old_gid would have to leave out $ro_many mount points below it, too many for one find command, so nothing in $ro_dir is re-owned"
        exit 0
    fi
    [ -z "$ro_left" ] \
        || warn "re-owning $ro_dir from $old_uid:$old_gid leaves out each mount point below it and all it holds: $ro_left"
    find "$ro_dir" -xdev "$@" \( -uid "$old_uid" -o -gid "$old_gid" \) \
        -exec /usr/bin/gnuchown -h --from="$old_uid" "$target_uid" {} + \
        -exec /usr/bin/gnuchown -h --from=":$old_gid" ":$target_gid" {} +
)

# Every candidate is checked before execution; hooks keep the caller's locale.
run_hooks() (
    hook_kind=$2
    denbox_names "$1" ''
    set --
    while IFS= read -r hook; do
        [ -z "$hook" ] || set -- "$@" "$hook"
    done <<EOF
$_denbox_names
EOF
    for hook do
        [ -e "$hook" ] || [ -L "$hook" ] || continue
        if ! denbox_trusted "$hook"; then
            if [ "$hook_kind" = root ]; then
                fail "Untrusted root hook: $hook"
            fi
            warn "skipped untrusted user hook: $hook"
            continue
        fi
        [ -x "$hook" ] || continue
        hook_status=0
        if [ "$hook_kind" = root ]; then
            (
                cd / || exit 1
                HOME=/root
                export HOME
                "$hook" "$user_home" "$target_uid" "$target_gid" < /dev/null
            ) || hook_status=$?
            [ "$hook_status" = 0 ] || fail "Root hook failed ($hook_status): $hook"
        else
            /usr/bin/gnutimeout -k 10 300 \
                /usr/bin/setpriv --reuid "$target_uid" --regid "$target_gid" --init-groups \
                /usr/bin/env -i HOME="$user_home" PATH=/usr/sbin:/usr/bin:/sbin:/bin \
                /bin/sh -c '
                    if [ ! -x "$1" ]; then
                        printf "denbox: user hook not executable by %s: %s\n" "$0" "$1" >&2
                        exit 0
                    fi
                    exec "$@"
                ' "$username" "$hook" < /dev/null || hook_status=$?
            if [ "$hook_status" != 0 ]; then
                warn "user hook failed or timed out ($hook_status): $hook"
            fi
        fi
    done
)

IFS= read -r username < /etc/container-user
record=$(getent passwd "$username")
IFS=: read -r name password old_uid old_gid gecos user_home login_shell <<EOF
$record
EOF
[ "$user_home" = "/home/$username" ] && [ ! -L "$user_home" ] \
    || fail 'Unexpected or symlinked user home'
# Only trusted image lists are read here; env code runs after dropping root.
runtime_path=$(HOME="$user_home"; PATH="$inherited_path"; denbox_user_path; printf '%s' "$PATH")
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
denbox_state=${DENBOX_STATE:-1}
case "$denbox_state" in
    0|1) ;;
    *) fail 'DENBOX_STATE must be 0 or 1' ;;
esac
clean_tmp=${DENBOX_CLEAN_TMP:-0}
case "$clean_tmp" in
    0|1) ;;
    *) fail 'DENBOX_CLEAN_TMP must be 0 or 1' ;;
esac
# The state step runs unless DENBOX_STATE=0, and only for a mount point at
# /state: the image's own /state directory is in the container's layer.
use_state=0
if [ "$denbox_state" = 1 ] && own_mount "$state_dir"; then
    use_state=1
fi

if [ "$(id -u)" -eq 0 ]; then
    if [ "$target_uid:$target_gid" != "$old_uid:$old_gid" ]; then
        if [ "$target_uid" != "$old_uid" ] && getent passwd "$target_uid" >/dev/null; then
            fail 'HOST_UID already belongs to another account'
        fi
        # On overlayfs, re-owning a file copies it into the container's layer.
        printf '%s\n' "container-entrypoint: remapping $username from $old_uid:$old_gid to $target_uid:$target_gid re-owns $user_home, which on overlayfs copies all of it into each new container; build with --build-arg USER_UID=$target_uid --build-arg USER_GID=$target_gid to skip this." >&2
        # Change only matching IDs. Do this before the account gets its new
        # IDs so a failed workspace traversal leaves the original account IDs
        # available for a retry.
        if [ "$fix_workspace" = 1 ]; then
            [ -d "$workspace_dir" ] && [ ! -L "$workspace_dir" ] \
                || fail 'Workspace must be a directory, not a symlink'
            reown "$workspace_dir" || fail 'Workspace ownership adjustment failed'
        fi
        if ! getent group "$target_gid" >/dev/null; then
            groupadd --gid "$target_gid" "$username-$target_gid"
        fi
        # usermod --uid and --gid also re-own, in a walk of their own, what the
        # old IDs own in the home the account has, mount points below it and
        # all they hold included; reown does that, and leaves them out. So
        # the account has the home $no_home, which does not exist, while
        # usermod gives it its new IDs, and gets its home back from a usermod
        # with no --uid or --gid, which walks nothing. Neither moves anything
        # (no --move-home), and each holds the locks on the account files
        # that the other account tools take. After a failed second call the
        # account keeps $no_home, and each later start stops at the check of
        # the home above, so the message says to recreate the container.
        usermod --home "$no_home" --uid "$target_uid" --gid "$target_gid" "$username" \
            || fail "Could not give $username the IDs $target_uid:$target_gid"
        usermod --home "$user_home" "$username" \
            || fail "Could not give $username its home $user_home back after its new IDs; recreate the container"
        reown "$user_home"
        # The state volume holds the user's files with the old IDs too; the
        # same walk, which a failure does not stop the start for. With a mount
        # point below the volume, which -xdev would not keep the walk out of
        # when it is of the same file system, there is no walk at all.
        if [ "$use_state" = 1 ]; then
            nested_status=0
            nested=$(mount_below "$state_dir") || nested_status=$?
            case "$nested_status" in
                1)
                    find "$state_dir" -xdev \( -uid "$old_uid" -o -gid "$old_gid" \) \
                        -exec /usr/bin/gnuchown -h --from="$old_uid" "$target_uid" {} + \
                        -exec /usr/bin/gnuchown -h --from=":$old_gid" ":$target_gid" {} + \
                        || warn "re-owning $state_dir from $old_uid:$old_gid failed part way"
                    ;;
                0) warn "mount point $nested is below $state_dir, so nothing in $state_dir is re-owned from $old_uid:$old_gid; docker/README.md shows how to re-own a volume once" ;;
                *) warn "could not read the mount table $mountinfo, so nothing in $state_dir is re-owned from $old_uid:$old_gid; docker/README.md shows how to re-own a volume once" ;;
            esac
        fi
    fi
    # A bare workspace needs an owner even when recursive adjustment is disabled.
    if ! mountpoint -q "$workspace_dir"; then
        /usr/bin/gnuchown -h "$target_uid:$target_gid" "$workspace_dir"
    fi
    # /tmp is emptied only on request, and only when it is a mount point of
    # its own: a tmpfs or a volume, or a host directory bound there, which this
    # empties too (docker/README.md says never to bind one). The image's own
    # /tmp is left alone. A docker exec session started while this runs may
    # lose its files there. find does not follow symbolic links, so a link
    # cannot send a deletion elsewhere. -xdev keeps it out of other file
    # systems mounted below /tmp, but not out of a mount of the same one (a
    # second named volume, or a bind mount): with any mount point below /tmp,
    # nothing is deleted.
    if [ "$clean_tmp" = 1 ]; then
        if own_mount "$tmp_dir"; then
            nested_status=0
            nested=$(mount_below "$tmp_dir") || nested_status=$?
            case "$nested_status" in
                1)
                    find "$tmp_dir" -xdev -mindepth 1 -delete \
                        || warn 'some entries under /tmp were left in place'
                    ;;
                0) warn "DENBOX_CLEAN_TMP=1 empties /tmp only when no mount point is below it, and $nested is one; it is left as it is" ;;
                *) warn "DENBOX_CLEAN_TMP=1 empties /tmp only when no mount point is below it, and the mount table $mountinfo could not be read; it is left as it is" ;;
            esac
        else
            warn 'DENBOX_CLEAN_TMP=1 empties /tmp only when it is a mount point of its own; it is left as it is'
        fi
    fi
    # The state volume. Root only makes /state/home and gives /state and
    # /state/home, not what they hold, to the user, after checking that
    # neither is a symbolic link (chown -h would not follow one either).
    # state-link then links the home's paths into it as the user, so it never
    # reaches a file the user could not reach already. Its failures are
    # warnings: the start goes on. The user can make it wait (a FIFO swapped
    # in for the list it opens), so root waits for it 300 seconds at most;
    # GNU timeout, as for chown, also stops the commands state-link runs.
    # state-link itself waits 60 seconds at most for another run on the same
    # volume (a second container's start, or a run by hand) to end.
    state_ready=0
    if [ "$use_state" = 1 ]; then
        if [ -L "$state_dir/home" ]; then
            warn "$state_dir/home is a symbolic link; the home is not linked into $state_dir"
        elif { [ -d "$state_dir/home" ] || (umask 077 && /usr/bin/gnumkdir "$state_dir/home"); } \
            && [ ! -L "$state_dir/home" ] \
            && /usr/bin/gnuchown -h "$target_uid:$target_gid" "$state_dir" "$state_dir/home"; then
            state_ready=1
        else
            warn "could not prepare $state_dir/home; the home is not linked into $state_dir"
        fi
    fi
    run_hooks "$root_hooks" root || exit $?
    if [ "$state_ready" = 1 ]; then
        link_status=0
        /usr/bin/gnutimeout -k 10 300 \
            /usr/bin/setpriv --reuid "$target_uid" --regid "$target_gid" --init-groups \
            /usr/bin/env -i HOME="$user_home" PATH=/usr/sbin:/usr/bin:/sbin:/bin \
            /usr/local/lib/denbox/state-link \
            || link_status=$?
        case "$link_status" in
            0) ;;
            124) warn "state-link was stopped after 300 seconds, so the run was cut short; run /usr/local/lib/denbox/state-link as $username to finish it" ;;
            # GNU timeout's KILL, 10 seconds after its TERM, gives 137, and
            # so does any other KILL (the OOM killer, or kill -9).
            137) warn "state-link was killed, by the time limit or by a signal, so the run was cut short; run /usr/local/lib/denbox/state-link as $username to finish it" ;;
            *) warn 'state-link reported problems (see above)' ;;
        esac
    fi
    run_hooks "$user_hooks" user
    export HOME="$user_home" USER="$username" LOGNAME="$username" SHELL="$login_shell"
    exec /usr/bin/setpriv --reuid "$target_uid" --regid "$target_gid" --init-groups \
        /usr/bin/env PATH="$runtime_path" /usr/local/lib/denbox/user-exec "$@"
fi

[ "$fix_workspace" = 0 ] \
    || fail 'FIX_WORKSPACE_OWNERSHIP requires root initialization; omit --user or use --user 0'
[ "$(id -u):$(id -g)" = "$target_uid:$target_gid" ] \
    || fail 'UID/GID adjustment requires root initialization; omit --user or rebuild with matching USER_UID/USER_GID'
if [ "$use_state" = 1 ]; then
    warn "$state_dir is mounted, but only a root start links the home into it; omit --user, or set DENBOX_STATE=0"
fi
if [ "$clean_tmp" = 1 ]; then
    warn 'DENBOX_CLEAN_TMP=1 needs a root start; /tmp is left as it is'
fi
export PATH="$runtime_path" HOME="$user_home" USER="$username" LOGNAME="$username" SHELL="$login_shell"
exec /usr/local/lib/denbox/user-exec "$@"
ENTRYPOINT
chmod 0755 /usr/local/bin/container-entrypoint

# The state volume (docker/README.md, "What survives where"). /state is a
# mount point the user owns. There is no VOLUME instruction: an image built
# FROM this one could never take one away.
install -d -o "$USER_UID" -g "$USER_GID" -m 0700 /state
install -d -m 0755 /etc/denbox /etc/denbox/state-paths.d /usr/local/lib/denbox
install -d -m 0755 /etc/denbox/init.d /etc/denbox/user-init.d \
    /etc/denbox/user-env.d /etc/denbox/user-path.d
cat > /etc/denbox/user-path.d/denbox.list <<'USER_PATHS'
# One directory per line, relative to HOME or absolute, in PATH order.
.nvm/current/bin
.local/bin
.cargo/bin
USER_PATHS
cat > /usr/local/lib/denbox/dropins.sh <<'DROPINS'
# Shared by dash, bash and zsh. No caller-controlled search path or config.
# local is supported by all three shells; zsh options belong in zshenv.
_denbox_shell_trusted=0
# Shell startup can check all fixed parents and candidates in one process.
# On any failure, fall back to the per-file ancestor checks and diagnostics.
denbox_shell_trust() {
    local bad
    _denbox_shell_trusted=0
    # A subshell, so the caller's -f and failglob do not reach the expansion. A
    # failglob error ends only the subshell, and the per-file checks take over.
    if bad=$(
        exec 2>/dev/null
        set +f
        set -- / /etc /etc/denbox /etc/denbox/user-path.d /etc/denbox/user-env.d
        for file in /etc/denbox/user-path.d/*.list /etc/denbox/user-env.d/*.sh; do
            [ -e "$file" ] || [ -L "$file" ] || continue
            set -- "$@" "$file"
        done
        cd / && exec /usr/bin/find "$@" -maxdepth 0 \
            \( ! -uid 0 -o -perm /022 -o -type l \) -print -quit
    ); then
        [ -n "$bad" ] || _denbox_shell_trusted=1
    fi
}
# Linux supplies the effective UID without a process; read the account using
# shell builtins too. Never trust inherited EUID, USER or LOGNAME.
denbox_shell_identity() {
    local key real effective rest name password account_uid
    _denbox_uid=''
    _denbox_is_user=0
    {
        while read -r key real effective rest; do
            [ "$key" = Uid: ] || continue
            _denbox_uid=$effective
            break
        done < /proc/self/status
    } 2>/dev/null || :
    case "$_denbox_uid" in
        ''|*[!0-9]*)
            _denbox_uid=$(/usr/bin/id -u 2>/dev/null) || _denbox_uid=''
            ;;
    esac
    case "$_denbox_uid" in
        ''|*[!0-9]*) _denbox_uid=''; return 0 ;;
    esac
    while IFS=: read -r name password account_uid rest; do
        [ "$name" = "$_container_user" ] || continue
        [ "$account_uid" != "$_denbox_uid" ] || _denbox_is_user=1
        break
    done < /etc/passwd
}
denbox_trusted() {
    [ ! -L "$1" ] && [ -f "$1" ] || return 1
    [ "${_denbox_shell_trusted:-0}" != 1 ] || return 0
    denbox_trusted_walk "$1"
}
denbox_trusted_walk() (
    # Check every ancestor too: a writable parent can replace a trusted file.
    candidate=$1
    while :; do
        [ ! -L "$candidate" ] || exit 1
        metadata=$(/usr/bin/gnustat -c '%u:%a' -- "$candidate") || exit 1
        owner=${metadata%%:*} mode=${metadata#*:}
        case "$mode" in ''|*[!0-7]*) exit 1 ;; esac
        [ "$owner" = 0 ] || exit 1
        # Test the permission digits without shell-dependent octal arithmetic.
        case "$mode" in *[2367][0-7]|*[2367]) exit 1 ;; esac
        [ "$candidate" != / ] || exit 0
        candidate=${candidate%/*}
        [ -n "$candidate" ] || candidate=/
        [ -d "$candidate" ] || exit 1
    done
)
# Return newline-separated names in byte order. The subshell keeps the caller's
# locale, -f and failglob as they are; a failglob error means no names. Hidden
# names are dropped by hand, as dotglob or globdots would expand them. No comment
# with a quote inside the substitution: an interactive zsh parses it as code.
# The caller reconstructs argv before sourcing, so env files keep their stdin.
denbox_names() {
    local directory=$1 suffix=$2
    _denbox_names=$(
        exec 3>&2 2>/dev/null
        set +f
        LC_ALL=C
        export LC_ALL
        for file in "$directory"/*"$suffix"; do
            [ -e "$file" ] || [ -L "$file" ] || continue
            case "${file##*/}" in .*) continue ;; esac
            case "$file" in
                *'
'*) printf 'denbox: skipped drop-in name containing a newline: %s\n' \
                    "$directory" >&3; continue ;;
            esac
            printf '%s\n' "$file"
        done
    ) || _denbox_names=''
}
# Build a prefix in list/line order, preserving the inherited PATH suffix.
denbox_user_path() {
    local list line prefix='' dir _denbox_names
    denbox_names /etc/denbox/user-path.d .list
    set --
    while IFS= read -r list; do
        [ -z "$list" ] || set -- "$@" "$list"
    done <<EOF
$_denbox_names
EOF
    for list do
        [ -e "$list" ] || [ -L "$list" ] || continue
        if ! denbox_trusted "$list"; then
            printf 'denbox: skipped untrusted path list %s\n' "$list" >&2
            continue
        fi
        if [ ! -r "$list" ]; then
            printf 'denbox: skipped unreadable path list %s\n' "$list" >&2
            continue
        fi
        while IFS= read -r line || [ -n "$line" ]; do
            case "$line" in ''|\#*) continue ;; esac
            case "$line" in
                *:*) printf 'denbox: skipped invalid PATH entry in %s\n' "$list" >&2; continue ;;
                /*) dir=$line ;;
                *) dir=$HOME/$line ;;
            esac
            case ":${PATH}:${prefix}:" in *":$dir:"*) continue ;; esac
            prefix=${prefix:+$prefix:}$dir
        done < "$list"
    done
    # Existing entries, including duplicates and empty fields, stay untouched.
    PATH=${prefix:+$prefix:}$PATH
    export PATH
}
# Only call this after identity has been checked or privileges dropped.
denbox_user_env() {
    local file saved_options dry_run=1 _denbox_names
    denbox_names /etc/denbox/user-env.d .sh
    [ -n "$_denbox_names" ] || return 0
    # Only normal bash, interactive POSIX bash and zsh catch source errors. A
    # subscript is a bad substitution in dash and fine in those; the version
    # variables prove nothing, as dash takes them from the environment.
    if ( set +u; eval ': "${_denbox_probe[0]}"' ) >/dev/null 2>&1; then
        dry_run=0
        case :${SHELLOPTS-}: in
            *:posix:*) case $- in *i*) ;; *) dry_run=1 ;; esac ;;
        esac
    fi
    set --
    while IFS= read -r file; do
        [ -z "$file" ] || set -- "$@" "$file"
    done <<EOF
$_denbox_names
EOF
    for file do
        [ -e "$file" ] || [ -L "$file" ] || continue
        if denbox_trusted "$file"; then
            if [ ! -r "$file" ]; then
                printf 'denbox: skipped unreadable env file %s\n' "$file" >&2
                continue
            fi
            # A missing dot target or a bad special builtin can kill dash
            # even in an if condition. Parse-only checks cannot detect that.
            if [ "$dry_run" = 1 ] && ! (
                set +eu
                . "$file"
                exit 0
            ) >/dev/null 2>&1; then
                printf 'denbox: skipped env file that aborts the shell: %s; source it in this shell to see the error\n' \
                    "$file" >&2
                continue
            fi
            saved_options=$-
            set +eu
            # shellcheck source=/dev/null
            if . "$file"; then
                :
            else
                printf 'denbox: env file returned non-zero: %s\n' "$file" >&2
            fi
            case "$saved_options" in *u*) set -u ;; *) set +u ;; esac
            case "$saved_options" in *e*) set -e ;; *) set +e ;; esac
        else
            printf 'denbox: skipped untrusted env file %s\n' "$file" >&2
        fi
    done
}
DROPINS
cat > /usr/local/lib/denbox/user-exec <<'USER_EXEC'
#!/bin/sh
# This wrapper is entered only as the container user, never as root.
set +eu
# shellcheck source=/dev/null
. /usr/local/lib/denbox/dropins.sh
denbox_user_env
exec "$@"
USER_EXEC
chmod 0644 /etc/denbox/user-path.d/denbox.list /usr/local/lib/denbox/dropins.sh
chmod 0755 /usr/local/lib/denbox/user-exec
cat > /etc/denbox/state-paths.d/denbox.list <<'STATE_PATHS'
# The image's paths of the user's home kept in the state volume at
# /state/home, one "<kind> <path>" per line, the path relative to the home:
#   d  a directory, created in the volume when missing
#   F  a file, created empty in the volume when missing
#   f  a file, linked only once the volume or the home has one
# An image built FROM this one adds its own in a <name>.list file here; one
# environment adds its own in ~/.config/denbox/state-paths, in the volume.
d .ssh
F .gitconfig
F .zsh_history
F .bash_history
d .config/gh
d .config/rclone
d .local/share/zoxide
d .local/share/powershell/PSReadLine
d .config/den
d .config/denbox
d .vscode-server
STATE_PATHS
chmod 0644 /etc/denbox/state-paths.d/denbox.list
cat > /usr/local/lib/denbox/state-link <<'STATE_LINK'
#!/bin/sh
# Ubuntu's /bin/sh is dash, which has test -O and -ef, and local.
# shellcheck shell=dash
# state-link - keep paths of the user's home in the state volume.
# container-entrypoint runs it as the user at each root start, once /state/home
# is the user's; run by hand, it applies the lists again. For each
# "<kind> <path>" line of the lists it links ~/<path> to /state/home/<path>
# (kinds: /etc/denbox/state-paths.d/denbox.list). The lists are every
# /etc/denbox/state-paths.d/*.list, then the environment's own
# /state/home/.config/denbox/state-paths.
# A path the home has and the volume does not moves into the volume. When both
# have a file, the volume's stays and the home's moves to
# /state/home/.denbox-set-aside/<UTC time>/<path>. When both have a directory,
# each name in the home's moves into the volume's, a directory both have is
# merged the same way, and any other name both have goes aside; a directory
# with anything in it this user cannot move is left whole. A move copies into
# /state/home/.denbox-staging, renames the whole copy into place, and only then
# removes the home's, so the home's goes only once the volume holds all of it.
# A run stopped by a signal removes the copy it was making; a copy that an
# earlier run left there (one that KILL or a crash stopped) is set aside,
# never deleted and never taken for the volume's. Runs on one volume take
# turns: each holds a lock on /state/home/.denbox-lock.
# Nothing is done through a symbolic link or on a mount point: an entry with a
# link on its way, in the home or in the volume, is skipped, and so is one
# whose path in the home is a mount point, is below one other than /, or has
# one below it (a host directory bound into the home), and one whose path in
# the volume is a mount point, is below one or has one below it, counting the
# mount points below the volume alone. A move renames its copy into place,
# and a rename to another file system is a copy again: with a mount point at,
# above or inside .denbox-staging or .denbox-set-aside, nothing moves through it.
# A bad line and an entry that fails are warnings, and the next line goes on;
# the exit status is 1 when there was one. A set-aside is a note, which leaves
# the status alone.
# HOME, DENBOX_STATE_ROOT (default /state), DENBOX_STATE_LISTS (default
# /etc/denbox/state-paths.d) and DENBOX_STATE_MOUNTINFO (default
# /proc/self/mountinfo) name what it reads, and DENBOX_STATE_LOCK_WAIT (default
# 60) how many seconds it waits for another run, so tests can run it
# elsewhere.
set -u
export LC_ALL=C
umask 077

state_root=${DENBOX_STATE_ROOT:-/state}
lists_dir=${DENBOX_STATE_LISTS:-/etc/denbox/state-paths.d}
mountinfo=${DENBOX_STATE_MOUNTINFO:-/proc/self/mountinfo}
lock_wait=${DENBOX_STATE_LOCK_WAIT:-60}
case "$lock_wait" in '' | *[!0-9]*) lock_wait=60 ;; esac
stamp=$(date -u +%Y%m%dT%H%M%SZ)
aside=
where=
status=0
# The staging copy a move is making, while it makes it.
copying=

warn() { printf 'state-link: %s\n' "$*" >&2; status=1; }
# Something this run did that the user should know of, and no failure.
note() { printf 'state-link: %s\n' "$*" >&2; }

# A signal (the entrypoint's time limit sends TERM) stops the run, and the
# copy it was making goes: the home still has all of that path. The traps
# below call it.
# shellcheck disable=SC2329
stopped() {
    if [ -n "$copying" ]; then
        rm -rf -- "$copying"
        printf 'state-link: stopped by a signal; removed %s, the unfinished copy it was making\n' \
            "$copying" >&2
    else
        printf 'state-link: stopped by a signal\n' >&2
    fi
    exit "$1"
}
trap 'stopped 129' HUP
trap 'stopped 130' INT
trap 'stopped 143' TERM

# Succeed when DIR is an absolute path to a directory this user owns, not a
# symbolic link.
own_dir() {
    case "$1" in /*) ;; *) return 1 ;; esac
    # test -O is not POSIX; dash, the image's /bin/sh, has it.
    # shellcheck disable=SC3067
    [ -d "$1" ] && [ ! -L "$1" ] && [ -O "$1" ]
}

# Print the physical path of DIR, which own_dir must accept with its trailing
# slashes taken off, and succeed. The mount table names mount points by their
# physical paths, so HOME=/home/dev/ or /home/./dev must not hide one.
canon_dir() {
    cd_dir=$1
    while :; do
        case "$cd_dir" in
            ?*/) cd_dir=${cd_dir%/} ;;
            *) break ;;
        esac
    done
    own_dir "$cd_dir" && cd_dir=$(cd -P -- "$cd_dir" && pwd -P) && own_dir "$cd_dir" \
        && printf '%s\n' "$cd_dir"
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

# Print the first mount point of the mount table that PATH is, is below or has
# below it, and succeed; fail with 1 when there is none. A mount point at or
# above BASE (default /), the one PATH is meant to be on, does not count. The
# table writes a space, tab, newline or backslash in a mount point as a
# backslash and three octal digits.
mount_on() {
    mo_path=$1 mo_base=${2:-/} awk '
        function unescape(s,    out, i, d) {
            out = ""
            while ((i = index(s, "\\")) > 0) {
                d = substr(s, i + 1, 3)
                if (d ~ /^[0-7][0-7][0-7]$/) {
                    out = out substr(s, 1, i - 1) sprintf("%c", \
                        substr(d, 1, 1) * 64 + substr(d, 2, 1) * 8 + substr(d, 3, 1))
                    s = substr(s, i + 4)
                } else {
                    out = out substr(s, 1, i)
                    s = substr(s, i + 1)
                }
            }
            return out s
        }
        BEGIN { path = ENVIRON["mo_path"]; base = ENVIRON["mo_base"]; found = 0 }
        {
            m = unescape($5)
            if (m == "/" || m == base || index(base, m "/") == 1)
                next
            if (m == path || index(path, m "/") == 1 || index(m, path "/") == 1) {
                print m
                found = 1
                exit
            }
        }
        END { exit (found ? 0 : 1) }
    ' "$mountinfo"
}

# Succeed when DIR, a path in the volume, is on the volume's own file system:
# no mount point below the volume is at, above or inside it. Otherwise say
# which and fail. A move renames its copy from the staging directory to a
# path in the volume or the set-aside directory, and a rename to another file
# system is a copy, which a stop leaves part done.
on_volume() {
    ov_mount=$(mount_on "$1" "$volume")
    case $? in
        1) return 0 ;;
        0) printf 'state-link: mount point %s is at, above or inside %s\n' "$ov_mount" "$1" >&2 ;;
        *) printf 'state-link: %s: could not read the mount table %s\n' "$1" "$mountinfo" >&2 ;;
    esac
    return 1
}

# The directory moves copy into, /state/home/.denbox-staging, made on first use.
make_staging() {
    on_volume "$staging" || return 1
    if [ ! -e "$staging" ] && [ ! -L "$staging" ]; then
        mkdir -m 0700 -- "$staging" || return 1
    fi
    if [ -L "$staging" ] || [ ! -d "$staging" ]; then
        printf 'state-link: %s is not a directory\n' "$staging" >&2
        return 1
    fi
}

# Set slot to the staging name of REL: its path with ':' for '/'.
set_slot() {
    slot=
    ss_rest=$1
    while :; do
        slot=$slot${slot:+:}${ss_rest%%/*}
        case "$ss_rest" in
            */*) ss_rest=${ss_rest#*/} ;;
            *) break ;;
        esac
    done
    slot=$staging/$slot
}

# Succeed when this user can copy PATH and then remove it: its directory is
# writable, every directory in it readable, writable and searchable, and every
# file in it readable. find decides as access(2) does, so a read-only file
# system fails too. access(2) knows nothing of the sticky bit: in a sticky
# directory (mode 1000) another user owns, only the owner of a name may
# remove it, so such a directory in PATH fails, and so does PATH in one when
# this user does not own PATH.
removable() {
    rv_dir=${1%/*}
    [ -w "$rv_dir" ] || return 1
    rv_uid=$(id -u) || return 1
    rv_bad=$(find "$rv_dir" -maxdepth 0 -perm -1000 ! -uid "$rv_uid" -print 2>&1) || return 1
    if [ -n "$rv_bad" ]; then
        rv_bad=$(find "$1" -maxdepth 0 ! -uid "$rv_uid" -print 2>&1) || return 1
        [ -z "$rv_bad" ] || return 1
    fi
    rv_bad=$(find "$1" \( -type d \( ! -readable -o ! -writable -o ! -executable \
        -o -perm -1000 ! -uid "$rv_uid" \) -o -type f ! -readable \) -print -quit 2>&1) \
        || return 1
    [ -z "$rv_bad" ]
}

# Move SRC, a path of the home, to DST in the volume, which must not exist;
# REL, the path below the home, names the staging copy. Copy SRC there, rename
# the whole copy to DST, and only then remove SRC. A copy that fails is
# removed again, and SRC stays as it was.
transfer() {
    if ! removable "$1"; then
        printf 'state-link: %s: this user cannot read and remove all of it\n' "$1" >&2
        return 1
    fi
    make_staging || return 1
    set_slot "$3"
    if [ -e "$slot" ] || [ -L "$slot" ]; then
        printf 'state-link: %s is in the way\n' "$slot" >&2
        return 1
    fi
    copying=$slot
    if ! cp -a -T -- "$1" "$slot"; then
        rm -rf -- "$slot"
        copying=
        return 1
    fi
    # -T never moves the copy into a directory at DST, and -n never replaces
    # anything there; mv -n skips an existing DST and may still succeed.
    if ! mv -T -n -- "$slot" "$2" || [ -e "$slot" ] || [ -L "$slot" ]; then
        printf 'state-link: %s: could not rename it to %s\n' "$slot" "$2" >&2
        rm -rf -- "$slot"
        copying=
        return 1
    fi
    copying=
    if ! rm -rf -- "$1"; then
        printf 'state-link: %s: copied to %s, but not all of it could be removed\n' "$1" "$2" >&2
        return 1
    fi
}

# The directory this run sets the home's copies aside in, made on first use:
# /state/home/.denbox-set-aside/<UTC time>, with .<n> added to the time when that
# name is taken. mkdir makes a new directory or fails, also on a link.
make_aside() {
    [ -n "$aside" ] && return 0
    ma_root=$volume/.denbox-set-aside
    on_volume "$ma_root" || return 1
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

# Succeed when a directory above ~/REL is a link to the same directory in the
# volume, as an entry for that directory makes it.
covered() {
    cv_home=$home
    cv_vol=$volume
    cv_rest=$le_sub
    while [ -n "$cv_rest" ]; do
        cv_home=$cv_home/${cv_rest%%/*}
        cv_vol=$cv_vol/${cv_rest%%/*}
        case "$cv_rest" in
            */*) cv_rest=${cv_rest#*/} ;;
            *) cv_rest= ;;
        esac
        if [ -L "$cv_home" ]; then
            [ "$(readlink -- "$cv_home")" = "$cv_vol" ]
            return
        fi
    done
    return 1
}

# Make the volume's REL when it is missing: an empty directory for d, an empty
# file for F. Return 2 for an f entry that the volume does not have.
make_entry() {
    [ -e "$le_vol" ] && return 0
    case "$le_kind" in
        f) return 2 ;;
        d) make_dirs "$volume" "$le_sub" && mkdir -m 0700 -- "$le_vol" ;;
        *) make_dirs "$volume" "$le_sub" && (set -C && : > "$le_vol") ;;
    esac || return 1
}

# Both have directory REL: each name in the home's moves into the volume's, a
# directory both have is merged the same way, any other name both have goes
# aside, and a link to the same name in the volume's goes last, so that the
# entry it serves works until the rest has moved. Then the emptied directory
# goes. The caller checked that this user can move all of it.
merge_dir() {
    # local is not POSIX; dash, the image's /bin/sh, has it.
    # shellcheck disable=SC3043
    local mg_rel mg_home mg_name mg_vol mg_failed
    mg_rel=$1
    mg_failed=0
    for mg_home in "$home/$mg_rel"/* "$home/$mg_rel"/.[!.]* "$home/$mg_rel"/..?*; do
        [ -e "$mg_home" ] || [ -L "$mg_home" ] || continue
        mg_name=${mg_home##*/}
        mg_vol=$volume/$mg_rel/$mg_name
        if [ -L "$mg_home" ] && [ "$(readlink -- "$mg_home")" = "$mg_vol" ]; then
            continue
        elif [ ! -e "$mg_vol" ] && [ ! -L "$mg_vol" ]; then
            transfer "$mg_home" "$mg_vol" "$mg_rel/$mg_name" || mg_failed=1
        elif [ -d "$mg_home" ] && [ ! -L "$mg_home" ] && [ -d "$mg_vol" ] && [ ! -L "$mg_vol" ]; then
            merge_dir "$mg_rel/$mg_name" || mg_failed=1
        elif make_aside && make_dirs "$aside" "$mg_rel" \
            && transfer "$mg_home" "$aside/$mg_rel/$mg_name" "$mg_rel/$mg_name"; then
            note "$where: $mg_vol and $mg_home both existed: kept $mg_vol, moved $mg_home to $aside/$mg_rel/$mg_name"
        else
            mg_failed=1
        fi
    done
    [ "$mg_failed" = 0 ] || return 1
    for mg_home in "$home/$mg_rel"/* "$home/$mg_rel"/.[!.]* "$home/$mg_rel"/..?*; do
        if [ -L "$mg_home" ] && [ "$(readlink -- "$mg_home")" = "$volume/$mg_rel/${mg_home##*/}" ]; then
            rm -f -- "$mg_home" || return 1
        fi
    done
    rmdir -- "$home/$mg_rel"
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
    if ! clear_path "$volume" "$le_sub"; then
        warn "$where: skipped $le_rel: a symbolic link or a file is on its way in $home or $volume"
        return
    fi
    if [ -L "$le_vol" ]; then
        warn "$where: skipped $le_rel: $le_vol is a symbolic link"
        return
    fi
    if [ -e "$le_vol" ] && ! is_kind "$le_kind" "$le_vol"; then
        warn "$where: skipped $le_rel: $le_vol is not a $(kind_name "$le_kind")"
        return
    fi
    # The volume's path must be on the volume's own file system, as the
    # staging directory is: a move renames into it.
    le_mount=$(mount_on "$le_vol" "$volume")
    case $? in
        0)
            warn "$where: skipped $le_rel: mount point $le_mount is at, above or inside $le_vol"
            return
            ;;
        1) ;;
        *)
            warn "$where: skipped $le_rel: could not read the mount table $mountinfo"
            return
            ;;
    esac
    if covered; then
        # ~/REL is the volume's REL already, through the link above it.
        make_entry
        if [ $? -eq 1 ]; then
            warn "$where: skipped $le_rel: could not make $le_vol"
        fi
        return
    fi
    if ! clear_path "$home" "$le_sub"; then
        warn "$where: skipped $le_rel: a symbolic link or a file is on its way in $home or $volume"
        return
    fi
    le_mount=$(mount_on "$le_home")
    case $? in
        0)
            warn "$where: skipped $le_rel: mount point $le_mount is at, above or inside $le_home"
            return
            ;;
        1) ;;
        *)
            warn "$where: skipped $le_rel: could not read the mount table $mountinfo"
            return
            ;;
    esac
    if [ -L "$le_home" ]; then
        # A link to something that exists is the user's own: it stays. A
        # dangling one, or one to the volume's path spelled otherwise, is
        # made right below.
        le_target=$(readlink -- "$le_home")
        if [ "$le_target" != "$le_vol" ] && [ -e "$le_home" ] && [ ! "$le_home" -ef "$le_vol" ]; then
            warn "$where: left $le_rel alone: $le_home is a link to $le_target, not to $le_vol"
            return
        fi
    elif [ -e "$le_home" ]; then
        if ! is_kind "$le_kind" "$le_home"; then
            warn "$where: skipped $le_rel: $le_home is not a $(kind_name "$le_kind")"
            return
        fi
        if [ ! -e "$le_vol" ]; then
            # The volume has none yet: the home's moves into it.
            if ! make_dirs "$volume" "$le_sub" || ! transfer "$le_home" "$le_vol" "$le_rel"; then
                warn "$where: skipped $le_rel: could not move $le_home into $volume"
                return
            fi
        elif [ "$le_kind" = d ]; then
            # All or nothing: a name this user cannot move, or a staging or
            # set-aside directory it may not use, stops the merge before
            # anything moves or any link in it goes.
            if ! on_volume "$staging" || ! on_volume "$volume/.denbox-set-aside"; then
                warn "$where: skipped $le_rel: could not move all of $le_home into $le_vol or aside"
                return
            fi
            if ! removable "$le_home"; then
                printf 'state-link: %s: this user cannot read and remove all of it\n' "$le_home" >&2
                warn "$where: skipped $le_rel: could not move all of $le_home into $le_vol or aside"
                return
            fi
            if ! merge_dir "$le_rel"; then
                warn "$where: skipped $le_rel: could not move all of $le_home into $le_vol or aside"
                return
            fi
        elif make_aside && make_dirs "$aside" "$le_sub" \
            && transfer "$le_home" "$aside/$le_rel" "$le_rel"; then
            # Both have one: the volume's stays, and the home's goes aside in
            # the volume, which outlives the container's layer.
            note "$where: $le_vol and $le_home both existed: kept $le_vol, moved $le_home to $aside/$le_rel"
        else
            warn "$where: skipped $le_rel: could not set $le_home aside"
            return
        fi
    fi
    make_entry
    case $? in
        1)
            warn "$where: skipped $le_rel: could not make $le_vol"
            return
            ;;
        2) return ;;
    esac
    if [ -L "$le_home" ]; then
        [ "$(readlink -- "$le_home")" = "$le_vol" ] && return
        # -n replaces a link to a directory instead of linking inside it.
        ln -sfnT -- "$le_vol" "$le_home" \
            || warn "$where: skipped $le_rel: could not replace the link $le_home"
        return
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

if ! home=$(canon_dir "${HOME:-}"); then
    warn "HOME (${HOME:-}) is not a directory of this user's; nothing is linked"
    exit 1
fi
if ! volume=$(canon_dir "$state_root/home"); then
    warn "$state_root/home is not a directory of this user's; nothing is linked"
    exit 1
fi
env_list=$volume/.config/denbox/state-paths
staging=$volume/.denbox-staging
lock=$volume/.denbox-lock
if [ ! -r "$mountinfo" ]; then
    warn "cannot read the mount table $mountinfo; nothing is linked"
    exit 1
fi
# Runs on one volume take turns: a second container's start, or a run by
# hand, waits for the one under way, whose staging copies it would take for
# leftovers. The lock file is a regular file of the user's, made here; <>
# opens it without waiting, as opening a FIFO would.
if [ -L "$lock" ] || { [ -e "$lock" ] && [ ! -f "$lock" ]; }; then
    warn "$lock is not a regular file; nothing is linked"
    exit 1
fi
if ! command exec 9<>"$lock"; then
    warn "cannot open $lock; nothing is linked"
    exit 1
fi
if ! flock -w "$lock_wait" 9; then
    warn "another run of state-link holds $lock; nothing is linked"
    exit 1
fi
# Copies that an earlier run left in the staging directory, stopped part way
# by KILL or a crash: that container's home, and the only whole copy, may be
# gone, so they are set aside, never deleted and never taken for the volume's.
# A staging directory with a mount point at, above or inside it is left as it
# is, and nothing moves through it.
staging_ok=1
if [ -L "$staging" ] || { [ -e "$staging" ] && [ ! -d "$staging" ]; }; then
    warn "$staging is not a directory"
elif ! on_volume "$staging"; then
    staging_ok=0
    warn "left $staging as it is; nothing moves into $volume"
elif [ -d "$staging" ] && ! rmdir -- "$staging" 2>/dev/null; then
    if make_aside && mv -T -n -- "$staging" "$aside/.denbox-staging" \
        && [ ! -e "$staging" ] && [ ! -L "$staging" ]; then
        note "moved $staging, unfinished copies that an earlier run left, to $aside/.denbox-staging"
    else
        warn "could not set $staging aside"
    fi
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
    # test -O is not POSIX; dash, the image's /bin/sh, has it.
    # shellcheck disable=SC3067
    if clear_path "$volume" .config/denbox && [ ! -L "$env_list" ] && [ -f "$env_list" ] \
        && [ -O "$env_list" ] && [ -r "$env_list" ]; then
        apply_list "$env_list"
    else
        warn "skipped $env_list: not a readable regular file of this user's, or a symbolic link is on its way"
    fi
fi
# Each move empties the staging directory again; it stays only when a copy
# could not be removed, for the next run to set aside.
if [ "$staging_ok" = 1 ] && [ -d "$staging" ] && [ ! -L "$staging" ]; then
    rmdir -- "$staging" 2>/dev/null
fi
exit "$status"
STATE_LINK
chmod 0755 /usr/local/lib/denbox/state-link
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
        # in place. By default, when zsh rewrites the history file (to trim
        # it, or on fc -W) it writes a new file beside the link and renames
        # it over the link, which leaves the history in the container's
        # layer. Without the link, zsh keeps its default, under which an
        # interrupted rewrite loses no history.
        if [[ -L $HOME/.zsh_history ]]; then
            setopt no_hist_save_by_copy
        fi
    fi
    () {
        setopt localoptions glob nonomatch
        unsetopt cshnullglob nullglob
        # shellcheck source=/dev/null
        . /usr/local/lib/denbox/dropins.sh
        denbox_shell_trust
        denbox_user_path
        if [[ "$USERNAME" == "$(</etc/container-user)" ]]; then
            denbox_user_env
        fi
    }
    # Only this branch reads dropins.sh; zsh's unset -f reports a name it lacks.
    unset _denbox_shell_trusted
    unset -f denbox_shell_trust denbox_shell_identity denbox_trusted \
        denbox_trusted_walk denbox_names denbox_user_path denbox_user_env
fi
CONTAINER_ZSH_ENV
cat >> /etc/bash.bashrc <<'CONTAINER_BASH_RC'

# The /etc/zsh/zshenv block for interactive bash. It runs before ~/.bashrc,
# so each bash reads its own user's ~/.bashrc. bash set HISTFILE from the HOME
# it started with before it read this file.
export POWERSHELL_TELEMETRY_OPTOUT=1 POWERSHELL_UPDATECHECK=Off
IFS= read -r _container_user < /etc/container-user
# shellcheck source=/dev/null
. /usr/local/lib/denbox/dropins.sh
denbox_shell_identity
if [ "$_denbox_uid" = 0 ]; then
    if [ "$HOME" = "/home/$_container_user" ]; then
        export HOME=/root USER=root LOGNAME=root
        if [ "${HISTFILE-}" = "/home/$_container_user/.bash_history" ]; then
            HISTFILE=/root/.bash_history
        fi
    fi
elif [ -n "$_denbox_uid" ]; then
    if [ "$HOME" = /root ] && [ "$_denbox_is_user" = 1 ]; then
        export HOME="/home/$_container_user" USER="$_container_user" LOGNAME="$_container_user"
        if [ "${HISTFILE-}" = /root/.bash_history ]; then
            HISTFILE=$HOME/.bash_history
        fi
    fi
    # Let profile.d do this once; /etc/profile reads this file first.
    if ! shopt -q login_shell; then
        denbox_shell_trust
        denbox_user_path
        if [ "$_denbox_is_user" = 1 ]; then
            denbox_user_env
        fi
    fi
fi
unset _container_user _denbox_uid _denbox_is_user _denbox_shell_trusted
unset -f denbox_shell_trust denbox_shell_identity denbox_trusted \
    denbox_trusted_walk denbox_names denbox_user_path denbox_user_env
CONTAINER_BASH_RC
cat > /etc/profile.d/00-container-home.sh <<'CONTAINER_PROFILE'
# A login shell (bash -l, sh -l) finds ~/.profile through HOME, and
# /etc/profile runs this file first: the container user gets its own HOME
# back from the image's /root, and a root shell given the user's HOME /root.
# This also adds missing tool paths and sources user-env.d for the container
# user, including non-interactive login commands (bash -lc and sh -lc).
IFS= read -r _container_user < /etc/container-user
# shellcheck source=/dev/null
. /usr/local/lib/denbox/dropins.sh
denbox_shell_identity
if [ "$_denbox_uid" = 0 ]; then
    if [ "$HOME" = "/home/$_container_user" ]; then
        export HOME=/root USER=root LOGNAME=root
    fi
elif [ -n "$_denbox_uid" ]; then
    if [ "$HOME" = /root ] && [ "$_denbox_is_user" = 1 ]; then
        export HOME="/home/$_container_user" USER="$_container_user" LOGNAME="$_container_user"
    fi
    denbox_shell_trust
    denbox_user_path
    if [ "$_denbox_is_user" = 1 ]; then
        denbox_user_env
    fi
fi
unset _container_user _denbox_uid _denbox_is_user _denbox_shell_trusted
unset -f denbox_shell_trust denbox_shell_identity denbox_trusted \
    denbox_trusted_walk denbox_names denbox_user_path denbox_user_env
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
