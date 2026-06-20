#!/usr/bin/env bash
# test_completion.sh — Tests for completion.ps1 (pwsh Tab completion). pwsh-only;
# the actual interactive completion needs a real terminal, so this is a load
# smoke test (sources cleanly + defines the helper) -- the rest is PSScriptAnalyzer
# (CI) plus manual verification on Windows.
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

HELPERS_PS1="$DOTFILES/shell/pwsh/_helpers.ps1"
COMPLETION_PS1="$DOTFILES/shell/pwsh/completion.ps1"

echo "================================================"
echo "  Testing completion.ps1 with PWSH"
echo "================================================"

if ! command -v pwsh >/dev/null 2>&1; then
    echo "pwsh not found; skipping completion tests"
    print_summary "test_completion"
    [ "$FAIL" -eq 0 ]
    return 0 2>/dev/null || exit 0
fi

# completion.ps1 depends on _helpers.ps1 (Test-CacheSafe). Sourcing both must not
# error and must define Initialize-Completion. Per-tool completers are guarded by
# Get-Command (absent tools skipped), and the Tab handler is guarded by PSReadLine
# being loaded (it is not, non-interactively), so both are no-ops here.
echo "[pwsh] completion.ps1 sources cleanly and defines Initialize-Completion"
actual=$(run_pwsh "$HELPERS_PS1" ". '$COMPLETION_PS1'; if (Get-Command Initialize-Completion -ErrorAction SilentlyContinue) { 'DEFINED' } else { 'MISSING' }" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/completion defines Initialize-Completion" "DEFINED" "$actual"

print_summary "test_completion"
[ "$FAIL" -eq 0 ]
