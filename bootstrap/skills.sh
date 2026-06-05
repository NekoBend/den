#!/usr/bin/env bash
# Install the prompt skills into coding-agent skill directories.
#
# Each skill is installed as a SELF-CONTAINED unit. The skill's own files are
# copied under <target>/skills/<name>/, and the shared resources that skill
# actually references (shared/reference/*.md and, if any script is used, the
# whole shared/scripts/ set) are copied into <target>/skills/<name>/shared/.
# So a skill directory carries everything it needs and can be registered or
# moved on its own. No top-level shared/ tree is created.
#
# Every shared/ reference in the installed skill (with or without a leading
# ../../) is rewritten to an ABSOLUTE path under that skill's own shared/, so
# it resolves regardless of the agent's working directory. Absolute paths are
# deliberate: weak models resolve them reliably where a relative path is
# ambiguous.
#
# Usage: skills.sh [--tool TOOL]... [--all-tools] [--target DIR]...
#                  [--with-parent] [--dry-run] [--codex-config]
#
#   --tool TOOL      deploy to a named tool's directories (repeatable).
#                    TOOL = claude | codex | cline | copilot | gemini
#   --all-tools      deploy to all supported tools (shorthand for all --tool)
#   --target DIR     custom target root (repeatable; overrides tool defaults)
#   --with-parent    install the parent prompt into each tool's correct location
#                    (AGENTS.md, CLAUDE.md, copilot-instructions.md, GEMINI.md, ...)
#   --dry-run        print actions without writing
#   --codex-config   print the [[skills.config]] block for ~/.codex/config.toml
#
# Tool-specific locations (verified 2026-06-04):
#   claude  : skills -> ~/.claude/skills/     parent -> ~/.claude/CLAUDE.md
#   codex   : skills -> ~/.agents/skills/     parent -> ~/.codex/AGENTS.md
#   cline   : skills -> ~/.cline/skills/      parent -> ~/.agents/AGENTS.md
#   copilot : skills -> ~/.copilot/skills/    parent -> ~/.copilot/copilot-instructions.md
#   gemini  : skills -> ~/.gemini/skills/     parent -> ~/.gemini/GEMINI.md
#
# Default (no --tool / --target): deploys to ~/.agents and ~/.claude (backward-
# compatible; covers Claude Code + tools that read ~/.agents).
#
# bootstrap/install.sh delegates here for the "LLM agent skills" component;
# this script is also runnable on its own.
set -euo pipefail

# This script lives at <repo>/bootstrap/. The agents subsystem is the sibling
# <repo>/agents/.
SRC="$(cd "$(dirname "$0")/../agents" && pwd)"

# --- Tool registry ---
# Each entry: "skills_dir|parent_dir|parent_filename"
# parent_filename = the exact filename the tool reads as always-on instructions.
_tool_config() {
  case "$1" in
    claude)  printf '%s' "$HOME/.claude/skills|$HOME/.claude|CLAUDE.md" ;;
    codex)   printf '%s' "$HOME/.agents/skills|$HOME/.codex|AGENTS.md" ;;
    cline)   printf '%s' "$HOME/.cline/skills|$HOME/.agents|AGENTS.md" ;;
    copilot) printf '%s' "$HOME/.copilot/skills|$HOME/.copilot|copilot-instructions.md" ;;
    gemini)  printf '%s' "$HOME/.gemini/skills|$HOME/.gemini|GEMINI.md" ;;
    *) echo "unknown tool: $1 (valid: claude codex cline copilot gemini)" >&2; exit 2 ;;
  esac
}

expand_tilde() {
  # shellcheck disable=SC2088
  case "$1" in
    "~") printf '%s' "$HOME" ;;
    "~/"*) printf '%s/%s' "$HOME" "${1#"~/"}" ;;
    *) printf '%s' "$1" ;;
  esac
}

tools=()
targets=()
dry_run=0
codex_config=0
with_parent=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --tool)       tools+=("$2"); shift 2 ;;
    --all-tools)  tools=(claude codex cline copilot gemini); shift ;;
    --target)     targets+=("$2"); shift 2 ;;
    --with-parent) with_parent=1; shift ;;
    --dry-run)    dry_run=1; shift ;;
    --codex-config) codex_config=1; shift ;;
    -h|--help)    sed -n '2,50p' "$0"; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

if [ ! -d "$SRC/skills" ] || [ ! -d "$SRC/shared" ]; then
  echo "error: expected $SRC/skills and $SRC/shared" >&2
  exit 1
fi

skill_arr=()
for d in "$SRC"/skills/*/; do
  [ -f "${d}SKILL.md" ] && skill_arr+=("$(basename "$d")")
done

# Copy a tree, excluding test/build cruft, from $1 into $2 (which is created).
copy_tree() {
  mkdir -p "$2"
  tar -C "$1" \
    --exclude='__pycache__' --exclude='*.pyc' \
    --exclude='.pytest_cache' --exclude='tests' \
    -cf - . | tar -C "$2" -xf -
}

install_skill() {
  local name="$1" skills_dir="$2"
  local src="$SRC/skills/$name"
  local dest="$skills_dir/$name"
  copy_tree "$src" "$dest"

  local need_scripts=0 need_all_refs=0
  local ref_files=()
  if grep -rq 'shared/scripts/' "$dest"; then need_scripts=1; fi
  if grep -rq 'shared/reference/<' "$dest"; then need_all_refs=1; fi
  while IFS= read -r fname; do
    [ -n "$fname" ] && ref_files+=("$fname")
  done < <(grep -rhoE 'shared/reference/[A-Za-z0-9_-]+\.md' "$dest" |
    sed 's#shared/reference/##' | sort -u)

  if [ "$need_all_refs" -eq 1 ]; then
    mkdir -p "$dest/shared/reference"
    cp "$SRC"/shared/reference/*.md "$dest/shared/reference/"
  elif [ "${#ref_files[@]}" -gt 0 ]; then
    mkdir -p "$dest/shared/reference"
    for rf in "${ref_files[@]}"; do
      [ -f "$SRC/shared/reference/$rf" ] && cp "$SRC/shared/reference/$rf" "$dest/shared/reference/$rf"
    done
  fi
  if [ "$need_scripts" -eq 1 ]; then
    copy_tree "$SRC/shared/scripts" "$dest/shared/scripts"
  fi

  local rewritten=0 f esc_dest
  esc_dest=$(printf '%s' "$dest" | sed 's/[#&\\]/\\&/g')
  while IFS= read -r f; do
    sed -E "s#(\.\./)*shared/(reference|scripts)/#${esc_dest}/shared/\2/#g" "$f" >"$f.tmp"
    cmp -s "$f" "$f.tmp" || rewritten=$((rewritten + 1))
    mv "$f.tmp" "$f"
  done < <(find "$dest" -name '*.md')
  echo "  $name (rewrote $rewritten md files)"
}

# Deploy one skills+parent location pair.
deploy_target() {
  local skills_dir="$1" parent_dir="$2" parent_file="$3"

  if [ "$dry_run" -eq 1 ]; then
    echo "[dry-run] skills -> $skills_dir/<name>/"
    echo "[dry-run]   skills: ${skill_arr[*]}"
    [ "$with_parent" -eq 1 ] && echo "[dry-run]   parent -> $parent_dir/$parent_file"
    return
  fi

  mkdir -p "$skills_dir"
  local abs_skills
  abs_skills="$(cd "$skills_dir" && pwd)"
  echo "installing skills -> $abs_skills"
  for name in "${skill_arr[@]}"; do
    install_skill "$name" "$abs_skills"
  done

  if [ "$with_parent" -eq 1 ]; then
    local src_parent="$SRC/dist/AGENTS.md"
    # Claude Code reads CLAUDE.md specifically.
    [ "$parent_file" = "CLAUDE.md" ] && src_parent="$SRC/dist/CLAUDE.md"
    if [ -f "$src_parent" ]; then
      mkdir -p "$parent_dir"
      cp "$src_parent" "$parent_dir/$parent_file"
      echo "  parent -> $parent_dir/$parent_file"
    else
      echo "  warning: $src_parent not found; run agents/.private/build.py first" >&2
    fi
  fi
}

# Build the list of (skills_dir, parent_dir, parent_file) triples to process.
# Priority: --tool entries first, then --target entries (legacy/custom), then
# the default if neither was given.
processed_skills_dirs=()
has_work=0

deploy_for_tool() {
  local tool="$1"
  local cfg; cfg="$(_tool_config "$tool")"
  local skills_dir parent_dir parent_file
  skills_dir="${cfg%%|*}"; cfg="${cfg#*|}"
  parent_dir="${cfg%%|*}"
  parent_file="${cfg##*|}"
  deploy_target "$skills_dir" "$parent_dir" "$parent_file"
  processed_skills_dirs+=("$skills_dir")
  has_work=1
}

for tool in "${tools[@]}"; do
  deploy_for_tool "$tool"
done

for t in "${targets[@]}"; do
  t="$(expand_tilde "$t")"
  if [ "$dry_run" -eq 1 ]; then
    echo "[dry-run] skills -> $t/skills/<name>/"
    echo "[dry-run]   skills: ${skill_arr[*]}"
    [ "$with_parent" -eq 1 ] && echo "[dry-run]   plus AGENTS.md + CLAUDE.md -> $t/"
    has_work=1
    continue
  fi
  mkdir -p "$t"
  local_abs="$(cd "$t" && pwd)"
  echo "installing -> $local_abs"
  for name in "${skill_arr[@]}"; do
    install_skill "$name" "$local_abs/skills"
  done
  if [ "$with_parent" -eq 1 ]; then
    if [ -f "$SRC/dist/AGENTS.md" ] && [ -f "$SRC/dist/CLAUDE.md" ]; then
      cp "$SRC/dist/AGENTS.md" "$local_abs/AGENTS.md"
      cp "$SRC/dist/CLAUDE.md" "$local_abs/CLAUDE.md"
      echo "  parent: AGENTS.md + CLAUDE.md -> $local_abs/"
    else
      echo "  warning: AGENTS.md/CLAUDE.md not found in $SRC/dist; run agents/.private/build.py first" >&2
    fi
  fi
  has_work=1
done

# Default: backward-compatible (no --tool and no --target given).
if [ "${#tools[@]}" -eq 0 ] && [ "${#targets[@]}" -eq 0 ]; then
  deploy_for_tool claude
  # Also deploy skills to ~/.agents for codex + other tools that read it.
  deploy_target "$HOME/.agents/skills" "$HOME/.agents" "AGENTS.md"
fi

if [ "$codex_config" -eq 1 ]; then
  # Use the first processed skills dir, or ~/.agents/skills as fallback.
  first_skills="${processed_skills_dirs[0]:-$HOME/.agents/skills}"
  [ "$dry_run" -eq 0 ] && mkdir -p "$first_skills"
  echo ""
  echo "# --- paste into ~/.codex/config.toml ---"
  for name in "${skill_arr[@]}"; do
    echo "[[skills.config]]"
    echo "path = \"$first_skills/$name/SKILL.md\""
    echo "enabled = true"
    echo ""
  done
fi

if [ "$dry_run" -eq 0 ] && [ "$with_parent" -eq 0 ] && [ "$has_work" -eq 1 ]; then
  echo ""
  echo "Note: skills reference a parent prompt (<honesty_contract>,"
  echo "<language_policy>, <work_discipline>). Re-run with --with-parent to"
  echo "install the parent into each tool's correct location."
fi
