FROM archlinux:base-devel-20260201.0.486523

# =============================================================================
# System packages
# =============================================================================
RUN pacman -Syu --noconfirm && \
    pacman -S --noconfirm \
        # Basic utilities
        curl \
        git \
        unzip \
        wget \
        zip \
        # Shell
        zsh \
        # Fuzzy finder
        fzf \
        # Prompt
        starship \
        # Rust CLI tools
        bat \
        eza \
        fd \
        git-delta \
        ripgrep \
        zoxide \
        bottom \
        dust \
        lsd \
        procs \
        sd \
        hyperfine \
        tealdeer \
        yazi \
        gitui \
        xh \
        grex \
        broot \
    && pacman -Scc --noconfirm

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# =============================================================================
# Shell setup (zsh; den's zsh plugins are cloned by `den install shell` below)
# =============================================================================
RUN chsh -s /bin/zsh

# =============================================================================
# Python tools (astral.sh)
# =============================================================================
# The astral installers put uv, ty and ruff in ~/.local/bin (not ~/.cargo/bin
# as older uv releases did) and only edit shell rc files, which later RUN steps
# never source; put the directory on PATH here so `uv tool install` below finds
# uv, and so `den` (a uv tool shim in the same directory) is on PATH at runtime.
ENV PATH="/root/.local/bin:${PATH}"
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    curl -LsSf https://astral.sh/ty/install.sh | sh && \
    curl -LsSf https://astral.sh/ruff/install.sh | sh

# =============================================================================
# Shell configuration (clone den from GitHub)
# =============================================================================
RUN git clone --depth 1 https://github.com/NekoBend/den.git /tmp/den && \
    uv tool install /tmp/den && \
    den install shell --force && \
    rm -rf /tmp/den

# =============================================================================
# Workspace
# =============================================================================
WORKDIR /workspace

CMD ["zsh"]
