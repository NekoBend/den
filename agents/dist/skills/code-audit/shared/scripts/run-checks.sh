#!/usr/bin/env bash
# Run format, lint, and typecheck on a single source file,
# dispatching by extension.
#
# Usage:   run-checks.sh <file>
# Exit:    0 = all configured checks passed (or only skipped)
#          1 = at least one check failed
#          2 = bad usage / unknown extension
#
# Trust: on a .ts or .js file, eslint and prettier run the project's code as
# you: they load its JavaScript config files and the plugins those name
# (eslint.config.js, prettier.config.js). On a tree you do not trust, get
# the user's yes before running this script on such a file. The PowerShell
# lint is pinned against the same kind of attack (see the ps1 branch).

# Note: intentionally NOT 'set -euo pipefail'. This wrapper runs each tool
# with '|| <count failure>' fall-through so it can report ALL check results
# rather than stop at the first failure. 'set -u' is kept for undefined-var
# safety. (shell-structure.md section 7 mandates strict mode for normal scripts; this
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
  "$@" >"$tmp_out" 2>&1
  report "$label" "$?" "$*"
}

# report <label> <exit code> <command as shown>
# Records PASS, or FAIL with the output captured in $tmp_out, for a command
# that has already run.
report() {
  if [ "$2" -eq 0 ]; then
    printf '[%-9s] PASS      %s\n' "$1" "$3"
    passed=$((passed + 1))
  else
    printf '[%-9s] FAIL (%d) %s\n' "$1" "$2" "$3"
    sed 's/^/             /' "$tmp_out"
    failed=$((failed + 1))
  fi
}

# skip <label> <reason>
# Records a check that did not run, and why.
skip() {
  printf '[%-9s] SKIPPED   %s\n' "$1" "$2"
  skipped=$((skipped + 1))
}

# project_only <label> <hint>
# Records that this check is only meaningful at project level.
project_only() {
  skip "$1" "$2"
}

# _find_up <dir> <name>...
# Prints the nearest directory, from <dir> up to /, that holds a file with
# one of the names; returns 1 when none does.
_find_up() {
  local dir="$1" name
  shift
  while :; do
    for name in "$@"; do
      if [ -f "$dir/$name" ]; then
        printf '%s\n' "$dir"
        return 0
      fi
    done
    [ "$dir" = "/" ] && return 1
    dir=$(dirname "$dir")
  done
}

# _abs_dir <file>
# The file's directory as an absolute path with symlinks resolved, the form
# tsc reports paths against.
_abs_dir() {
  (CDPATH='' cd -P -- "$(dirname -- "$1")" && pwd -P)
}

# _py_has_ruff_config <file>
# Walk up from the file the way ruff itself discovers config (nearest
# .ruff.toml / ruff.toml / pyproject.toml with [tool.ruff] wins). When a
# project config exists we pass NO extra flags, so the project's own settings
# are never overridden; only a config-less file gets the defaults below.
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

# _tsc_verdict <file relative to the tsconfig.json directory> <tsc exit code>
# Reads the output of 'tsc --pretty false --explainFiles' on stdin. tsc prints
# each diagnostic as 'path(line,col): error TS<n>: message', with indented
# continuation lines, and then --explainFiles names every file of the program
# at column 0, both relative to the tsconfig.json directory. Prints the
# verdict (FAIL, PASS, UNLISTED or STOPPED) and the number of errors in other
# files on the first line, then the lines to show: the file's own
# diagnostics for FAIL, the first lines of the other errors for STOPPED.
_tsc_verdict() {
  TSC_REL="$1" TSC_RC="$2" awk '
    BEGIN { rel = ENVIRON["TSC_REL"]; rc = ENVIRON["TSC_RC"] + 0 }
    { sub(/\r$/, "") }
    /^[ \t]/ {
      if (kind == "mine") mine[++n] = $0
      else if (kind == "other" && m < 10) other[++m] = $0
      next
    }
    $0 == rel { listed = 1; kind = ""; next }
    index($0, rel "(") == 1 && substr($0, length(rel) + 1) ~ /^\([0-9]+,[0-9]+\): error TS[0-9]+:/ {
      mine[++n] = $0; kind = "mine"; next
    }
    # an error with no file (an option or a missing global type) stops tsc
    # before it type-checks anything
    /^error TS[0-9]+:/ {
      others++; stopped = 1; kind = "other"
      if (m < 10) other[++m] = $0
      next
    }
    match($0, /\([0-9]+,[0-9]+\): error TS[0-9]+:/) {
      others++; kind = "other"
      if (m < 10) other[++m] = $0
      code = substr($0, RSTART, RLENGTH)
      sub(/^.*TS/, "", code)
      code += 0
      # so does an error in the config (tsconfig.json)
      if (substr($0, 1, RSTART - 1) ~ /\.json$/) stopped = 1
      # TS2xxx, TS7xxx and the unused-name errors come from the type
      # checker, so it ran
      if ((code >= 2000 && code < 3000) || (code >= 7000 && code < 8000) ||
          code == 6133 || code == 6138 || code == 6192 || code == 6196 ||
          code == 6198 || code == 6199 || code == 6205) checked = 1
      next
    }
    { kind = "" }
    END {
      # without a type-checker error, an error elsewhere (a syntax error)
      # means tsc stopped before type-checking this file
      if (n) verdict = "FAIL"
      else if (rc != 0 && (stopped || !checked)) verdict = "STOPPED"
      else if (!listed) verdict = "UNLISTED"
      else verdict = "PASS"
      print verdict, others + 0
      if (verdict == "FAIL") for (i = 1; i <= n; i++) print mine[i]
      if (verdict == "STOPPED") for (i = 1; i <= m; i++) print other[i]
    }
  '
}

# _ts_typecheck <file> <extension>
# tsc checks a project, not a file: given a file, TypeScript before 6.0
# ignores tsconfig.json (paths, jsx, lib, strict) and 6.0 and later stop with
# TS5112. So the nearest tsconfig.json above the file is checked as a
# project from its own directory, and only this file's diagnostics FAIL.
# A syntax error in another file or an error in the config stops tsc before
# it type-checks anything, so those end in SKIPPED, never in PASS. With no
# tsconfig.json, a .ts/.tsx file is checked alone from its own directory,
# and JavaScript is SKIPPED: tsc reads it only in a project with allowJs or
# checkJs.
_ts_typecheck() {
  local dir base conf rel rc shown out verdict others
  if ! command -v tsc >/dev/null 2>&1; then
    skip "typecheck" "tsc not installed"
    return 0
  fi
  dir=$(_abs_dir "$1")
  base=$(basename -- "$1")
  if ! conf=$(_find_up "$dir" tsconfig.json); then
    case "$2" in
      ts|tsx)
        (cd -- "$dir" && tsc --noEmit "./$base") >"$tmp_out" 2>&1
        report "typecheck" "$?" "tsc --noEmit $1 (no tsconfig.json above it)"
        ;;
      *)
        skip "typecheck" "no tsconfig.json above $1; tsc checks JavaScript only in a project with allowJs or checkJs"
        ;;
    esac
    return 0
  fi
  rel="${dir#"$conf"}"
  rel="${rel#/}"
  rel="${rel:+$rel/}$base"
  shown="tsc --noEmit --pretty false --explainFiles -p $conf"
  (cd -- "$conf" && tsc --noEmit --pretty false --explainFiles -p .) >"$tmp_out" 2>&1
  rc=$?
  out=$(_tsc_verdict "$rel" "$rc" <"$tmp_out")
  verdict=$(printf '%s\n' "$out" | sed -n '1s/ .*//p')
  others=$(printf '%s\n' "$out" | sed -n '1s/.* //p')
  case "$verdict" in
    FAIL)
      printf '[%-9s] FAIL (%d) %s\n' "typecheck" "$rc" "$shown"
      printf '%s\n' "$out" | sed -e '1d' -e 's/^/             /'
      failed=$((failed + 1))
      ;;
    PASS)
      [ "$others" -gt 0 ] && shown="$shown (errors in other files, not counted: $others)"
      printf '[%-9s] PASS      %s\n' "typecheck" "$shown"
      passed=$((passed + 1))
      ;;
    UNLISTED)
      skip "typecheck" "$rel is not in the program of $conf/tsconfig.json (its include, exclude and files decide; JavaScript also needs allowJs or checkJs)"
      ;;
    *)
      skip "typecheck" "tsc stopped before type-checking $rel: errors in other files or in the config (first lines below)"
      if [ "$(printf '%s\n' "$out" | sed -n '$=')" -gt 1 ]; then
        printf '%s\n' "$out" | sed -e '1d' -e 's/^/             /'
      else
        head -n 10 "$tmp_out" | sed 's/^/             /'
      fi
      ;;
  esac
}

# _toml_value <file> <table> <key>
# The value of <key> in the [<table>] table of a TOML file, unquoted, or
# 'workspace' when the key is inherited (key.workspace = true, or
# key = { workspace = true }). It reads a key written on one line, which is
# how Cargo.toml writes an edition.
_toml_value() {
  TOML_TABLE="$2" TOML_KEY="$3" awk '
    BEGIN { table = ENVIRON["TOML_TABLE"]; key = ENVIRON["TOML_KEY"]; q = "\047" }
    /^[ \t]*\[/ {
      name = $0
      sub(/^[ \t]*\[[ \t]*/, "", name)
      sub(/[ \t]*\].*$/, "", name)
      in_table = (name == table)
      next
    }
    !in_table { next }
    {
      line = $0
      sub(/^[ \t]+/, "", line)
      if (index(line, key) != 1) next
      rest = substr(line, length(key) + 1)
      if (rest ~ /^\.workspace[ \t]*=[ \t]*true/) { print "workspace"; exit }
      if (rest !~ /^[ \t]*=/) next
      sub(/^[ \t]*=[ \t]*/, "", rest)
      if (rest ~ /^\{.*workspace[ \t]*=[ \t]*true/) { print "workspace"; exit }
      if (match(rest, /^"[^"]*"/) || match(rest, "^" q "[^" q "]*" q)) {
        print substr(rest, 2, RLENGTH - 2)
        exit
      }
    }
  ' "$1"
}

# _cargo_edition <dir>
# The Rust edition of the crate whose Cargo.toml is nearest above <dir>, read
# as cargo reads it: its [package] edition, or, when the crate inherits it,
# the [workspace.package] edition of the nearest Cargo.toml at or above the
# crate that has a [workspace] table. Prints nothing when there is no
# Cargo.toml or no edition: cargo then uses 2015, rustfmt's default too.
_cargo_edition() {
  local crate root edition
  crate=$(_find_up "$1" Cargo.toml) || return 0
  edition=$(_toml_value "$crate/Cargo.toml" package edition)
  if [ "$edition" = "workspace" ]; then
    edition=""
    root="$crate"
    while :; do
      if grep -q '^[[:space:]]*\[workspace\]' "$root/Cargo.toml"; then
        edition=$(_toml_value "$root/Cargo.toml" workspace.package edition)
        break
      fi
      [ "$root" = "/" ] && break
      root=$(_find_up "$(dirname "$root")" Cargo.toml) || break
    done
  fi
  case "$edition" in
    20[0-9][0-9]) printf '%s\n' "$edition" ;;
  esac
}

# _rustfmt_sets_edition <dir>
# True when the config rustfmt picks for a file in <dir> (the nearest
# .rustfmt.toml or rustfmt.toml, the dotted name first) sets the edition.
_rustfmt_sets_edition() {
  local conf
  conf=$(_find_up "$1" .rustfmt.toml rustfmt.toml) || return 1
  if [ -f "$conf/.rustfmt.toml" ]; then
    conf="$conf/.rustfmt.toml"
  else
    conf="$conf/rustfmt.toml"
  fi
  grep -q '^[[:space:]]*edition[[:space:]]*=' "$conf"
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
    _ts_typecheck "$file" "$ext"
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
    # rustfmt does not read Cargo.toml: with no edition it parses Rust 2015,
    # where 'async fn' is a syntax error. Pass the crate's edition unless the
    # project's rustfmt config sets one.
    rs_dir=$(_abs_dir "$file")
    edition=$(_cargo_edition "$rs_dir")
    if [ -n "$edition" ] && ! _rustfmt_sets_edition "$rs_dir"; then
      run_tool "format" rustfmt --check --edition "$edition" "$file"
    else
      run_tool "format" rustfmt --check "$file"
    fi
    project_only "lint" "clippy operates at crate level; run 'cargo clippy' in crate root"
    project_only "typecheck" "Rust has no file-level typecheck; run 'cargo check' in crate root"
    ;;
  java)
    run_tool "format"    google-java-format --dry-run --set-exit-if-changed "$file"
    run_tool "lint"      checkstyle "$file"
    project_only "typecheck" "javac requires classpath context; run a build (gradle/maven) in project root"
    ;;
  ps1|psm1)
    # PSScriptAnalyzer at Error severity is the bar the originating repository's
    # CI applies to its PowerShell. Parse errors surface as their own check so a syntax break
    # reads as one line, not a wall of analyzer output. The file path travels
    # in an env var, never interpolated into the pwsh command string, so a
    # hostile filename cannot become pwsh code.
    #
    # -Settings is passed as a hashtable, and it is not optional. With no
    # -Settings, PSScriptAnalyzer auto-discovers a PSScriptAnalyzerSettings.psd1
    # in the analyzed file's own directory, and such a profile may set
    # CustomRulePath, which the analyzer Import-Modules before it reports a
    # single finding -- arbitrary code execution from checked-out content, in a
    # step whose visible output is only PASS/FAIL. Any non-null -Settings
    # disables that lookup, so the settings are this script's, not the
    # checked-out repository's.
    export RC_FILE="$file"
    # shellcheck disable=SC2016  # the $-expressions are pwsh code, expanded by pwsh, not bash
    run_tool "parse" pwsh -NoProfile -Command '$t=$null;$e=$null;[void][System.Management.Automation.Language.Parser]::ParseFile((Resolve-Path -LiteralPath $env:RC_FILE).Path,[ref]$t,[ref]$e);if($e.Count){$e|ForEach-Object{"line $($_.Extent.StartLineNumber): $($_.Message)"};exit 1}'
    if command -v pwsh >/dev/null 2>&1 && ! pwsh -NoProfile -Command 'if(Get-Module -ListAvailable PSScriptAnalyzer){exit 0};exit 1' >/dev/null 2>&1; then
      printf '[%-9s] SKIPPED   PSScriptAnalyzer module not installed\n' "lint"
      skipped=$((skipped + 1))
    else
      # shellcheck disable=SC2016  # same: pwsh expands, bash must not
      run_tool "lint" pwsh -NoProfile -Command '$p=[System.Management.Automation.WildcardPattern]::Escape((Resolve-Path -LiteralPath $env:RC_FILE).Path);$r=Invoke-ScriptAnalyzer -Path $p -Settings @{Severity=@("Error");IncludeDefaultRules=$true};if($r){$r|ForEach-Object{"$($_.Line): $($_.RuleName): $($_.Message)"};exit 1}'
    fi
    project_only "typecheck" "PowerShell has no static typecheck; parse + PSScriptAnalyzer are the gate"
    ;;
  cs)
    project_only "format"    "dotnet format operates at project level; run 'dotnet format --verify-no-changes' in project root"
    project_only "lint"      "dotnet analyzers run during build; run 'dotnet build' in project root"
    project_only "typecheck" "C# typecheck happens during build; run 'dotnet build' in project root"
    ;;
  sh|bash)
    # -i 2 -ci -s is the style shell.md section 3 sets. A formatting flag
    # makes shfmt ignore EditorConfig, so with an .editorconfig above the
    # file shfmt runs with none and the project's settings win.
    if _find_up "$(_abs_dir "$file")" .editorconfig >/dev/null; then
      run_tool "format" shfmt -d "$file"
    else
      run_tool "format" shfmt -d -i 2 -ci -s "$file"
    fi
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
