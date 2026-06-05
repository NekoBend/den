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
# Shell setup (zsh + oh-my-zsh + plugins)
# =============================================================================
RUN chsh -s /bin/zsh

RUN sh -c "$(curl -fsSL https://raw.githubusercontent.com/ohmyzsh/ohmyzsh/master/tools/install.sh)" "" --unattended && \
    git clone https://github.com/zsh-users/zsh-autosuggestions ${ZSH_CUSTOM:-~/.oh-my-zsh/custom}/plugins/zsh-autosuggestions

# =============================================================================
# Python tools (astral.sh)
# =============================================================================
RUN curl -LsSf https://astral.sh/uv/install.sh | sh && \
    curl -LsSf https://astral.sh/ty/install.sh | sh && \
    curl -LsSf https://astral.sh/ruff/install.sh | sh

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
