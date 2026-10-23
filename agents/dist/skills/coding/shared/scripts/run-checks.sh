#!/usr/bin/env bash
# Run format, lint, and typecheck on a single source file,
# dispatching by extension.
#
# Usage:   run-checks.sh <file>
# Exit:    0 = all configured checks passed (or only skipped)
#          1 = at least one check failed
#          2 = bad usage / unknown extension
#
# Trust: on a .ts, .tsx, .js, .jsx, .mjs or .cjs file, eslint and prettier
# run the project's code as you: they load its JavaScript config files and
# the plugins those name (eslint.config.js, prettier.config.js). On a .rs
# file, rustfmt is usually a rustup proxy: when this script runs from inside
# the tree, a rust-toolchain.toml or rust-toolchain whose [toolchain] path is
# absolute runs the rustfmt at that path. On a tree you do not trust, get the
# user's yes before running this script on any of these files. The
# PowerShell lint is pinned against the same kind of attack (see the ps1
# branch).

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

# Capture tool output to a temp file so we can prefix it cleanly. tsc's
# .tsbuildinfo goes to the same temp directory.
tmp_dir=$(mktemp -d 2>/dev/null || mktemp -d -t run-checks)
[ -n "$tmp_dir" ] || { echo "mktemp failed" >&2; exit 2; }
tmp_out="$tmp_dir/out"
trap 'rm -rf "$tmp_dir"' EXIT

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

# run_tool_skip_on <label> <marker> <command...>
# run_tool for a tool that, when its settings make it skip the file it was
# given, still exits 0 and says so in a line containing <marker>: that run
# is SKIPPED with the line from <marker> on, not PASS.
run_tool_skip_on() {
  local label="$1" marker="$2" rc line
  shift 2
  if ! command -v "$1" >/dev/null 2>&1; then
    skip "$label" "$1 not installed"
    return 0
  fi
  "$@" >"$tmp_out" 2>&1
  rc=$?
  line=$(RC_MARKER="$marker" awk '
    i = index($0, ENVIRON["RC_MARKER"]) {
      s = substr($0, i)
      sub(/[ \t\r]+$/, "", s)
      print s
      exit
    }
  ' "$tmp_out")
  if [ "$rc" -eq 0 ] && [ -n "$line" ]; then
    skip "$label" "$* did not check the file: $line"
  else
    report "$label" "$rc" "$*"
  fi
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

# _rel_path <dir> <path>
# <path> relative to <dir>, both absolute: how tsc run from <dir> names it.
_rel_path() {
  local from="$1" up=""
  while [ "$from" != / ]; do
    case "$2" in
      "$from"/*)
        printf '%s%s\n' "$up" "${2#"$from"/}"
        return 0
        ;;
    esac
    from=$(dirname -- "$from")
    up="../$up"
  done
  printf '%s%s\n' "$up" "${2#/}"
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

# _tsc_verdict <file relative to the config's directory> <tsc exit code>
# Reads the output of 'tsc --pretty false --explainFiles' run from the
# config's directory on stdin. tsc prints each diagnostic as
# 'path(line,col): error TS<n>: message', with indented continuation lines,
# and then --explainFiles names every file of the program at column 0, both
# relative to that directory. Prints the verdict (FAIL, PASS, UNLISTED or
# STOPPED) and the number of errors in other files on the first line, then
# the lines to show: the file's own diagnostics for FAIL, the first lines of
# the other errors for STOPPED, and for UNLISTED when every error is in a
# config.
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
      # so may an error in the config (an option tsc rejects)
      if (substr($0, 1, RSTART - 1) ~ /\.json$/) { stopped = 1; injson++ }
      # TS2xxx, TS7xxx, the override and possibly-null errors and the
      # unused-name errors come from the type checker, so it ran; not these
      # TS2xxx, which the parser reports too (parser.ts and scanner.ts of
      # TypeScript 5.9.3 and 6.0.3, numbered in diagnosticMessages.json)
      if (index(" 2427 2457 2458 2657 2754 2809 2819 ", " " code " ")) next
      if ((code >= 2000 && code < 3000) || (code >= 7000 && code < 8000) ||
          (code >= 4112 && code <= 4117) || (code >= 18046 && code <= 18050) ||
          code == 6133 || code == 6138 || code == 6192 || code == 6196 ||
          code == 6198 || code == 6199 || code == 6205) checked = 1
      next
    }
    # a file of the program, as --explainFiles names it (not a line of a
    # crash trace)
    /\.([cm]?[jt]sx?|json)$/ { files++ }
    { kind = "" }
    END {
      # without a type-checker error, an error elsewhere (a syntax error)
      # means tsc may have stopped before type-checking this file. A file
      # the program leaves out is UNLISTED whatever else failed, unless tsc
      # failed without listing any file and not only on errors in a config
      # (a missing reference).
      if (n) verdict = "FAIL"
      else if (listed) verdict = (rc != 0 && (stopped || !checked)) ? "STOPPED" : "PASS"
      else verdict = (files || rc == 0 || (others && others == injson)) ? "UNLISTED" : "STOPPED"
      print verdict, others + 0
      if (verdict == "FAIL") for (i = 1; i <= n; i++) print mine[i]
      if (verdict == "STOPPED" || (verdict == "UNLISTED" && others && others == injson))
        for (i = 1; i <= m; i++) print other[i]
    }
  '
}

# _tsc_in <dir> <argument>...
# Runs tsc from <dir>, its output in $tmp_out.
_tsc_in() {
  (CDPATH='' cd -- "$1" && shift && tsc "$@") >"$tmp_out" 2>&1
}

# _tsconfig_facts
# Reads 'tsc --showConfig' on stdin: the config as tsc resolves it (extends
# applied), as JSON indented four spaces a level. Prints 'checkJs',
# 'skipLibCheck' and 'noCheck' for each one that is on, 'buildinfo' when it
# sets incremental, composite or a tsBuildInfoFile, and 'ref <path>' for each
# reference as written, with tsc's backslash-to-slash.
_tsconfig_facts() {
  awk '
    { sub(/\r$/, "") }
    /^    "references": \[/ { refs = 1; next }
    refs && /^    [^ ]/ { refs = 0 }
    refs && /^            "path": "/ {
      p = $0
      sub(/^            "path": "/, "", p)
      sub(/",?$/, "", p)
      gsub(/\\\\/, "/", p)
      print "ref " p
      next
    }
    /^        "(checkJs|skipLibCheck|noCheck)": true,?$/ { split($0, f, "\""); print f[2] }
    /^        "(incremental|composite)": true,?$/ { print "buildinfo" }
    /^        "tsBuildInfoFile": / { print "buildinfo" }
  '
}

# _fact <name> <facts>: true when <name> is a line of <facts>.
_fact() {
  printf '%s\n' "$2" | grep -qx -- "$1"
}

# _ts_unchecked <file> <name to show> <extension> <facts of its config>
# Prints why tsc reports no type errors in a file of the program, or nothing
# when it does. noCheck turns them off for every file, skipLibCheck for a
# declaration file (a name with .d. in it) and a // @ts-nocheck comment for
# its file; JavaScript gets them only under checkJs or a // @ts-check
# comment. tsc honours both comments only before the first statement, and
# allows any Unicode space (JavaScript's \s) between the // and the @; here
# @ts-check counts only in the comment lines that open the file, with
# nothing but spaces or tabs between the // and the @, and @ts-nocheck
# anywhere in the file, so either can cost a PASS, never give one. Not
# covered: under TypeScript 5.x, skipDefaultLibCheck also turns them off
# for a file whose leading comments hold
# /// <reference no-default-lib="true"/>, and such a file still gets PASS.
_ts_unchecked() {
  local base="${1##*/}" js=""
  case "$3" in
    js|jsx|mjs|cjs) js=1 ;;
  esac
  if _fact noCheck "$4"; then
    echo "noCheck: tsc reports no type errors in any file ($2)"
  elif [ "$3" = ts ] && [ "${base#*.d.}" != "$base" ] && _fact skipLibCheck "$4"; then
    echo "skipLibCheck: tsc reports no type errors in declaration files ($2)"
  elif grep -qi '@ts-nocheck' "$1"; then
    echo "$2 contains @ts-nocheck, which turns off tsc's type errors when a leading // comment holds it"
  elif [ -n "$js" ] && ! _fact checkJs "$4" && ! awk '
      NR == 1 && /^#!/ { next }
      !/^[ \t]*(\/\/.*)?\r?$/ { exit }
      tolower($0) ~ /^[ \t]*\/\/\/?[ \t]*@ts-check([ \t:\r].*)?$/ { found = 1; exit }
      END { exit !found }
    ' "$1"; then
    echo "allowJs without checkJs: tsc reports no type errors in JavaScript ($2)"
  fi
}

# _in_list <needle> <item>...: true when <needle> is one of the items.
_in_list() {
  local needle="$1" item
  shift
  for item in "$@"; do
    [ "$item" = "$needle" ] && return 0
  done
  return 1
}

# _ts_typecheck <file> <extension>
# tsc checks a project, not a file: given a file, TypeScript before 6.0
# ignores tsconfig.json (paths, jsx, lib, strict) and 6.0 and later stop with
# TS5112. So the nearest tsconfig.json above the file is checked as a
# project from its own directory, and only this file's diagnostics FAIL.
# When that program leaves the file out, the configs it references are tried
# in turn (a solution-style tsconfig.json has "files": [] and only lists
# references, so its own program is empty). Errors that may have stopped tsc
# before it type-checked anything (a syntax error in another file, an error
# in the config) end in SKIPPED, never in PASS, and so does a file that tsc
# reads but does not type-check (see _ts_unchecked). With no tsconfig.json,
# a .ts/.tsx file is checked alone from its own directory, and JavaScript is
# SKIPPED.
#
# tsc writes a .tsbuildinfo next to the config (next to outFile or under
# outDir if set, or where tsBuildInfoFile says) when the config has
# incremental or composite, so the check sends it to the temp directory. A
# tsBuildInfoFile without either was an error outside 'tsc -b' up to
# TypeScript 5.6.2 (create-vite's tsconfig.app.json sets one), so
# --incremental comes along.
_ts_typecheck() {
  local dir path conf cfg cdir name rel rc shown out verdict="" others facts
  local ref target i why queue first first_rel bad="" bad_rel=""
  if ! command -v tsc >/dev/null 2>&1; then
    skip "typecheck" "tsc not installed"
    return 0
  fi
  dir=$(_abs_dir "$1")
  path="${dir%/}/$(basename -- "$1")"
  if ! conf=$(_find_up "$dir" tsconfig.json); then
    case "$2" in
      ts|tsx)
        _tsc_in "$dir" --noEmit "./${path##*/}"
        rc=$?
        why=""
        [ "$rc" -eq 0 ] && why=$(_ts_unchecked "$1" "$1" "$2" "")
        if [ -n "$why" ]; then
          skip "typecheck" "$why"
        else
          report "typecheck" "$rc" "tsc --noEmit $1 (no tsconfig.json above it)"
        fi
        ;;
      *)
        skip "typecheck" "no tsconfig.json above $1; JavaScript is type-checked only through one, under checkJs or // @ts-check"
        ;;
    esac
    return 0
  fi
  first="${conf%/}/tsconfig.json"
  first_rel=$(_rel_path "$conf" "$path")
  queue=("$first")
  i=0
  while [ "$i" -lt "${#queue[@]}" ] && [ "$i" -lt 8 ]; do
    cfg="${queue[$i]}"
    i=$((i + 1))
    cdir="${cfg%/*}"
    cdir="${cdir:-/}"
    name="${cfg##*/}"
    rel=$(_rel_path "$cdir" "$path")
    if ! _tsc_in "$cdir" --showConfig -p "./$name"; then
      # with no references to follow from the nearest config the walk ends;
      # a referenced config is named only if no config lists the file
      if [ -z "$bad" ]; then
        bad="$cfg" bad_rel="$rel"
        cp "$tmp_out" "$tmp_dir/bad"
      fi
      [ "$i" -gt 1 ] && continue
      break
    fi
    facts=$(_tsconfig_facts <"$tmp_out")
    case "$facts" in
      *buildinfo*) _tsc_in "$cdir" --noEmit --pretty false --explainFiles --incremental --tsBuildInfoFile "$tmp_dir/$i.tsbuildinfo" -p "./$name" ;;
      *) _tsc_in "$cdir" --noEmit --pretty false --explainFiles -p "./$name" ;;
    esac
    rc=$?
    out=$(_tsc_verdict "$rel" "$rc" <"$tmp_out")
    verdict=$(printf '%s\n' "$out" | sed -n '1s/ .*//p')
    [ "$verdict" = UNLISTED ] || break
    # a run that failed only on errors in a config (a missing reference)
    # keeps its first lines, shown if no config lists the file
    if [ ! -s "$tmp_dir/json" ]; then
      printf '%s\n' "$out" | sed '1d' >"$tmp_dir/json"
    fi
    # A reference names a config file, or a directory holding tsconfig.json,
    # relative to the referencing config.
    while IFS= read -r ref; do
      case "$ref" in
        "") continue ;;
        /*) target="$ref" ;;
        *) target="$cdir/$ref" ;;
      esac
      case "$target" in
        *.json) ;;
        *) target="${target%/}/tsconfig.json" ;;
      esac
      [ -f "$target" ] || continue
      target="$(_abs_dir "$target")/${target##*/}"
      _in_list "$target" "${queue[@]}" || queue+=("$target")
    done <<EOF
$(printf '%s\n' "$facts" | sed -n 's/^ref //p')
EOF
  done
  if [ -n "$bad" ] && [ "${verdict:-UNLISTED}" = UNLISTED ]; then
    skip "typecheck" "tsc --showConfig -p $bad reports errors in the config, so $bad_rel was not checked (first lines below)"
    head -n 10 "$tmp_dir/bad" | sed 's/^/             /'
    return 0
  fi
  shown="tsc --noEmit --pretty false --explainFiles -p $cfg"
  others=$(printf '%s\n' "$out" | sed -n '1s/.* //p')
  if [ "$verdict" = PASS ]; then
    why=$(_ts_unchecked "$1" "$rel" "$2" "$facts")
    if [ -n "$why" ]; then
      skip "typecheck" "$why"
      return 0
    fi
  fi
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
      if [ "$i" -lt "${#queue[@]}" ]; then
        first="$first or of the configs it references ($((i - 1)) checked, stopped after $i configs)"
      elif [ "$i" -gt 1 ]; then
        first="$first or of the configs it references ($((i - 1)) checked)"
      fi
      why="$first_rel is not in the program of $first (include, exclude and files decide; JavaScript also needs allowJs)"
      if [ -s "$tmp_dir/json" ]; then
        skip "typecheck" "$why; tsc reports errors in a config (first lines below)"
        sed 's/^/             /' "$tmp_dir/json"
      else
        skip "typecheck" "$why"
      fi
      ;;
    *)
      skip "typecheck" "tsc -p $cfg may have stopped before type-checking $rel: errors in other files or in the config (first lines below)"
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

# _rustfmt_conf <dir>
# The config rustfmt picks for a file in <dir>: the nearest .rustfmt.toml or
# rustfmt.toml, the dotted name first. Returns 1 when there is none. Not
# covered: with none from <dir> up to /, rustfmt also reads one in the home
# directory or in rustfmt/ under the user's config directory.
_rustfmt_conf() {
  local conf
  conf=$(_find_up "$1" .rustfmt.toml rustfmt.toml) || return 1
  if [ -f "$conf/.rustfmt.toml" ]; then
    printf '%s\n' "$conf/.rustfmt.toml"
  else
    printf '%s\n' "$conf/rustfmt.toml"
  fi
}

# _rustfmt_sets_edition <dir>
# True when the config rustfmt picks for a file in <dir> sets the edition.
_rustfmt_sets_edition() {
  local conf
  conf=$(_rustfmt_conf "$1") || return 1
  grep -q '^[[:space:]]*edition[[:space:]]*=' "$conf"
}

# _rustfmt_disabled <dir>
# Prints the config rustfmt picks for a file in <dir>, and returns 0, when it
# sets disable_all_formatting = true: rustfmt --check then exits 0 on any
# file.
_rustfmt_disabled() {
  local conf
  conf=$(_rustfmt_conf "$1") || return 1
  # rustfmt reads the file as TOML, so the key may be quoted and the file may
  # start with a UTF-8 byte order mark.
  LC_ALL=C sed "1s/^$(printf '\357\273\277')//" "$conf" |
    grep -qE '^[[:space:]]*["'\'']?disable_all_formatting["'\'']?[[:space:]]*=[[:space:]]*true([[:space:]#]|$)' ||
    return 1
  printf '%s\n' "$conf"
}

# _shfmt_lang <file> <extension>
# The language section besides [[shell]] that shfmt 3.14 reads for the file:
# bash for a .bash file, and for a .sh file the one its shebang selects (bash
# for bash or bats, zsh for zsh, none for sh, dash or mksh), else bash,
# shfmt's fallback. 'shell' stands for none.
_shfmt_lang() {
  if [ "$2" = bash ]; then
    echo bash
    return 0
  fi
  awk '
    NR == 1 {
      s = substr($0, 1, 32)
      if (s ~ /^#![ \t]*\/(usr\/)?bin\/(env[ \t]+)?(sh|dash|bash|mksh|bats|zsh)([ \t\r\f]|$)/) {
        sub(/^#![ \t]*\/(usr\/)?bin\/(env[ \t]+)?/, "", s)
        sub(/[ \t\r\f].*/, "", s)
        print (s == "zsh" ? "zsh" : (s == "bash" || s == "bats") ? "bash" : "shell")
      } else print "bash"
    }
    { exit }
    END { if (!NR) print "bash" }
  ' "$1"
}

# _editorconfig_sets_indent <dir> <extension> <language section>
# True when an .editorconfig of the project at or above <dir> sets
# indent_style in a section that plausibly applies to a shell file with that
# extension: [*], [**], a header naming the extension ([*.sh],
# [*.{sh,bash}]), [[shell]] or [[<language section>]]. This approximates
# EditorConfig's matching; it reads no paths in the globs. The walk stops
# after an .editorconfig with root = true and after the work tree's root
# (the first directory with a .git); outside a work tree it stops below
# $HOME, so ~/.editorconfig counts only for a project rooted at $HOME or
# above.
_editorconfig_sets_indent() {
  local dir="$1" root="$1" home=""
  while [ ! -e "$root/.git" ]; do
    if [ "$root" = / ]; then
      root=""
      break
    fi
    root=$(dirname -- "$root")
  done
  [ -n "${HOME:-}" ] && home=$(CDPATH='' cd -P -- "$HOME" 2>/dev/null && pwd -P)
  while :; do
    [ -z "$root" ] && [ "$dir" = "$home" ] && return 1
    if [ -f "$dir/.editorconfig" ]; then
      EC_EXT="$2" EC_LANG="$3" awk '
        BEGIN { ext = ENVIRON["EC_EXT"]; lang = ENVIRON["EC_LANG"] }
        { line = tolower($0); sub(/\r$/, "", line) }
        line ~ /^[ \t]*[#;]/ { next }
        line ~ /^[ \t]*\[/ {
          h = line
          sub(/^[ \t]*\[/, "", h)
          sub(/\][ \t]*$/, "", h)
          in_section = 1
          applies = h == "*" || h == "**" || h == "[shell]" || h == "[" lang "]" ||
            h ~ ("\\." ext "$") || h ~ ("\\." ext "[,}]") ||
            h ~ ("\\.[{]([^{}]*,)?" ext "(,[^{}]*)?[}]")
          next
        }
        !in_section && line ~ /^[ \t]*root[ \t]*=[ \t]*true[ \t]*$/ { root = 1 }
        applies && line ~ /^[ \t]*indent_style[ \t]*=[ \t]*(tab|space)[ \t]*$/ { found = 1; exit }
        END { exit (found ? 0 : (root ? 2 : 1)) }
      ' "$dir/.editorconfig"
      case $? in
        0) return 0 ;;
        2) return 1 ;;
      esac
    fi
    if [ "$dir" = "$root" ] || [ "$dir" = / ]; then
      return 1
    fi
    dir=$(dirname -- "$dir")
  done
}

case "$ext" in
  py)
    # typecheck (ty) resolves imports against the real environment, which
    # replaced the retired verify-imports.py; the docstring-presence rules
    # below replaced the retired doc-coverage.py for Python.
    #
    # Under force-exclude, ruff run from inside the project skips a named file
    # that its exclude or extend-exclude matches, prints "No Python files found
    # under the given path(s)" and exits 0: SKIPPED with that line, not PASS.
    # Not covered: a [tool.ruff.lint] or [tool.ruff.format] exclude also skips
    # the file there but prints nothing about it, so such a file still gets
    # PASS.
    run_tool_skip_on "format" "No Python files found" ruff format --check "$file"
    if _py_has_ruff_config "$file"; then
      run_tool_skip_on "lint" "No Python files found" ruff check "$file"
    else
      run_tool_skip_on "lint" "No Python files found" ruff check --extend-select D101,D102,D103 "$file"
    fi
    run_tool "typecheck" ty check "$file"
    ;;
  ts|tsx|js|jsx|mjs|cjs)
    # prettier --check skips a file that the .prettierignore or .gitignore of
    # the directory it runs from matches and still exits 0, and it stops with
    # "No matching files" (exit 2) on a named file under node_modules;
    # --file-info reports both as ignored: SKIPPED, not PASS or FAIL. Not
    # covered: requirePragma (on a file
    # with no @format or @prettier pragma) and checkIgnorePragma (on a file
    # with @noformat or @noprettier) also make --check skip the file and exit
    # 0, and --file-info cannot see that, so such a file still gets PASS.
    if command -v prettier >/dev/null 2>&1 &&
      prettier --file-info "$file" 2>/dev/null | grep -q '"ignored":[[:space:]]*true'; then
      skip "format" "prettier ignores $file (an ignore file or node_modules, where it runs), so prettier --check would not check it"
    else
      run_tool "format" prettier --check "$file"
    fi
    # Given a file by name, eslint exits 0 with a single "File ignored ..."
    # warning when its config ignores the file, no config object matches it,
    # or it lies outside the base path: SKIPPED with that line, not PASS.
    run_tool_skip_on "lint" "File ignored" eslint "$file"
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
    # project's rustfmt config sets one. When that config sets
    # disable_all_formatting = true, rustfmt --check exits 0 on any file:
    # SKIPPED, and rustfmt does not run.
    rs_dir=$(_abs_dir "$file")
    edition=$(_cargo_edition "$rs_dir")
    if rs_conf=$(_rustfmt_disabled "$rs_dir"); then
      skip "format" "$rs_conf sets disable_all_formatting = true, so rustfmt --check would not check $file"
    elif [ -n "$edition" ] && ! _rustfmt_sets_edition "$rs_dir"; then
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
    # makes shfmt ignore EditorConfig, so where the project's .editorconfig
    # sets the indentation of shell files, shfmt runs with none and the
    # project's settings win.
    if _editorconfig_sets_indent "$(_abs_dir "$file")" "$ext" "$(_shfmt_lang "$file" "$ext")"; then
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
