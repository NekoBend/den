#!/usr/bin/env bats
#
# Tests for run-checks.sh. The script dispatches format/lint/typecheck by
# file extension, SKIPs any tool that is not on PATH, and reports a summary.
# These tests assert the usage/exit-code contract and the SKIP behaviour,
# which hold regardless of which language toolchains are installed.

setup() {
  SCRIPT="${BATS_TEST_DIRNAME}/../run-checks.sh"
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
