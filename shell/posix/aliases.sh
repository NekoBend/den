#!/bin/sh
# aliases.sh — Shell aliases (navigation, git, docker, editor).
# Requires: wrappers.sh and functions.sh loaded first.
# Sourced by .bashrc / .zshrc via init script. POSIX sh compatible.
# Deploy target: ~/.config/shell/aliases.sh

# Skip in non-interactive shells to avoid breaking scripts
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0;; esac

# ===== Navigation =====

# .. / .1–.9 → shorthand for up (defined in functions.sh)
alias ..="cd .."
for _n in 1 2 3 4 5 6 7 8 9; do
    eval "alias .$_n='up $_n'"
done
unset _n

# c → clear screen
alias c="clear"

# ===== Git =====

alias g="git"
alias ga="git add"
alias gaa="git add --all"
alias gb="git branch"
alias gc="git commit"
alias gcm="git commit -m"
alias gco="git checkout"
alias gd="git diff"
alias gds="git diff --staged"
alias gf="git fetch --all --prune"
alias gl="git log --oneline --graph"
alias gpl="git pull"
alias gps="git push"
alias gst="git status -sb"
alias gsw="git switch"

# ===== Docker =====

alias d="docker"
alias dc="docker compose"
alias dcb="docker compose build"
alias dcd="docker compose down"
alias dce="docker compose exec"
alias dcl="docker compose logs"
alias dcu="docker compose up"
alias di="docker images"
alias dps="docker ps"
alias dri="docker run -it"
alias drir="docker run -it --rm"

# ===== Editor =====

# code → code-insiders (falls back to stable code)
if command -v code-insiders >/dev/null 2>&1; then
    alias code="code-insiders"
elif ! command -v code >/dev/null 2>&1; then
    alias code='echo "VS Code is not installed." >&2 && false'
fi

# gu → gitui (terminal git UI)
if command -v gitui >/dev/null 2>&1; then
    alias gu="gitui"
else
    alias gu='echo "gitui is not installed." >&2 && false'
fi


