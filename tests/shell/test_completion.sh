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

# completion.ps1 uses the shared Initialize-Cache (in _helpers.ps1) and registers
# the per-tool completers. Sourcing both must not error: the trailing sentinel
# prints only if completion.ps1 sourced without a terminating error. run_pwsh is
# -NonInteractive, which the _DenInteractive gate treats as non-interactive, so set
# _DEN_FORCE_INTERACTIVE=1 to exercise the body; the per-tool completers no-op
# because their tools are absent. Stderr is NOT suppressed, so a load failure shows.
echo "[pwsh] completion.ps1 sources cleanly"
actual=$(run_pwsh "$HELPERS_PS1" "\$env:_DEN_FORCE_INTERACTIVE='1'; . '$COMPLETION_PS1'; 'SOURCED-OK'" | tr -d '\r')
assert_eq "pwsh/completion sources cleanly" "SOURCED-OK" "$actual"

print_summary "test_completion"
[ "$FAIL" -eq 0 ]
