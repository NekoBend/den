#!/usr/bin/env bash
# test_python.sh — Tests for python.sh / python.ps1 (uv wrappers).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

DOTFILES="/root/.dotfiles"
PYTHON_SH_GUARDED="$DOTFILES/shell/posix/python.sh"
PYTHON_PS1="$DOTFILES/shell/pwsh/python.ps1"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
NO_UV_BIN="$WORK/no-uv-bin"
mkdir -p "$NO_UV_BIN"

# --- Setup: mock uv binary ---
cat > "$WORK/uv" << 'MOCK'
#!/bin/sh
echo "mock-uv $*"
MOCK
chmod +x "$WORK/uv"

# POSIX: prepend mock PATH + source python.sh
PYTHON_SH_SOURCE="$WORK/python_source.sh"
make_noninteractive_source_copy "$PYTHON_SH_GUARDED" "$PYTHON_SH_SOURCE"

PYTHON_SH_TEST="$WORK/python_test.sh"
{
    echo "export PATH=\"$WORK:\$PATH\""
    cat "$PYTHON_SH_SOURCE"
} > "$PYTHON_SH_TEST"

# pwsh: strip uv availability guard
PYTHON_PS1_TEST="$WORK/python_test.ps1"
grep -v 'Get-Command uv.*SilentlyContinue.*return' "$PYTHON_PS1" > "$PYTHON_PS1_TEST"

# pwsh with the mock uv resolvable: _helpers.ps1 (provides _ResolveCmd) + the mock
# PATH prepended, so `uv`/`va` exercise the real code path against the mock binary.
PYTHON_PS1_COMBINED="$WORK/python_combined.ps1"
{
    echo "\$env:PATH = '$WORK' + [IO.Path]::PathSeparator + \$env:PATH"
    echo ". '$DOTFILES/shell/pwsh/_helpers.ps1'"
    cat "$PYTHON_PS1_TEST"
} > "$PYTHON_PS1_COMBINED"

# mk_venv_ps <project dir> <version_info> — venv fixture for the pwsh va tests
mk_venv_ps() {
    rm -rf "$1"
    mkdir -p "$1/.venv/bin"
    printf '%s\n' '$env:VIRTUAL_ENV = "fakevenv"' > "$1/.venv/bin/Activate.ps1"
    printf 'version_info = %s\n' "$2" > "$1/.venv/pyvenv.cfg"
}

# =============================================================================
# Bash tests
# =============================================================================

echo "[bash] _show_uv_only_message format"
actual=$(run_bash_stderr "$PYTHON_SH_TEST" "_show_uv_only_message 'pip install foo' 'uv pip install foo'")
assert_eq "bash/_show_uv_only_message" "pip install foo → uv pip install foo" "$actual"

echo "[bash] guard: non-interactive source skips python helpers"
actual=$(bash -c "
    export PATH='$WORK:\$PATH'
    source '$PYTHON_SH_GUARDED'
    type va >/dev/null 2>&1 && echo 'DEFINED' || echo 'UNDEFINED'
" | tr -d '\r')
assert_eq "bash/guard non-interactive" "UNDEFINED" "$actual"

echo "[bash] uv missing: va/vd remain defined"
actual=$(bash -c "
    export PATH='$NO_UV_BIN'
    source '$PYTHON_SH_SOURCE'
    type va >/dev/null 2>&1 && echo 'va=DEFINED' || echo 'va=UNDEFINED'
    type vd >/dev/null 2>&1 && echo 'vd=DEFINED' || echo 'vd=UNDEFINED'
    type vv >/dev/null 2>&1 && echo 'vv=DEFINED' || echo 'vv=UNDEFINED'
" | tr -d '\r')
assert_contains "bash/uv missing defines va" "va=DEFINED" "$actual"
assert_contains "bash/uv missing defines vd" "vd=DEFINED" "$actual"
assert_contains "bash/uv missing omits vv" "vv=UNDEFINED" "$actual"

echo "[bash] pip redirect message"
err=$(run_bash_stderr "$PYTHON_SH_TEST" "unset VIRTUAL_ENV; pip install foo")
assert_contains "bash/pip redirect" "→ uv pip" "$err"

echo "[bash] python redirect message"
err=$(run_bash_stderr "$PYTHON_SH_TEST" "unset VIRTUAL_ENV _DEN_VENV_PYTHON; python -c pass")
assert_contains "bash/python redirect" "→ uv run" "$err"

echo "[bash] uv run keeps the user's own uv options"
# `--` ends uv's option parsing, so it must NOT precede an option: pre-fix this
# became `uv run --python X -- --with rich script.py`, i.e. "spawn --with".
actual=$(run_bash "$PYTHON_SH_TEST" "export VIRTUAL_ENV='$WORK/fakevenv' _DEN_VENV_PYTHON=3.12; uv run --with rich script.py")
assert_eq "bash/uv run keeps --with as an option" "mock-uv run --python 3.12 --with rich script.py" "$actual"

actual=$(run_bash "$PYTHON_SH_TEST" "export VIRTUAL_ENV='$WORK/fakevenv' _DEN_VENV_PYTHON=3.12; uv run -m pytest")
assert_eq "bash/uv run keeps -m as an option" "mock-uv run --python 3.12 -m pytest" "$actual"

echo "[bash] uv run still separates a non-option command"
actual=$(run_bash "$PYTHON_SH_TEST" "export VIRTUAL_ENV='$WORK/fakevenv' _DEN_VENV_PYTHON=3.12; uv run script.py")
assert_eq "bash/uv run separates script.py" "mock-uv run --python 3.12 -- script.py" "$actual"

echo "[bash] va normalizes pyvenv.cfg version_info"
# virtualenv (tox/nox/virtualenv CLI) writes all five fields; uv rejects that form.
mk_venv() {
    rm -rf "$1"
    mkdir -p "$1/.venv/bin"
    : > "$1/.venv/bin/activate"
    printf 'version_info = %s\n' "$2" > "$1/.venv/pyvenv.cfg"
}
mk_venv "$WORK/venv_virtualenv" "3.12.3.final.0"
actual=$(run_bash "$PYTHON_SH_TEST" "cd '$WORK/venv_virtualenv' && va && echo \"PY=\$_DEN_VENV_PYTHON\"")
assert_eq "bash/va trims virtualenv 5-field version_info" "PY=3.12.3" "$actual"

mk_venv "$WORK/venv_uv" "3.13.13"
actual=$(run_bash "$PYTHON_SH_TEST" "cd '$WORK/venv_uv' && va && echo \"PY=\$_DEN_VENV_PYTHON\"")
assert_eq "bash/va keeps uv 3-field version_info" "PY=3.13.13" "$actual"

echo "[bash] va rejects a non-numeric version_info"
mk_venv "$WORK/venv_evil" "3.12; touch $WORK/pwned"
err=$(run_bash_stderr "$PYTHON_SH_TEST" "cd '$WORK/venv_evil' && va; echo \"PY=[\$_DEN_VENV_PYTHON]\" >&2")
assert_contains "bash/va rejects suspicious version_info" "rejecting suspicious version_info" "$err"
assert_contains "bash/va unsets _DEN_VENV_PYTHON on reject" "PY=[]" "$err"
assert_not_exists "bash/va does not execute version_info" "$WORK/pwned"

echo "[bash] va refuses a venv whose activate script is committed"
# The threat is a venv that arrives WITH a clone: after `git clone` the file is
# owned by the user and mode 644, so only its tracked-ness marks it as foreign.
mk_venv "$WORK/venv_tracked" "3.12.0"
(
    cd "$WORK/venv_tracked" || exit 1
    git init -q .
    git -c user.email=t@example.com -c user.name=t add -f .venv/bin/activate .venv/pyvenv.cfg
    git -c user.email=t@example.com -c user.name=t commit -q -m "committed venv"
) >/dev/null 2>&1
err=$(run_bash_stderr "$PYTHON_SH_TEST" "cd '$WORK/venv_tracked' && va" || true)
assert_contains "bash/va refuses git-tracked activate" "tracked by git" "$err"
assert_contains "bash/va names the tracked files" "tracked by git (bin/activate pyvenv.cfg)" "$err"
assert_contains "bash/va names the escape hatch" "source .venv/bin/activate" "$err"

# pyvenv.cfg alone is enough to refuse, and the message must name THAT file --
# not the activate script, which is untracked here.
mk_venv "$WORK/venv_cfg_only" "3.12.0"
(
    cd "$WORK/venv_cfg_only" || exit 1
    git init -q .
    git -c user.email=t@example.com -c user.name=t add -f .venv/pyvenv.cfg
    git -c user.email=t@example.com -c user.name=t commit -q -m "committed pyvenv.cfg"
) >/dev/null 2>&1
err=$(run_bash_stderr "$PYTHON_SH_TEST" "cd '$WORK/venv_cfg_only' && va" || true)
assert_contains "bash/va reports pyvenv.cfg alone as the tracked file" "tracked by git (pyvenv.cfg)" "$err"
assert_not_contains "bash/va does not blame the untracked activate script" "bin/activate)" "$err"

echo "[bash] va refuses a world-writable activate script"
mk_venv "$WORK/venv_ww" "3.12.0"
chmod 777 "$WORK/venv_ww/.venv/bin/activate"
err=$(run_bash_stderr "$PYTHON_SH_TEST" "cd '$WORK/venv_ww' && va" || true)
assert_contains "bash/va refuses world-writable activate" "world-writable" "$err"

echo "[bash] va accepts an untracked venv inside a git repo"
mk_venv "$WORK/venv_untracked" "3.12.0"
(
    cd "$WORK/venv_untracked" || exit 1
    git init -q .
    printf '.venv/\n' > .gitignore
    git -c user.email=t@example.com -c user.name=t add .gitignore
    git -c user.email=t@example.com -c user.name=t commit -q -m "ignore venv"
) >/dev/null 2>&1
actual=$(run_bash "$PYTHON_SH_TEST" "cd '$WORK/venv_untracked' && va && echo \"PY=\$_DEN_VENV_PYTHON\"")
assert_eq "bash/va accepts a gitignored venv" "PY=3.12.0" "$actual"

echo "[bash] va accepts a symlinked venv"
# `ln -s ~/venvs/proj .venv` is a legitimate layout, not an attack.
mk_venv "$WORK/venv_symlink_target" "3.12.0"
mkdir -p "$WORK/venv_symlink"
ln -sfn "$WORK/venv_symlink_target/.venv" "$WORK/venv_symlink/.venv"
actual=$(run_bash "$PYTHON_SH_TEST" "cd '$WORK/venv_symlink' && va && echo \"PY=\$_DEN_VENV_PYTHON\"")
assert_eq "bash/va accepts a symlinked venv" "PY=3.12.0" "$actual"

echo "[bash] vd no active venv"
err=$(run_bash_stderr "$PYTHON_SH_TEST" "unset VIRTUAL_ENV; vd" || true)
assert_contains "bash/vd no venv" "No active venv" "$err"

echo "[bash] toggle-uv OFF"
actual=$(run_bash "$PYTHON_SH_TEST" "toggle-uv" 2>/dev/null)
assert_contains "bash/toggle-uv OFF" "OFF" "$actual"

echo "[bash] toggle-uv sets env var"
actual=$(run_bash "$PYTHON_SH_TEST" "toggle-uv >/dev/null 2>&1; echo \$_DEN_UV_OVERRIDE")
assert_eq "bash/toggle-uv env" "0" "$actual"

# =============================================================================
# Zsh tests
# =============================================================================

echo "[zsh] _show_uv_only_message format"
actual=$(run_zsh_stderr "$PYTHON_SH_TEST" "_show_uv_only_message 'pip' 'uv pip'")
assert_eq "zsh/_show_uv_only_message" "pip → uv pip" "$actual"

echo "[zsh] pip redirect message"
err=$(run_zsh_stderr "$PYTHON_SH_TEST" "unset VIRTUAL_ENV; pip install foo")
assert_contains "zsh/pip redirect" "→ uv pip" "$err"

echo "[zsh] uv run keeps the user's own uv options"
actual=$(run_zsh "$PYTHON_SH_TEST" "export VIRTUAL_ENV='$WORK/fakevenv' _DEN_VENV_PYTHON=3.12; uv run --with rich script.py")
assert_eq "zsh/uv run keeps --with as an option" "mock-uv run --python 3.12 --with rich script.py" "$actual"

echo "[zsh] va normalizes pyvenv.cfg version_info"
mk_venv "$WORK/venv_zsh" "3.11.4.final.0"
actual=$(run_zsh "$PYTHON_SH_TEST" "cd '$WORK/venv_zsh' && va && echo \"PY=\$_DEN_VENV_PYTHON\"")
assert_eq "zsh/va trims virtualenv 5-field version_info" "PY=3.11.4" "$actual"

echo "[zsh] vd no active venv"
err=$(run_zsh_stderr "$PYTHON_SH_TEST" "unset VIRTUAL_ENV; vd" || true)
assert_contains "zsh/vd no venv" "No active venv" "$err"

echo "[zsh] toggle-uv OFF"
actual=$(run_zsh "$PYTHON_SH_TEST" "toggle-uv" 2>/dev/null)
assert_contains "zsh/toggle-uv OFF" "OFF" "$actual"

# =============================================================================
# PowerShell tests
# =============================================================================

echo "[pwsh] Show-UvOnlyMessage format"
actual=$(run_pwsh "$PYTHON_PS1_TEST" "Show-UvOnlyMessage 'pip install' 'uv pip install' 6>&1" | tr -d '\r')
assert_contains "pwsh/Show-UvOnlyMessage" "→ uv pip install" "$actual"

echo "[pwsh] vd no VIRTUAL_ENV"
err=$(run_pwsh_stderr "$PYTHON_PS1_TEST" "\$env:VIRTUAL_ENV = \$null; vd" || true)
assert_contains "pwsh/vd no venv" "No active venv" "$err"

echo "[pwsh] toggle-uv OFF sets env"
actual=$(run_pwsh "$PYTHON_PS1_TEST" "toggle-uv *>\$null; \$env:_DEN_UV_OVERRIDE" | tr -d '\r')
assert_eq "pwsh/toggle-uv OFF env" "0" "$actual"

echo "[pwsh] toggle-uv removes functions"
actual=$(run_pwsh "$PYTHON_PS1_TEST" "toggle-uv *>\$null; if (Get-Command pip -ErrorAction SilentlyContinue) { 'exists' } else { 'removed' }" | tr -d '\r')
assert_eq "pwsh/toggle-uv removes pip" "removed" "$actual"

echo "[pwsh] va activates a Linux/macOS venv (bin/Activate.ps1)"
mkdir -p "$WORK/venvtest/.venv/bin"
printf '%s\n' '$env:VIRTUAL_ENV = "fakevenv"' > "$WORK/venvtest/.venv/bin/Activate.ps1"
actual=$(run_pwsh "$PYTHON_PS1_TEST" "Set-Location '$WORK/venvtest'; va *>\$null; \$env:VIRTUAL_ENV" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/va finds bin/Activate.ps1" "fakevenv" "$actual"

echo "[pwsh] va treats \$Name literally (no wildcard glob-expansion)"
# A real 'foobar/bin/Activate.ps1' must NOT be reached by 'va foo*': -LiteralPath
# rejects the literal 'foo*' dir instead of globbing to foobar and sourcing it.
mkdir -p "$WORK/wildtest/foobar/bin"
printf '%s\n' '$env:VIRTUAL_ENV = "leaked"' > "$WORK/wildtest/foobar/bin/Activate.ps1"
err=$(run_pwsh_stderr "$PYTHON_PS1_TEST" "Set-Location '$WORK/wildtest'; \$env:VIRTUAL_ENV = \$null; va 'foo*'")
assert_contains "pwsh/va rejects wildcard name" "activate script not found" "$err"

echo "[pwsh] uv run keeps the user's own uv options"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
    \$env:VIRTUAL_ENV = '$WORK/fakevenv'; \$env:_DEN_VENV_PYTHON = '3.12'
    uv run --with rich script.py
" | tr -d '\r')
assert_eq "pwsh/uv run keeps --with as an option" "mock-uv run --python 3.12 --with rich script.py" "$actual"

echo "[pwsh] uv run still separates a non-option command"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
    \$env:VIRTUAL_ENV = '$WORK/fakevenv'; \$env:_DEN_VENV_PYTHON = '3.12'
    uv run script.py
" | tr -d '\r')
assert_eq "pwsh/uv run separates script.py" "mock-uv run --python 3.12 -- script.py" "$actual"

echo "[pwsh] va normalizes pyvenv.cfg version_info"
mk_venv_ps "$WORK/ps_venv5" "3.11.4.final.0"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "Set-Location '$WORK/ps_venv5'; va *>\$null; \$env:_DEN_VENV_PYTHON" | tr -d '\r')
assert_eq "pwsh/va trims virtualenv 5-field version_info" "3.11.4" "$actual"

echo "[pwsh] va refuses a venv whose activate script is committed"
mk_venv_ps "$WORK/ps_venv_tracked" "3.12.0"
(
    cd "$WORK/ps_venv_tracked" || exit 1
    git init -q .
    git -c user.email=t@example.com -c user.name=t add -f .venv/bin/Activate.ps1 .venv/pyvenv.cfg
    git -c user.email=t@example.com -c user.name=t commit -q -m "committed venv"
) >/dev/null 2>&1
err=$(run_pwsh_stderr "$PYTHON_PS1_COMBINED" "Set-Location '$WORK/ps_venv_tracked'; va")
assert_contains "pwsh/va refuses git-tracked activate" "tracked by git" "$err"
assert_contains "pwsh/va names the tracked files" "pyvenv.cfg" "$err"

mk_venv_ps "$WORK/ps_venv_cfg_only" "3.12.0"
(
    cd "$WORK/ps_venv_cfg_only" || exit 1
    git init -q .
    git -c user.email=t@example.com -c user.name=t add -f .venv/pyvenv.cfg
    git -c user.email=t@example.com -c user.name=t commit -q -m "committed pyvenv.cfg"
) >/dev/null 2>&1
err=$(run_pwsh_stderr "$PYTHON_PS1_COMBINED" "Set-Location '$WORK/ps_venv_cfg_only'; \$env:VIRTUAL_ENV = \$null; va")
assert_contains "pwsh/va refuses on pyvenv.cfg alone" "tracked by git" "$err"
assert_contains "pwsh/va reports pyvenv.cfg as the tracked file" "pyvenv.cfg" "$err"
assert_not_contains "pwsh/va does not blame the untracked activate script" "Activate.ps1)" "$err"

echo "[pwsh] va accepts an untracked venv inside a git repo"
mk_venv_ps "$WORK/ps_venv_untracked" "3.12.0"
(
    cd "$WORK/ps_venv_untracked" || exit 1
    git init -q .
    printf '.venv/\n' > .gitignore
    git -c user.email=t@example.com -c user.name=t add .gitignore
    git -c user.email=t@example.com -c user.name=t commit -q -m "ignore venv"
) >/dev/null 2>&1
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "Set-Location '$WORK/ps_venv_untracked'; va *>\$null; \$env:_DEN_VENV_PYTHON" | tr -d '\r')
assert_eq "pwsh/va accepts a gitignored venv" "3.12.0" "$actual"

echo "[pwsh] va refuses a world-writable activate script"
# pwsh 7 on Linux/macOS exposes UnixMode, which is what the refusal reads;
# Windows has no world-writable bit and skips the check.
mk_venv_ps "$WORK/ps_venv_ww" "3.12.0"
chmod 666 "$WORK/ps_venv_ww/.venv/bin/Activate.ps1"
err=$(run_pwsh_stderr "$PYTHON_PS1_COMBINED" "Set-Location '$WORK/ps_venv_ww'; \$env:VIRTUAL_ENV = \$null; va")
assert_contains "pwsh/va refuses world-writable activate" "world-writable" "$err"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
    Set-Location '$WORK/ps_venv_ww'
    \$env:VIRTUAL_ENV = \$null
    va *>\$null
    \"VE=[\$env:VIRTUAL_ENV] PY=[\$env:_DEN_VENV_PYTHON]\"
" | tr -d '\r')
assert_eq "pwsh/va activates nothing when refusing" "VE=[] PY=[]" "$actual"

echo "[pwsh] va accepts a 0644 activate script"
mk_venv_ps "$WORK/ps_venv_644" "3.12.0"
chmod 644 "$WORK/ps_venv_644/.venv/bin/Activate.ps1"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
    Set-Location '$WORK/ps_venv_644'
    \$env:VIRTUAL_ENV = \$null
    va *>\$null
    \"VE=[\$env:VIRTUAL_ENV] PY=[\$env:_DEN_VENV_PYTHON]\"
" | tr -d '\r')
assert_eq "pwsh/va accepts a 0644 activate script" "VE=[fakevenv] PY=[3.12.0]" "$actual"

# =============================================================================
# Summary
# =============================================================================
print_summary "test_python"
[ "$FAIL" -eq 0 ]
