FROM ubuntu:24.04

# =============================================================================
# System packages
# =============================================================================
RUN apt-get update && \
    apt-get install -y \
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
        # Build dependencies (for cargo install)
        build-essential \
        pkg-config \
        libssl-dev \
    && rm -rf /var/lib/apt/lists/*

ENV LANG=C.UTF-8
ENV LC_ALL=C.UTF-8

# =============================================================================
# Shell setup (zsh; den's zsh plugins are cloned by `den install shell` below)
# =============================================================================
RUN chsh -s /bin/zsh

# Starship prompt
RUN curl -sS https://starship.rs/install.sh | sh -s -- --yes

# =============================================================================
# Rust toolchain
# =============================================================================
RUN curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs | sh -s -- -y
ENV PATH="/root/.cargo/bin:${PATH}"

# =============================================================================
# Python tools (astral.sh)
# =============================================================================
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    curl -LsSf https://astral.sh/ty/install.sh | sh && \
    curl -LsSf https://astral.sh/ruff/install.sh | sh

# =============================================================================
# Rust CLI tools (cargo install)
# =============================================================================
RUN cargo install --locked \
        bat \
        bottom \
        broot \
        du-dust \
        eza \
        fd-find \
        git-delta \
        gitui \
        grex \
        hyperfine \
        lsd \
        procs \
        ripgrep \
        sd \
        tealdeer \
        xh \
        yazi-build \
        zoxide \
    && rm -rf /root/.cargo/registry /root/.cargo/git

# =============================================================================
# Shell configuration (clone dotfiles from GitHub)
# =============================================================================
RUN git clone --depth 1 https://github.com/NekoBend/den.git /tmp/den && \
    uv tool install /tmp/den && \
    /root/.local/bin/den install shell --force && \
    rm -rf /tmp/den

# =============================================================================
# Workspace
# =============================================================================
WORKDIR /workspace

CMD ["zsh"]