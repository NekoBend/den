#!/usr/bin/env bash
# Run format, lint, and typecheck on a single source file,
# dispatching by extension.
#
# Usage:   run-checks.sh <file>
# Exit:    0 = all configured checks passed (or only skipped)
#          1 = at least one check failed
#          2 = bad usage / unknown extension

# Note: intentionally NOT 'set -euo pipefail'. This wrapper runs each tool
# with '|| <count failure>' fall-through so it can report ALL check results
# rather than stop at the first failure. 'set -u' is kept for undefined-var
# safety. (shell.md section 7 mandates strict mode for normal scripts; this
# is a documented exception because the script's job is to keep going.)
set -u

usage() {
  echo "usage: $0 <file>" >&2
  exit 2
}

[ "$#" -eq 1 ] || usage
file="$1"
[ -f "$file" ] || { echo "file not found: $file" >&2; exit 2; }

ext="${file##*.}"
passed=0
failed=0
skipped=0

# Capture tool output to a temp file so we can prefix it cleanly.
tmp_out=$(mktemp 2>/dev/null || mktemp -t run-checks)
trap 'rm -f "$tmp_out"' EXIT

# run_tool <label> <command...>
# Runs the command if the first token is on PATH, otherwise records SKIPPED.
run_tool() {
  label="$1"; shift
  if ! command -v "$1" >/dev/null 2>&1; then
    printf '[%-9s] SKIPPED   %s not installed\n' "$label" "$1"
    skipped=$((skipped + 1))
    return 0
  fi
  if "$@" >"$tmp_out" 2>&1; then
    printf '[%-9s] PASS      %s\n' "$label" "$*"
    passed=$((passed + 1))
  else
    rc=$?
    printf '[%-9s] FAIL (%d) %s\n' "$label" "$rc" "$*"
    sed 's/^/             /' "$tmp_out"
    failed=$((failed + 1))
  fi
}

# project_only <label> <hint>
# Records that this check is only meaningful at project level.
project_only() {
  printf '[%-9s] SKIPPED   %s\n' "$1" "$2"
  skipped=$((skipped + 1))
}

# _py_has_ruff_config <file>
# Walk up from the file the way ruff itself discovers config (nearest
# .ruff.toml / ruff.toml / pyproject.toml with [tool.ruff] wins). When a
# project config exists we pass NO extra flags, so the project's own settings
# are never overridden; only a config-less file gets den's defaults below.
_py_has_ruff_config() {
  d=$(cd "$(dirname "$1")" && pwd)
  while :; do
    [ -f "$d/.ruff.toml" ] && return 0
    [ -f "$d/ruff.toml" ] && return 0
    if [ -f "$d/pyproject.toml" ] && grep -q '^\[tool\.ruff' "$d/pyproject.toml" 2>/dev/null; then
      return 0
    fi
    [ "$d" = "/" ] && return 1
    d=$(dirname "$d")
  done
}

case "$ext" in
  py)
    # typecheck (ty) resolves imports against the real environment, which
    # replaced the retired verify-imports.py; the docstring-presence rules
    # below replaced the retired doc-coverage.py for Python.
    run_tool "format"    ruff format --check "$file"
    if _py_has_ruff_config "$file"; then
      run_tool "lint"    ruff check "$file"
    else
      run_tool "lint"    ruff check --extend-select D101,D102,D103 "$file"
    fi
    run_tool "typecheck" ty check "$file"
    ;;
  ts|tsx|js|jsx|mjs|cjs)
    run_tool "format"    prettier --check "$file"
    run_tool "lint"      eslint "$file"
    run_tool "typecheck" tsc --noEmit "$file"
    ;;
  go)
    # gofmt -l prints offending file names; non-empty output = format issue.
    if command -v gofmt >/dev/null 2>&1; then
      out=$(gofmt -l "$file" 2>&1)
      if [ -z "$out" ]; then
        printf '[%-9s] PASS      gofmt -l %s\n' "format" "$file"
        passed=$((passed + 1))
      else
        printf '[%-9s] FAIL      gofmt would reformat %s\n' "format" "$file"
        failed=$((failed + 1))
      fi
    else
      printf '[%-9s] SKIPPED   gofmt not installed\n' "format"
      skipped=$((skipped + 1))
    fi
    project_only "lint" "golangci-lint operates at module level; run 'golangci-lint run ./...' in module root"
    project_only "typecheck" "Go has no file-level typecheck; run 'go build ./...' in module root"
    ;;
  rs)
    run_tool "format" rustfmt --check "$file"
    project_only "lint" "clippy operates at crate level; run 'cargo clippy' in crate root"
    project_only "typecheck" "Rust has no file-level typecheck; run 'cargo check' in crate root"
    ;;
  java)
    run_tool "format"    google-java-format --dry-run --set-exit-if-changed "$file"
    run_tool "lint"      checkstyle "$file"
    project_only "typecheck" "javac requires classpath context; run a build (gradle/maven) in project root"
    ;;
  cs)
    project_only "format"    "dotnet format operates at project level; run 'dotnet format --verify-no-changes' in project root"
    project_only "lint"      "dotnet analyzers run during build; run 'dotnet build' in project root"
    project_only "typecheck" "C# typecheck happens during build; run 'dotnet build' in project root"
    ;;
  sh|bash)
    run_tool "format" shfmt -d "$file"
    run_tool "lint"   shellcheck "$file"
    # No typechecker for shell.
    ;;
  *)
    echo "unknown extension: .$ext" >&2
    exit 2
    ;;
esac

printf 'SUMMARY: %d passed, %d failed, %d skipped\n' "$passed" "$failed" "$skipped"
[ "$failed" -eq 0 ] || exit 1
exit 0
