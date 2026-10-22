#!/usr/bin/env bats
#
# Tests for run-checks.sh. The script dispatches format/lint/typecheck by
# file extension, SKIPs any tool that is not on PATH, and reports a summary.
# These tests assert the usage/exit-code contract and the SKIP behaviour,
# which hold regardless of which language toolchains are installed.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../agents/src/shared/scripts/run-checks.sh"
  # the physical path: the script cd -P's before it runs tsc, and the stubs
  # record that directory (macOS's /var is a symlink to /private/var)
  WORK="$(cd -P -- "$(mktemp -d)" && pwd -P)"
}

teardown() {
  rm -rf "$WORK"
}

# _found_above <dir> <name>: true when <name> exists in a directory above
# <dir>. A tsconfig.json, Cargo.toml, rustfmt config or .editorconfig above
# the temp dir would change what the script runs, so those tests skip.
_found_above() {
  local d
  d=$(dirname "$1")
  while :; do
    [ -e "$d/$2" ] && return 0
    [ "$d" = "/" ] && return 1
    d=$(dirname "$d")
  done
}

# _stub <tool>: a fake <tool> in $WORK/bin that appends its working directory
# and arguments to $WORK/<tool>.log, prints $WORK/<tool>.out when it exists,
# and exits with the number in $WORK/<tool>.rc (0 without one).
_stub() {
  mkdir -p "$WORK/bin"
  cat > "$WORK/bin/$1" <<EOF
#!/usr/bin/env bash
printf 'cwd=%s argv=%s\n' "\$PWD" "\$*" >> "$WORK/$1.log"
[ -f "$WORK/$1.out" ] && cat "$WORK/$1.out"
exit "\$(cat "$WORK/$1.rc" 2>/dev/null || echo 0)"
EOF
  chmod +x "$WORK/bin/$1"
}

# _stub_tsc: a fake tsc in $WORK/bin that logs like _stub. Given -p ./<name>,
# a --showConfig run prints $WORK/<name>.show (an empty config without one)
# and exits with the number in $WORK/<name>.show.rc; any other run prints
# $WORK/<name>.out, else $WORK/tsc.out, and exits with the number in
# $WORK/<name>.rc, else $WORK/tsc.rc (0 without either). Like tsc, it writes
# the --tsBuildInfoFile it is given, and logs 'wrote <path>'.
_stub_tsc() {
  mkdir -p "$WORK/bin"
  {
    printf '#!/usr/bin/env bash\nW=%q\n' "$WORK"
    cat <<'EOF'
printf 'cwd=%s argv=%s\n' "$PWD" "$*" >> "$W/tsc.log"
show=0 name=tsc
while [ "$#" -gt 0 ]; do
  case $1 in
    --showConfig) show=1 ;;
    --tsBuildInfoFile) shift; : > "$1" && printf 'wrote %s\n' "$1" >> "$W/tsc.log" ;;
    -p) shift; name=${1##*/} ;;
  esac
  shift
done
if [ "$show" = 1 ]; then
  if [ -f "$W/$name.show" ]; then cat "$W/$name.show"; else printf '{\n    "compilerOptions": {}\n}\n'; fi
  exit "$(cat "$W/$name.show.rc" 2>/dev/null || echo 0)"
fi
out="$W/$name.out" rc="$W/$name.rc"
[ -f "$out" ] || out="$W/tsc.out"
[ -f "$rc" ] || rc="$W/tsc.rc"
[ -f "$out" ] && cat "$out"
exit "$(cat "$rc" 2>/dev/null || echo 0)"
EOF
  } > "$WORK/bin/tsc"
  chmod +x "$WORK/bin/tsc"
}

# _show <file> <compilerOptions line>...: write a 'tsc --showConfig' result,
# JSON indented four spaces a level as tsc prints it, with those options.
_show() {
  local f="$1" sep="" opt
  shift
  {
    printf '{\n    "compilerOptions": {'
    for opt in "$@"; do
      printf '%s\n        %s' "$sep" "$opt"
      sep=","
    done
    [ "$#" -gt 0 ] && printf '\n    '
    printf '}\n}\n'
  } > "$f"
}

# _run_stubbed <file>: run the script with the stubs and the system
# directories alone on PATH, so tools installed elsewhere stay out of it.
_run_stubbed() {
  run env PATH="$WORK/bin:/usr/bin:/bin" "$SCRIPT" "$1"
}

# _ts_project: $WORK/proj with a tsconfig.json and src/a.ts, src/b.ts.
_ts_project() {
  mkdir -p "$WORK/proj/src"
  printf '{}\n' > "$WORK/proj/tsconfig.json"
  printf 'export const a = 1;\n' > "$WORK/proj/src/a.ts"
  printf 'export const b = 2;\n' > "$WORK/proj/src/b.ts"
}

@test "no arguments: usage error, exit 2" {
  run "$SCRIPT"
  [ "$status" -eq 2 ]
  [[ "$output" == *"usage:"* ]]
}

@test "too many arguments: usage error, exit 2" {
  run "$SCRIPT" a b
  [ "$status" -eq 2 ]
}

@test "file not found: exit 2" {
  run "$SCRIPT" "$WORK/missing.py"
  [ "$status" -eq 2 ]
  [[ "$output" == *"file not found"* ]]
}

@test "unknown extension: exit 2" {
  printf 'hello\n' > "$WORK/data.unknownext"
  run "$SCRIPT" "$WORK/data.unknownext"
  [ "$status" -eq 2 ]
  [[ "$output" == *"unknown extension"* ]]
}

@test "clean shell file: all checks pass, summary printed, exit 0" {
  printf '#!/usr/bin/env bash\necho hi\n' > "$WORK/ok.sh"
  run "$SCRIPT" "$WORK/ok.sh"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SUMMARY:"* ]]
  [[ "$output" == *"0 failed"* ]]
}

@test "shell file with lint problem: exit 1" {
  # Unquoted variable in a risky context trips shellcheck.
  printf '#!/usr/bin/env bash\nrm $1\n' > "$WORK/bad.sh"
  run "$SCRIPT" "$WORK/bad.sh"
  [ "$status" -eq 1 ]
  [[ "$output" == *"FAIL"* ]]
}

@test "C# file: every check is project-level SKIPPED, exit 0" {
  printf 'public class Foo {}\n' > "$WORK/Foo.cs"
  run "$SCRIPT" "$WORK/Foo.cs"
  [ "$status" -eq 0 ]
  [[ "$output" == *"SKIPPED"* ]]
  [[ "$output" == *"3 skipped"* ]]
}

@test "Go file: lint and typecheck are project-level SKIPPED" {
  printf 'package main\n\nfunc main() {}\n' > "$WORK/main.go"
  run "$SCRIPT" "$WORK/main.go"
  # gofmt may pass or be skipped, but lint+typecheck are always project-only.
  [[ "$output" == *"golangci-lint operates at module level"* ]]
  [[ "$output" == *"Go has no file-level typecheck"* ]]
}

@test "PowerShell file: parse passes on valid script (or skips without pwsh)" {
  printf 'function Get-Widget {\n    param([string]$Name)\n    $Name\n}\n' > "$WORK/good.ps1"
  run "$SCRIPT" "$WORK/good.ps1"
  [ "$status" -eq 0 ]
  if command -v pwsh >/dev/null 2>&1; then
    [[ "$output" == *"[parse    ] PASS"* ]]
  else
    [[ "$output" == *"SKIPPED"* ]]
  fi
  [[ "$output" == *"no static typecheck"* ]]
}

@test "PowerShell file: parse error fails with a line number" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
  printf 'function Broken {\n  if ($x) {\n' > "$WORK/bad.ps1"
  run "$SCRIPT" "$WORK/bad.ps1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[parse    ] FAIL"* ]]
  [[ "$output" == *"line "* ]]
}

@test "PowerShell file: an Error-severity analyzer finding fails lint" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
  pwsh -NoProfile -Command 'if(Get-Module -ListAvailable PSScriptAnalyzer){exit 0};exit 1' \
    || skip "PSScriptAnalyzer not installed"
  printf '$s = ConvertTo-SecureString "pw" -AsPlainText -Force\n' > "$WORK/err.ps1"
  run "$SCRIPT" "$WORK/err.ps1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[lint     ] FAIL"* ]]
}

@test "PowerShell file: wildcard characters in the name are treated literally" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
  # regression: Resolve-Path/-Path expanded [n] as a glob, so a valid file
  # false-FAILED the parse and lint silently analyzed zero (or other) files
  printf 'function Get-Widget {\n    param()\n}\n' > "$WORK/clea[n].ps1"
  run "$SCRIPT" "$WORK/clea[n].ps1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[parse    ] PASS"* ]]
}

@test "PowerShell file: a planted PSScriptAnalyzerSettings.psd1 cannot run code" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
  pwsh -NoProfile -Command 'if(Get-Module -ListAvailable PSScriptAnalyzer){exit 0};exit 1' \
    || skip "PSScriptAnalyzer not installed"
  # regression: the lint step passed no -Settings, so PSScriptAnalyzer
  # auto-discovered PSScriptAnalyzerSettings.psd1 from the directory of the
  # analyzed file. That profile's CustomRulePath is Import-Module'd during
  # analyzer setup, so a cloned repo could execute code as the user during a
  # lint that prints only PASS/FAIL.
  mkdir -p "$WORK/rules"
  printf 'function Get-Widget {\n    param()\n}\n' > "$WORK/Deploy.ps1"
  cat > "$WORK/rules/Evil.psm1" <<EOF
Set-Content -Path '$WORK/PWNED' -Value 'custom rule module executed'
function Measure-Nothing {
    [CmdletBinding()]
    [OutputType([Microsoft.Windows.PowerShell.ScriptAnalyzer.Generic.DiagnosticRecord[]])]
    Param([System.Management.Automation.Language.ScriptBlockAst]\$ScriptBlockAst)
    return @()
}
Export-ModuleMember -Function Measure-Nothing
EOF
  cat > "$WORK/PSScriptAnalyzerSettings.psd1" <<EOF
@{
    CustomRulePath = '$WORK/rules/Evil.psm1'
    IncludeDefaultRules = \$true
    Severity = 'Error'
}
EOF
  run "$SCRIPT" "$WORK/Deploy.ps1"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[lint     ] PASS"* ]]
  [ ! -e "$WORK/PWNED" ]
}

@test "PowerShell file: a planted settings profile cannot silence the lint gate" {
  command -v pwsh >/dev/null 2>&1 || skip "pwsh not installed"
  pwsh -NoProfile -Command 'if(Get-Module -ListAvailable PSScriptAnalyzer){exit 0};exit 1' \
    || skip "PSScriptAnalyzer not installed"
  # The same auto-discovery let checked-out content weaken den's own gate:
  # profile keys take precedence over command-line parameters.
  printf '$s = ConvertTo-SecureString "pw" -AsPlainText -Force\n' > "$WORK/err.ps1"
  cat > "$WORK/PSScriptAnalyzerSettings.psd1" <<'EOF'
@{
    ExcludeRules = @('PSAvoidUsingConvertToSecureStringWithPlainText')
    Severity = 'Error'
}
EOF
  run "$SCRIPT" "$WORK/err.ps1"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[lint     ] FAIL"* ]]
}

@test "TypeScript: tsc checks the nearest tsconfig.json project from its directory (stub tsc)" {
  _found_above "$WORK" tsconfig.json && skip "a tsconfig.json above the temp dir"
  # regression: 'tsc --noEmit <file>' ignored tsconfig.json before TS 6.0
  # and fails with TS5112 from 6.0 on
  _ts_project
  _stub_tsc
  printf 'src/a.ts\n' > "$WORK/tsc.out"
  _run_stubbed "$WORK/proj/src/a.ts"
  [[ "$output" == *"[typecheck] PASS      tsc --noEmit --pretty false --explainFiles -p $WORK/proj/tsconfig.json"* ]]
  grep -qx "cwd=$WORK/proj argv=--showConfig -p ./tsconfig.json" "$WORK/tsc.log"
  grep -qx "cwd=$WORK/proj argv=--noEmit --pretty false --explainFiles -p ./tsconfig.json" "$WORK/tsc.log"
}

@test "TypeScript: errors in other files do not fail this file (stub tsc)" {
  _found_above "$WORK" tsconfig.json && skip "a tsconfig.json above the temp dir"
  _ts_project
  _stub_tsc
  printf '%s\n' \
    "src/b.ts(1,14): error TS2322: Type 'string' is not assignable to type 'number'." \
    "src/a.ts" "  Matched by include pattern '**/*' in 'tsconfig.json'" "src/b.ts" \
    > "$WORK/tsc.out"
  printf '2\n' > "$WORK/tsc.rc"
  _run_stubbed "$WORK/proj/src/a.ts"
  [[ "$output" == *"[typecheck] PASS"*"not counted: 1"* ]]
  _run_stubbed "$WORK/proj/src/b.ts"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[typecheck] FAIL (2)"* ]]
  [[ "$output" == *"src/b.ts(1,14): error TS2322"* ]]
}

@test "TypeScript: a syntax error elsewhere or a config error is SKIPPED, never PASS (stub tsc)" {
  _found_above "$WORK" tsconfig.json && skip "a tsconfig.json above the temp dir"
  # tsc type-checks nothing while any file has a syntax error or the config
  # has an option error, so this file's own type errors would not be reported
  _ts_project
  _stub_tsc
  printf '1\n' > "$WORK/tsc.rc"
  printf '%s\n' "src/b.ts(1,9): error TS1005: ';' expected." "src/a.ts" "src/b.ts" > "$WORK/tsc.out"
  _run_stubbed "$WORK/proj/src/a.ts"
  [[ "$output" == *"[typecheck] SKIPPED   tsc -p $WORK/proj/tsconfig.json may have stopped before type-checking src/a.ts"* ]]
  [[ "$output" == *"src/b.ts(1,9): error TS1005"* ]]
  printf '%s\n' "tsconfig.json(3,5): error TS5101: Option 'baseUrl' is deprecated." "src/a.ts" > "$WORK/tsc.out"
  _run_stubbed "$WORK/proj/src/a.ts"
  [[ "$output" == *"[typecheck] SKIPPED   tsc -p $WORK/proj/tsconfig.json may have stopped before type-checking src/a.ts"* ]]
}

@test "TypeScript: a config tsc cannot parse is SKIPPED before any check runs (stub tsc)" {
  _found_above "$WORK" tsconfig.json && skip "a tsconfig.json above the temp dir"
  # tsc --showConfig fails on what it cannot parse, an empty program
  # included (TS18003), and the check never runs
  _ts_project
  _stub_tsc
  printf '%s\n' "error TS18003: No inputs were found in config file '$WORK/proj/tsconfig.json'." > "$WORK/tsconfig.json.show"
  printf '1\n' > "$WORK/tsconfig.json.show.rc"
  _run_stubbed "$WORK/proj/src/a.ts"
  [[ "$output" == *"[typecheck] SKIPPED   tsc --showConfig -p $WORK/proj/tsconfig.json reports errors in the config, so src/a.ts was not checked"* ]]
  [[ "$output" == *"             error TS18003: No inputs were found"* ]]
  [ "$(wc -l < "$WORK/tsc.log")" -eq 1 ]
}

@test "TypeScript: other files' checker errors outside TS2xxx/TS7xxx still mean tsc checked (stub tsc)" {
  _found_above "$WORK" tsconfig.json && skip "a tsconfig.json above the temp dir"
  _ts_project
  _stub_tsc
  printf '2\n' > "$WORK/tsc.rc"
  for err in "TS18048: 'x' is possibly 'undefined'." "TS4114: This member must have an 'override' modifier because it overrides a member in the base class 'B'."; do
    printf '%s\n' "src/b.ts(1,1): error $err" "src/a.ts" "src/b.ts" > "$WORK/tsc.out"
    _run_stubbed "$WORK/proj/src/a.ts"
    [[ "$output" == *"[typecheck] PASS"*"not counted: 1"* ]]
  done
}

@test "TypeScript: a file the tsconfig.json program leaves out is SKIPPED (stub tsc)" {
  _found_above "$WORK" tsconfig.json && skip "a tsconfig.json above the temp dir"
  _ts_project
  printf 'export const c = 3;\n' > "$WORK/proj/src/c.js"
  _stub_tsc
  printf 'src/b.ts\n' > "$WORK/tsc.out"
  _run_stubbed "$WORK/proj/src/a.ts"
  [[ "$output" == *"[typecheck] SKIPPED   src/a.ts is not in the program of $WORK/proj/tsconfig.json ("* ]]
  _run_stubbed "$WORK/proj/src/c.js"
  [[ "$output" == *"[typecheck] SKIPPED   src/c.js is not in the program"*"JavaScript also needs allowJs)"* ]]
  # left out while other files fail is still left out, not a stop
  printf '%s\n' "src/b.ts(1,9): error TS1005: ';' expected." "src/b.ts" > "$WORK/tsc.out"
  printf '1\n' > "$WORK/tsc.rc"
  _run_stubbed "$WORK/proj/src/a.ts"
  [[ "$output" == *"[typecheck] SKIPPED   src/a.ts is not in the program"* ]]
}

@test "TypeScript: a solution-style tsconfig.json hands the file to the referenced config that lists it (stub tsc)" {
  _found_above "$WORK" tsconfig.json && skip "a tsconfig.json above the temp dir"
  # regression: create-vite's tsconfig.json has "files": [] and references
  # only, so 'tsc -p' on it checked nothing, exited 0, and every file was
  # SKIPPED as not in the program
  mkdir -p "$WORK/app/src"
  printf '{ "files": [], "references": [{ "path": "./tsconfig.app.json" }, { "path": "./tsconfig.node.json" }] }\n' > "$WORK/app/tsconfig.json"
  printf '{ "include": ["src"], "references": [{ "path": "." }] }\n' > "$WORK/app/tsconfig.app.json"
  printf '{ "include": ["vite.config.ts"] }\n' > "$WORK/app/tsconfig.node.json"
  printf 'export const ok = 1;\n' > "$WORK/app/src/ok.ts"
  printf 'export const bad: number = "x";\n' > "$WORK/app/src/bad.ts"
  printf 'export default {};\n' > "$WORK/app/vite.config.ts"
  printf 'export const lost = 1;\n' > "$WORK/app/lost.ts"
  _stub_tsc
  printf '%s\n' '{' '    "compilerOptions": {},' '    "references": [' \
    '        {' '            "path": "./tsconfig.app.json"' '        },' \
    '        {' '            "path": "./tsconfig.node.json"' '        }' \
    '    ],' '    "files": []' '}' > "$WORK/tsconfig.json.show"
  # the app config points back at the solution: a cycle the walk must stop
  printf '%s\n' '{' '    "compilerOptions": {},' '    "references": [' \
    '        {' '            "path": "."' '        }' '    ]' '}' > "$WORK/tsconfig.app.json.show"
  : > "$WORK/tsconfig.json.out"
  printf '%s\n' "src/bad.ts(1,14): error TS2322: Type 'string' is not assignable to type 'number'." \
    "src/bad.ts" "src/ok.ts" > "$WORK/tsconfig.app.json.out"
  printf '2\n' > "$WORK/tsconfig.app.json.rc"
  printf 'vite.config.ts\n' > "$WORK/tsconfig.node.json.out"
  _run_stubbed "$WORK/app/src/ok.ts"
  [[ "$output" == *"[typecheck] PASS      tsc --noEmit --pretty false --explainFiles -p $WORK/app/tsconfig.app.json (errors in other files, not counted: 1)"* ]]
  _run_stubbed "$WORK/app/src/bad.ts"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[typecheck] FAIL (2) tsc --noEmit --pretty false --explainFiles -p $WORK/app/tsconfig.app.json"* ]]
  [[ "$output" == *"             src/bad.ts(1,14): error TS2322"* ]]
  _run_stubbed "$WORK/app/vite.config.ts"
  [[ "$output" == *"[typecheck] PASS      tsc --noEmit --pretty false --explainFiles -p $WORK/app/tsconfig.node.json"* ]]
  : > "$WORK/tsc.log"
  _run_stubbed "$WORK/app/lost.ts"
  [[ "$output" == *"[typecheck] SKIPPED   lost.ts is not in the program of $WORK/app/tsconfig.json or of the configs it references (2 checked)"* ]]
  [ "$(grep -c -- '--explainFiles -p ./tsconfig.json$' "$WORK/tsc.log")" -eq 1 ]
  [ "$(grep -c -- '--explainFiles' "$WORK/tsc.log")" -eq 3 ]
}

@test "TypeScript: JavaScript is type-checked only under checkJs or // @ts-check (stub tsc)" {
  _found_above "$WORK" tsconfig.json && skip "a tsconfig.json above the temp dir"
  # regression: with allowJs alone, tsc lists a .js file in the program but
  # reports no type errors in it, and the file got PASS
  _ts_project
  printf 'export const c = 3;\n' > "$WORK/proj/src/c.js"
  printf '#!/usr/bin/env node\n// @ts-check\nexport const d = 4;\n' > "$WORK/proj/src/d.js"
  printf '// @ts-nocheck\nexport const e = 5;\n' > "$WORK/proj/src/e.js"
  printf 'export const f = 6;\n// @ts-check\n' > "$WORK/proj/src/f.js"
  _stub_tsc
  printf '%s\n' src/a.ts src/b.ts src/c.js src/d.js src/e.js src/f.js > "$WORK/tsc.out"
  _show "$WORK/tsconfig.json.show" '"allowJs": true'
  _run_stubbed "$WORK/proj/src/c.js"
  [[ "$output" == *"[typecheck] SKIPPED   allowJs without checkJs: tsc reports no type errors in JavaScript (src/c.js)"* ]]
  _run_stubbed "$WORK/proj/src/d.js"
  [[ "$output" == *"[typecheck] PASS"* ]]
  _run_stubbed "$WORK/proj/src/f.js"
  [[ "$output" == *"[typecheck] SKIPPED   allowJs without checkJs"* ]]
  _show "$WORK/tsconfig.json.show" '"allowJs": true' '"checkJs": true'
  _run_stubbed "$WORK/proj/src/c.js"
  [[ "$output" == *"[typecheck] PASS"* ]]
  _run_stubbed "$WORK/proj/src/e.js"
  [[ "$output" == *"[typecheck] SKIPPED   src/e.js has a // @ts-nocheck comment: tsc reports no type errors in it"* ]]
  # tsc still reports a JavaScript file's syntax errors, and they FAIL
  _show "$WORK/tsconfig.json.show" '"allowJs": true'
  printf '%s\n' "src/c.js(1,14): error TS1005: ',' expected." src/a.ts src/c.js > "$WORK/tsc.out"
  printf '1\n' > "$WORK/tsc.rc"
  _run_stubbed "$WORK/proj/src/c.js"
  [ "$status" -eq 1 ]
  [[ "$output" == *"[typecheck] FAIL (1)"* ]]
}

@test "TypeScript: an incremental config writes its .tsbuildinfo to a temp dir, not the tree (stub tsc)" {
  _found_above "$WORK" tsconfig.json && skip "a tsconfig.json above the temp dir"
  _ts_project
  _stub_tsc
  printf 'src/a.ts\n' > "$WORK/tsc.out"
  _run_stubbed "$WORK/proj/src/a.ts"
  [ "$(grep -c -- '--tsBuildInfoFile' "$WORK/tsc.log")" -eq 0 ]
  # create-vite's tsconfig.app.json sets tsBuildInfoFile alone, which tsc
  # rejects outside 'tsc -b' unless --incremental comes along
  for opt in '"incremental": true' '"composite": true' '"tsBuildInfoFile": "./node_modules/.tmp/tsconfig.app.tsbuildinfo"'; do
    : > "$WORK/tsc.log"
    _show "$WORK/tsconfig.json.show" "$opt"
    _run_stubbed "$WORK/proj/src/a.ts"
    [[ "$output" == *"[typecheck] PASS"* ]]
    grep -q -- '--explainFiles --incremental --tsBuildInfoFile ' "$WORK/tsc.log"
    info=$(sed -n 's/^wrote //p' "$WORK/tsc.log")
    [ -n "$info" ]
    [[ "$info" != "$WORK/"* ]]
    [ ! -e "$info" ]
    [ ! -e "$(dirname "$info")" ]
  done
}

@test "TypeScript: a path with parentheses matches its own diagnostics (stub tsc)" {
  _found_above "$WORK" tsconfig.json && skip "a tsconfig.json above the temp dir"
  _ts_project
  mkdir -p "$WORK/proj/app/(auth)"
  printf 'export const p = 1;\n' > "$WORK/proj/app/(auth)/page.tsx"
  _stub_tsc
  printf '%s\n' \
    "app/(auth)/page.tsx(1,14): error TS2322: Type 'string' is not assignable to type 'number'." \
    "  The expected type comes from this declaration." \
    "app/(auth)/page.tsx" "src/a.ts" > "$WORK/tsc.out"
  printf '2\n' > "$WORK/tsc.rc"
  _run_stubbed "$WORK/proj/app/(auth)/page.tsx"
  [[ "$output" == *"[typecheck] FAIL (2)"* ]]
  [[ "$output" == *"  The expected type comes from this declaration."* ]]
  _run_stubbed "$WORK/proj/src/a.ts"
  [[ "$output" == *"[typecheck] PASS"*"not counted: 1"* ]]
}

@test "TypeScript: with no tsconfig.json, .ts is checked alone and JavaScript is SKIPPED (stub tsc)" {
  _found_above "$WORK" tsconfig.json && skip "a tsconfig.json above the temp dir"
  mkdir -p "$WORK/loose"
  printf 'export const x = 1;\n' > "$WORK/loose/x.ts"
  printf 'export const y = 1;\n' > "$WORK/loose/y.js"
  _stub_tsc
  _run_stubbed "$WORK/loose/x.ts"
  [[ "$output" == *"[typecheck] PASS      tsc --noEmit $WORK/loose/x.ts (no tsconfig.json above it)"* ]]
  grep -qx "cwd=$WORK/loose argv=--noEmit ./x.ts" "$WORK/tsc.log"
  _run_stubbed "$WORK/loose/y.js"
  [[ "$output" == *"[typecheck] SKIPPED   no tsconfig.json above"*"under checkJs or // @ts-check"* ]]
  [ "$(wc -l < "$WORK/tsc.log")" -eq 1 ]
}

@test "TypeScript (tsc): tsconfig paths apply and another file's errors are not counted" {
  command -v tsc >/dev/null 2>&1 || skip "tsc not installed"
  _found_above "$WORK" tsconfig.json && skip "a tsconfig.json above the temp dir"
  mkdir -p "$WORK/proj/src/lib"
  cat > "$WORK/proj/tsconfig.json" <<'EOF'
{
  "compilerOptions": {
    "strict": true,
    "noEmit": true,
    "paths": { "@lib/*": ["./src/lib/*"] }
  },
  "include": ["src"]
}
EOF
  printf 'export const value: number = 1;\n' > "$WORK/proj/src/lib/value.ts"
  printf 'import { value } from "@lib/value";\nexport const doubled: number = value * 2;\n' > "$WORK/proj/src/ok.ts"
  printf 'export const n: number = "x";\n' > "$WORK/proj/src/bad.ts"
  run "$SCRIPT" "$WORK/proj/src/ok.ts"
  [[ "$output" == *"[typecheck] PASS"*"not counted: 1"* ]]
  run "$SCRIPT" "$WORK/proj/src/bad.ts"
  [[ "$output" == *"[typecheck] FAIL"* ]]
  [[ "$output" == *"src/bad.ts(1,14): error TS2322"* ]]
}

@test "TypeScript (tsc): a syntax error elsewhere hides this file's type errors, so SKIPPED" {
  command -v tsc >/dev/null 2>&1 || skip "tsc not installed"
  _found_above "$WORK" tsconfig.json && skip "a tsconfig.json above the temp dir"
  mkdir -p "$WORK/proj/src"
  printf '{ "compilerOptions": { "strict": true, "noEmit": true }, "include": ["src"] }\n' > "$WORK/proj/tsconfig.json"
  printf 'export const n: number = "x";\n' > "$WORK/proj/src/typed.ts"
  printf 'export const = ;\n' > "$WORK/proj/src/broken.ts"
  run "$SCRIPT" "$WORK/proj/src/typed.ts"
  [[ "$output" == *"[typecheck] SKIPPED   tsc -p $WORK/proj/tsconfig.json may have stopped before type-checking src/typed.ts"* ]]
}

@test "TypeScript (tsc): JavaScript is type-checked only in a project that takes it" {
  command -v tsc >/dev/null 2>&1 || skip "tsc not installed"
  _found_above "$WORK" tsconfig.json && skip "a tsconfig.json above the temp dir"
  mkdir -p "$WORK/plain/src" "$WORK/loose/src" "$WORK/checked/src"
  printf '{ "compilerOptions": { "noEmit": true }, "include": ["src"] }\n' > "$WORK/plain/tsconfig.json"
  printf '{ "compilerOptions": { "allowJs": true, "noEmit": true }, "include": ["src"] }\n' > "$WORK/loose/tsconfig.json"
  printf '{ "compilerOptions": { "allowJs": true, "checkJs": true, "noEmit": true }, "include": ["src"] }\n' > "$WORK/checked/tsconfig.json"
  printf '/** @type {number} */\nexport const n = "x";\n' > "$WORK/plain/src/a.js"
  # a .ts file keeps the program from being empty: on an empty one tsc
  # stops with TS18003 instead of leaving a.js out
  printf 'export const b = 1;\n' > "$WORK/plain/src/b.ts"
  cp "$WORK/plain/src/a.js" "$WORK/loose/src/a.js"
  cp "$WORK/plain/src/a.js" "$WORK/checked/src/a.js"
  run "$SCRIPT" "$WORK/plain/src/a.js"
  [[ "$output" == *"[typecheck] SKIPPED   src/a.js is not in the program"* ]]
  run "$SCRIPT" "$WORK/loose/src/a.js"
  [[ "$output" == *"[typecheck] SKIPPED   allowJs without checkJs"* ]]
  { printf '// @ts-check\n'; cat "$WORK/plain/src/a.js"; } > "$WORK/loose/src/a.js"
  run "$SCRIPT" "$WORK/loose/src/a.js"
  [[ "$output" == *"[typecheck] FAIL"* ]]
  [[ "$output" == *"src/a.js(3,14): error TS2322"* ]]
  run "$SCRIPT" "$WORK/checked/src/a.js"
  [[ "$output" == *"[typecheck] FAIL"* ]]
  [[ "$output" == *"src/a.js(2,14): error TS2322"* ]]
}

@test "TypeScript (tsc): a create-vite tree is checked through its referenced configs, and no .tsbuildinfo lands in it" {
  command -v tsc >/dev/null 2>&1 || skip "tsc not installed"
  _found_above "$WORK" tsconfig.json && skip "a tsconfig.json above the temp dir"
  mkdir -p "$WORK/app/src"
  printf '{ "files": [], "references": [{ "path": "./tsconfig.app.json" }, { "path": "./tsconfig.node.json" }] }\n' > "$WORK/app/tsconfig.json"
  cat > "$WORK/app/tsconfig.app.json" <<'EOF'
{
  "compilerOptions": {
    "tsBuildInfoFile": "./node_modules/.tmp/tsconfig.app.tsbuildinfo",
    "strict": true,
    "noEmit": true
  },
  "include": ["src"]
}
EOF
  printf '{ "compilerOptions": { "incremental": true, "strict": true, "noEmit": true }, "include": ["vite.config.ts"] }\n' > "$WORK/app/tsconfig.node.json"
  printf 'export const ok: number = 1;\n' > "$WORK/app/src/ok.ts"
  printf 'export const bad: number = "x";\n' > "$WORK/app/src/bad.ts"
  printf 'export default {};\n' > "$WORK/app/vite.config.ts"
  run "$SCRIPT" "$WORK/app/src/ok.ts"
  [[ "$output" == *"[typecheck] PASS"*"-p $WORK/app/tsconfig.app.json (errors in other files, not counted: 1)"* ]]
  run "$SCRIPT" "$WORK/app/src/bad.ts"
  [[ "$output" == *"[typecheck] FAIL"*"-p $WORK/app/tsconfig.app.json"* ]]
  [[ "$output" == *"src/bad.ts(1,14): error TS2322"* ]]
  run "$SCRIPT" "$WORK/app/vite.config.ts"
  [[ "$output" == *"[typecheck] PASS"*"-p $WORK/app/tsconfig.node.json"* ]]
  [ -z "$(find "$WORK/app" -name '*.tsbuildinfo')" ]
}

@test "Rust (rustfmt): async fn in an edition-2021 crate passes" {
  command -v rustfmt >/dev/null 2>&1 || skip "rustfmt not installed"
  for f in Cargo.toml rustfmt.toml .rustfmt.toml; do
    _found_above "$WORK" "$f" && skip "a $f above the temp dir"
  done
  # regression: rustfmt does not read Cargo.toml, so it parsed Rust 2015 and
  # FAILed 'async fn' with E0670
  mkdir -p "$WORK/crate/src"
  printf '[package]\nname = "probe"\nversion = "0.1.0"\nedition = "2021"\n' > "$WORK/crate/Cargo.toml"
  printf 'pub async fn fetch(x: u32) -> u32 {\n    x + 1\n}\n' > "$WORK/crate/src/lib.rs"
  run "$SCRIPT" "$WORK/crate/src/lib.rs"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[format   ] PASS      rustfmt --check --edition 2021"* ]]
}

@test "Rust (rustfmt): an edition inherited from the workspace is passed" {
  command -v rustfmt >/dev/null 2>&1 || skip "rustfmt not installed"
  for f in Cargo.toml rustfmt.toml .rustfmt.toml; do
    _found_above "$WORK" "$f" && skip "a $f above the temp dir"
  done
  mkdir -p "$WORK/ws/dotted/src" "$WORK/ws/inline/src"
  printf '[workspace]\nmembers = ["dotted", "inline"]\n\n[workspace.package]\nedition = "2021"\n' > "$WORK/ws/Cargo.toml"
  printf '[package]\nname = "dotted"\nversion = "0.1.0"\nedition.workspace = true\n' > "$WORK/ws/dotted/Cargo.toml"
  printf '[package]\nname = "inline"\nversion = "0.1.0"\nedition = { workspace = true }\n' > "$WORK/ws/inline/Cargo.toml"
  for m in dotted inline; do
    printf 'pub async fn fetch(x: u32) -> u32 {\n    x + 1\n}\n' > "$WORK/ws/$m/src/lib.rs"
    run "$SCRIPT" "$WORK/ws/$m/src/lib.rs"
    [ "$status" -eq 0 ]
    [[ "$output" == *"rustfmt --check --edition 2021"* ]]
  done
}

@test "Rust (rustfmt): a rustfmt.toml that sets the edition is not overridden" {
  command -v rustfmt >/dev/null 2>&1 || skip "rustfmt not installed"
  for f in Cargo.toml rustfmt.toml .rustfmt.toml; do
    _found_above "$WORK" "$f" && skip "a $f above the temp dir"
  done
  mkdir -p "$WORK/crate/src"
  printf '[package]\nname = "probe"\nversion = "0.1.0"\nedition = "2021"\n' > "$WORK/crate/Cargo.toml"
  printf 'edition = "2018"\n' > "$WORK/crate/rustfmt.toml"
  printf 'pub async fn fetch(x: u32) -> u32 {\n    x + 1\n}\n' > "$WORK/crate/src/lib.rs"
  run "$SCRIPT" "$WORK/crate/src/lib.rs"
  [ "$status" -eq 0 ]
  [[ "$output" == *"[format   ] PASS      rustfmt --check $WORK/crate/src/lib.rs"* ]]
}

@test "Shell: shfmt gets -i 2 -ci -s when no .editorconfig is above the file (stub shfmt)" {
  _found_above "$WORK" .editorconfig && skip "an .editorconfig above the temp dir"
  # regression: bare 'shfmt -d' indents with tabs, so every script written in
  # shell.md's 2-space style FAILed
  _stub shfmt
  printf '#!/usr/bin/env bash\necho hi\n' > "$WORK/a.sh"
  _run_stubbed "$WORK/a.sh"
  [[ "$output" == *"[format   ] PASS      shfmt -d -i 2 -ci -s $WORK/a.sh"* ]]
}

@test "Shell: an .editorconfig makes shfmt run with no formatting flags (stub shfmt)" {
  _found_above "$WORK" .editorconfig && skip "an .editorconfig above the temp dir"
  # a formatting flag makes shfmt ignore EditorConfig
  _stub shfmt
  mkdir -p "$WORK/proj/bin"
  printf 'root = true\n\n[*.sh]\nindent_style = tab\n' > "$WORK/proj/.editorconfig"
  printf '#!/usr/bin/env bash\necho hi\n' > "$WORK/proj/bin/a.sh"
  _run_stubbed "$WORK/proj/bin/a.sh"
  [[ "$output" == *"[format   ] PASS      shfmt -d $WORK/proj/bin/a.sh"* ]]
}

@test "Shell (shfmt): 2-space indentation passes with no .editorconfig" {
  command -v shfmt >/dev/null 2>&1 || skip "shfmt not installed"
  _found_above "$WORK" .editorconfig && skip "an .editorconfig above the temp dir"
  printf '#!/usr/bin/env bash\ngreet() {\n  echo hi\n}\ngreet\n' > "$WORK/a.sh"
  run "$SCRIPT" "$WORK/a.sh"
  [[ "$output" == *"[format   ] PASS"* ]]
}

@test "Shell (shfmt): a tab-indent .editorconfig wins over the default flags" {
  command -v shfmt >/dev/null 2>&1 || skip "shfmt not installed"
  _found_above "$WORK" .editorconfig && skip "an .editorconfig above the temp dir"
  printf 'root = true\n\n[*.sh]\nindent_style = tab\n' > "$WORK/.editorconfig"
  printf '#!/usr/bin/env bash\ngreet() {\n\techo hi\n}\ngreet\n' > "$WORK/a.sh"
  run "$SCRIPT" "$WORK/a.sh"
  [[ "$output" == *"[format   ] PASS"* ]]
}
