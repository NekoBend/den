# =============================================================================
# Shell Test Image — Minimal environment for testing shell scripts
# across bash, zsh, and PowerShell 7 (pwsh).
#
# Purpose: Validate that shell functions work correctly in all three shells.
#
# Usage:
#   docker build -t dotfiles-shell-test -f tests/shell/Dockerfile .
#   docker run --rm dotfiles-shell-test
# =============================================================================
FROM ubuntu:24.04

# Avoid interactive prompts during package install
ENV DEBIAN_FRONTEND=noninteractive
ENV LANG=C.UTF-8

# =============================================================================
# System packages: bash, zsh, git, coreutils, findutils, zip/unzip
# =============================================================================
RUN apt-get update && \
    apt-get install -y --no-install-recommends \
        bash \
        zsh \
        git \
        coreutils \
        findutils \
        ca-certificates \
        curl \
        wget \
        zip \
        unzip \
        bzip2 \
        xz-utils \
        software-properties-common \
    && rm -rf /var/lib/apt/lists/*

# =============================================================================
# PowerShell 7 from Microsoft repository
# =============================================================================
RUN . /etc/os-release && \
    wget -q "https://packages.microsoft.com/config/ubuntu/$VERSION_ID/packages-microsoft-prod.deb" && \
    dpkg -i packages-microsoft-prod.deb && \
    rm packages-microsoft-prod.deb && \
    apt-get update && \
    apt-get install -y --no-install-recommends powershell && \
    rm -rf /var/lib/apt/lists/*

# =============================================================================
# Copy dotfiles and test suite
# =============================================================================
COPY shell/ /root/.dotfiles/shell/
# Copy the whole test suite so a new test_*.sh is picked up without editing this
# Dockerfile.
COPY tests/shell/ /root/tests/shell/

# Normalize CRLF → LF (Windows host may inject \r)
RUN find /root -type f \( -name '*.sh' -o -name '*.ps1' -o -name '*.zsh' -o -name '*.bash' \) \
      -exec sed -i 's/\r$//' {} +
RUN chmod +x /root/tests/shell/*.sh

WORKDIR /root
CMD ["bash", "/root/tests/shell/run.sh"]
