#!/usr/bin/env bats
#
# Tests for run-checks.sh. The script dispatches format/lint/typecheck by
# file extension, SKIPs any tool that is not on PATH, and reports a summary.
# These tests assert the usage/exit-code contract and the SKIP behaviour,
# which hold regardless of which language toolchains are installed.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../../agents/src/shared/scripts/run-checks.sh"
  WORK="$(mktemp -d)"
}

teardown() {
  rm -rf "$WORK"
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
