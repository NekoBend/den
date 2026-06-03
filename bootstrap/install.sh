#!/bin/sh
# install.sh - den bootstrap installer (POSIX: bash / zsh).
#
# One entry point, branching by component. Pick what you want, skip the rest:
#   - shell environment : bash/zsh config, starship, helpers (-> ~/.config/shell)
#   - LLM agent skills  : the agents/ skill set (-> ~/.agents and ~/.claude),
#                         delegated to bootstrap/skills.sh
#
# Usage:
#   git clone --depth 1 https://github.com/NekoBend/den.git /tmp/den
#   sh /tmp/den/bootstrap/install.sh [options]
#   rm -rf /tmp/den
#
# Options:
#   --shell / --no-shell      install (or skip) the shell environment
#   --agents / --no-agents    install (or skip) the LLM agent skills
#   --skills-only             install only the skills (shorthand: --no-shell --agents)
#   --with-parent / --no-parent
#                             install (or skip) AGENTS.md + CLAUDE.md with the skills
#   --all                     install everything, no prompts
#   --yes, -y                 accept defaults, no prompts
#   --dry-run, -n             print actions without writing
#   -h, --help                show this help
#
# With no component flags the installer is interactive and asks per component.
set -eu

# --- Flag parsing ---
DRY_RUN=0
YES=0
ALL=0
WANT_SHELL=auto     # auto | yes | no
WANT_AGENTS=auto    # auto | yes | no
WITH_PARENT=auto    # auto | yes | no

usage() {
  cat <<'EOF'
den bootstrap installer (POSIX: bash / zsh)

Usage: sh bootstrap/install.sh [options]

Components (interactive per-component prompts when no flag is given):
  --shell / --no-shell      install (or skip) the shell environment
  --agents / --no-agents    install (or skip) the LLM agent skills
  --skills-only             only the skills (= --no-shell --agents)
  --with-parent / --no-parent
                            install (or skip) AGENTS.md + CLAUDE.md with skills

  --all        install everything, no prompts
  --yes, -y    accept defaults, no prompts
  --dry-run, -n   print actions without writing
  -h, --help   show this help
EOF
}

for arg in "$@"; do
  case "$arg" in
    --dry-run|-n) DRY_RUN=1 ;;
    --yes|-y) YES=1 ;;
    --all) ALL=1 ;;
    --shell) WANT_SHELL=yes ;;
    --no-shell) WANT_SHELL=no ;;
    --agents) WANT_AGENTS=yes ;;
    --no-agents) WANT_AGENTS=no ;;
    --skills-only) WANT_SHELL=no; WANT_AGENTS=yes ;;
    --with-parent) WITH_PARENT=yes ;;
    --no-parent) WITH_PARENT=no ;;
    -h|--help) usage; exit 0 ;;
    *) echo "unknown option: $arg" >&2; usage >&2; exit 2 ;;
  esac
done

if [ "$ALL" = 1 ]; then
  [ "$WANT_SHELL" = auto ] && WANT_SHELL=yes
  [ "$WANT_AGENTS" = auto ] && WANT_AGENTS=yes
  [ "$WITH_PARENT" = auto ] && WITH_PARENT=yes
  YES=1
fi

# Non-interactive when the user asked us not to prompt.
INTERACTIVE=1
if [ "$YES" = 1 ] || [ "$DRY_RUN" = 1 ]; then INTERACTIVE=0; fi

run_cmd() {
  if [ "$DRY_RUN" = 0 ]; then
    "$@"
  fi
}

# confirm DEFAULT MESSAGE -> 0 (yes) / 1 (no). DEFAULT is Y or N.
confirm() {
  default="$1"; msg="$2"
  if [ "$INTERACTIVE" = 0 ]; then
    [ "$default" = Y ] && return 0 || return 1
  fi
  if [ "$default" = Y ]; then printf '%s [Y/n] ' "$msg"; else printf '%s [y/N] ' "$msg"; fi
  read -r ans
  case "$ans" in
    "") [ "$default" = Y ] && return 0 || return 1 ;;
    [yY]*) return 0 ;;
    *) return 1 ;;
  esac
}

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SHELL_DIR="$HOME/.config/shell"

# --- Decide components ---
case "$WANT_SHELL" in
  yes) DO_SHELL=1 ;;
  no) DO_SHELL=0 ;;
  auto) if confirm Y "Install shell environment (bash/zsh, starship, helpers)?"; then DO_SHELL=1; else DO_SHELL=0; fi ;;
esac
case "$WANT_AGENTS" in
  yes) DO_AGENTS=1 ;;
  no) DO_AGENTS=0 ;;
  auto) if confirm N "Install LLM agent skills (-> ~/.agents, ~/.claude)?"; then DO_AGENTS=1; else DO_AGENTS=0; fi ;;
esac

if [ "$DO_SHELL" = 0 ] && [ "$DO_AGENTS" = 0 ]; then
  echo "Nothing selected. Re-run with --shell, --agents, --skills-only, or --all."
  exit 0
fi

TAG="OK"
[ "$DRY_RUN" = 1 ] && TAG="DRY"

# ============================================================================
# Component: shell environment
# ============================================================================
if [ "$DO_SHELL" = 1 ]; then
  # Pre-flight checks
  missing=0
  for src in \
    "$REPO_DIR/shell/posix/_helpers.sh" \
    "$REPO_DIR/shell/posix/wrappers.sh" \
    "$REPO_DIR/shell/posix/aliases.sh" \
    "$REPO_DIR/shell/posix/functions.sh" \
    "$REPO_DIR/shell/posix/hwinfo.sh" \
    "$REPO_DIR/shell/bash/init.bash" \
    "$REPO_DIR/shell/zsh/init.zsh" \
    "$REPO_DIR/shell/starship/starship.toml"; do
    if [ ! -f "$src" ]; then
      echo "ERROR: source file not found: $src" >&2
      missing=1
    fi
  done
  if [ "$missing" = 1 ]; then
    echo "Aborting: missing source files." >&2
    exit 1
  fi

  if [ "$DRY_RUN" = 1 ]; then
    echo "Shell environment -> $SHELL_DIR (dry run)"
  else
    echo "Shell environment -> $SHELL_DIR"
  fi
  run_cmd mkdir -p "$SHELL_DIR"

  for f in _helpers.sh wrappers.sh aliases.sh functions.sh hwinfo.sh; do
    run_cmd cp "$REPO_DIR/shell/posix/$f" "$SHELL_DIR/$f"
    echo "  [$TAG] $f"
  done

  # Optional modules
  for mod in "python.sh:Install Python/uv helpers?" \
             "ffmpeg.sh:Install ffmpeg helpers?" \
             "parallel.sh:Install parallel file operation helpers (pcp, pmv, prm, ptar)?"; do
    file="${mod%%:*}"
    prompt="${mod#*:}"
    if confirm Y "  $prompt"; then
      if [ -f "$REPO_DIR/shell/posix/$file" ]; then
        run_cmd cp "$REPO_DIR/shell/posix/$file" "$SHELL_DIR/$file"
        echo "  [$TAG] $file"
      else
        echo "  [SKIP] $file (not found)"
      fi
    else
      echo "  [SKIP] $file"
    fi
  done

  # Init scripts
  run_cmd cp "$REPO_DIR/shell/bash/init.bash" "$SHELL_DIR/init.bash"
  echo "  [$TAG] init.bash"
  run_cmd cp "$REPO_DIR/shell/zsh/init.zsh" "$SHELL_DIR/init.zsh"
  echo "  [$TAG] init.zsh"

  # Starship
  run_cmd mkdir -p "$HOME/.config"
  run_cmd cp "$REPO_DIR/shell/starship/starship.toml" "$HOME/.config/starship.toml"
  echo "  [$TAG] starship.toml"

  # Fix CRLF (safe no-op on LF files)
  if command -v sed >/dev/null 2>&1; then
    if [ "$DRY_RUN" = 1 ]; then
      echo "  [DRY] sed -i 's/\\r$//' (CRLF fix)"
    else
      sed -i 's/\r$//' \
        "$SHELL_DIR"/*.sh \
        "$SHELL_DIR"/init.bash \
        "$SHELL_DIR"/init.zsh \
        "$HOME/.config/starship.toml" 2>/dev/null || true
    fi
  fi

  # Add source line to ~/.bashrc (if not already present)
  COMMENT='# ===== den ====='
  BASH_LINE='[ -f "$HOME/.config/shell/init.bash" ] && . "$HOME/.config/shell/init.bash"'
  if [ -f "$HOME/.bashrc" ]; then
    if ! grep -qF '.config/shell/init.bash' "$HOME/.bashrc"; then
      if [ "$DRY_RUN" = 1 ]; then
        echo "  [DRY] Would append source line to ~/.bashrc"
      else
        printf '\n%s\n%s\n' "$COMMENT" "$BASH_LINE" >> "$HOME/.bashrc"
        echo "  [OK] Added source line to ~/.bashrc"
      fi
    else
      echo "  [SKIP] ~/.bashrc already configured"
    fi
  else
    if [ "$DRY_RUN" = 1 ]; then
      echo "  [DRY] Would create ~/.bashrc"
    else
      printf '%s\n%s\n' "$COMMENT" "$BASH_LINE" > "$HOME/.bashrc"
      echo "  [OK] Created ~/.bashrc"
    fi
  fi

  # Add source line to ~/.zshrc (if not already present)
  ZSH_LINE='[ -f "$HOME/.config/shell/init.zsh" ] && . "$HOME/.config/shell/init.zsh"'
  if [ -f "$HOME/.zshrc" ]; then
    if ! grep -qF '.config/shell/init.zsh' "$HOME/.zshrc"; then
      if [ "$DRY_RUN" = 1 ]; then
        echo "  [DRY] Would append source line to ~/.zshrc"
      else
        printf '\n%s\n%s\n' "$COMMENT" "$ZSH_LINE" >> "$HOME/.zshrc"
        echo "  [OK] Added source line to ~/.zshrc"
      fi
    else
      echo "  [SKIP] ~/.zshrc already configured"
    fi
  else
    if [ "$DRY_RUN" = 1 ]; then
      echo "  [DRY] Would create ~/.zshrc"
    else
      printf '%s\n%s\n' "$COMMENT" "$ZSH_LINE" > "$HOME/.zshrc"
      echo "  [OK] Created ~/.zshrc"
    fi
  fi
fi

# ============================================================================
# Component: LLM agent skills (delegated to skills.sh)
# ============================================================================
if [ "$DO_AGENTS" = 1 ]; then
  echo ""
  # Skills depend on the parent invariants; default to installing them.
  parent_flag=""
  case "$WITH_PARENT" in
    yes) parent_flag="--with-parent" ;;
    no) parent_flag="" ;;
    auto) if confirm Y "Install parent AGENTS.md / CLAUDE.md with the skills?"; then parent_flag="--with-parent"; fi ;;
  esac
  # skills.sh needs bash (arrays, process substitution, pipefail), not POSIX sh.
  if ! command -v bash >/dev/null 2>&1; then
    echo "ERROR: the skills installer requires bash, which was not found." >&2
    exit 1
  fi
  set -- "$REPO_DIR/bootstrap/skills.sh"
  [ -n "$parent_flag" ] && set -- "$@" "$parent_flag"
  [ "$DRY_RUN" = 1 ] && set -- "$@" --dry-run
  bash "$@"
fi

echo ""
echo "Done."
if [ "$DO_SHELL" = 1 ]; then
  echo "  Restart your shell, or: source ~/.bashrc  (bash) / source ~/.zshrc  (zsh)"
fi
