#!/usr/bin/env bash
# test_python.sh — Tests for python.sh / python.ps1 (uv wrappers).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

# helpers.sh already honours a DOTFILES override so the suite can run against a
# checkout; hardcoding it here silently discarded that and tested the INSTALLED
# copy instead, whatever DOTFILES said.
DOTFILES="${DOTFILES:-/root/.dotfiles}"
PYTHON_SH_GUARDED="$DOTFILES/shell/posix/python.sh"
PYTHON_PS1="$DOTFILES/shell/pwsh/python.ps1"

NO_UV_BIN="$WORK/no-uv-bin"
mkdir -p "$NO_UV_BIN"

# python, python3 and py go through uv run only outside a project: with a
# pyproject.toml or a .venv in the current directory or one above it they run a
# python directly. The suite itself may run from a checkout, which has a
# pyproject.toml, so a test that wants uv run starts in this directory.
NOPROJ="$WORK/noproj"
mkdir -p "$NOPROJ"

# --- Setup: mock uv binary ---
cat > "$WORK/uv" << 'MOCK'
#!/bin/sh
echo "mock-uv $*"
MOCK
chmod +x "$WORK/uv"

# POSIX: prepend mock PATH + source python.sh
PYTHON_SH_SOURCE="$TESTTMP/python_source.sh"
make_noninteractive_source_copy "$PYTHON_SH_GUARDED" "$PYTHON_SH_SOURCE"

PYTHON_SH_TEST="$TESTTMP/python_test.sh"
{
    echo "export PATH=\"$WORK:\$PATH\""
    cat "$PYTHON_SH_SOURCE"
} > "$PYTHON_SH_TEST"

# pwsh: strip uv availability guard
PYTHON_PS1_TEST="$TESTTMP/python_test.ps1"
grep -v 'Get-Command uv.*SilentlyContinue.*return' "$PYTHON_PS1" > "$PYTHON_PS1_TEST"

# pwsh with the mock uv resolvable: _helpers.ps1 (provides _ResolveCmd) + the mock
# PATH prepended, so `uv`/`va` exercise the real code path against the mock binary.
PYTHON_PS1_COMBINED="$TESTTMP/python_combined.ps1"
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

# toggle-uv ON re-reads python.ps1 from its own directory, which for the combined
# file is $TESTTMP: put a copy of the file under test there. PS_SET_PROFILE points
# $PROFILE at a directory whose python.ps1 is a decoy (a pip that says so), so ON
# cannot pass by reading the copy next to $PROFILE. The mock system pip keeps a
# missing redirect from reaching a real `pip install`.
cp "$PYTHON_PS1" "$TESTTMP/python.ps1"
PS_PROFILE_DIR="$WORK/ps_profile"
mkdir -p "$PS_PROFILE_DIR"
printf '%s\n' "function pip { 'decoy-pip' }" > "$PS_PROFILE_DIR/python.ps1"
PS_SET_PROFILE="\$PROFILE = '$PS_PROFILE_DIR/Microsoft.PowerShell_profile.ps1'"
# The same combined file with no python.ps1 beside it, and a $PROFILE directory
# with none either, for an ON that loads nothing.
mkdir -p "$WORK/no-python-ps1" "$WORK/empty-profile"
cp "$PYTHON_PS1_COMBINED" "$WORK/no-python-ps1/python_combined.ps1"
PS_SET_EMPTY_PROFILE="\$PROFILE = '$WORK/empty-profile/Microsoft.PowerShell_profile.ps1'"
MOCK_PIP_BIN="$WORK/mock-pip-bin"
mkdir -p "$MOCK_PIP_BIN"
printf '#!/bin/sh\necho "system-pip $*"\n' > "$MOCK_PIP_BIN/pip"
printf '#!/bin/sh\necho "system-pip3 $*"\n' > "$MOCK_PIP_BIN/pip3"
chmod +x "$MOCK_PIP_BIN/pip" "$MOCK_PIP_BIN/pip3"

# Two active-venv fixtures for pip/pip3: one made by uv, which has no pip of its
# own, and one with its own pip and pip3 (python -m venv).
mkdir -p "$WORK/venv_nopip/bin" "$WORK/venv_ownpip/bin"
printf '#!/bin/sh\necho "venv-pip $*"\n' > "$WORK/venv_ownpip/bin/pip"
printf '#!/bin/sh\necho "venv-pip3 $*"\n' > "$WORK/venv_ownpip/bin/pip3"
chmod +x "$WORK/venv_ownpip/bin/pip" "$WORK/venv_ownpip/bin/pip3"

# A repo that commits .venv/bin as a symlink to its own tools/, which holds the
# activate scripts. git reports the link as "bin" and nothing beneath it, so a
# check that asks about bin/activate alone saw no tracked file. Each script
# leaves a marker when it runs; nothing is tracked but the link and tools/.
SYMBIN="$WORK/venv_symbin"
mkdir -p "$SYMBIN/.venv" "$SYMBIN/tools"
printf 'echo sourced > "%s"\n' "$WORK/symbin_ran" > "$SYMBIN/tools/activate"
printf '"sourced" | Set-Content -LiteralPath "%s"\n' "$WORK/symbin_ran" > "$SYMBIN/tools/Activate.ps1"
ln -s ../tools "$SYMBIN/.venv/bin"
(
    cd "$SYMBIN" || exit 1
    git init -q .
    git -c user.email=t@example.com -c user.name=t add -A
    git -c user.email=t@example.com -c user.name=t commit -q -m "committed bin symlink"
) >/dev/null 2>&1

# A real bin/ whose activate scripts are symlinks to scripts elsewhere, outside any
# repo, so git has nothing to report. A symlink's own mode reads as world-writable
# on Linux (not on macOS), so the message is what shows the symlink test refused.
SYMACT="$WORK/venv_symact"
mkdir -p "$SYMACT/.venv/bin" "$SYMACT/tools"
printf 'echo sourced > "%s"\n' "$WORK/symact_ran" > "$SYMACT/tools/activate"
printf '"sourced" | Set-Content -LiteralPath "%s"\n' "$WORK/symact_ran" > "$SYMACT/tools/Activate.ps1"
ln -s ../../tools/activate "$SYMACT/.venv/bin/activate"
ln -s ../../tools/Activate.ps1 "$SYMACT/.venv/bin/Activate.ps1"

# A repo that commits its .venv as a repository of its own: HEAD, objects/, refs/
# and a config whose core.worktree is the venv itself. git asked from inside the
# venv took that repository, whose index is empty, so nothing looked tracked, and
# ran its core.fsmonitor command. Each script and that command leave a marker.
EMBED="$WORK/venv_embedded_repo"
mkdir -p "$EMBED/.venv/bin" "$EMBED/.venv/objects" "$EMBED/.venv/refs"
printf 'ref: refs/heads/main\n' > "$EMBED/.venv/HEAD"
: > "$EMBED/.venv/objects/.keep"
: > "$EMBED/.venv/refs/.keep"
printf '[core]\n\trepositoryformatversion = 0\n\tbare = false\n\tworktree = .\n\tfsmonitor = "echo ran > %s; false"\n' \
    "$WORK/embed_fsmonitor_ran" > "$EMBED/.venv/config"
printf 'echo sourced > "%s"\n' "$WORK/embed_ran" > "$EMBED/.venv/bin/activate"
printf '"sourced" | Set-Content -LiteralPath "%s"\n' "$WORK/embed_ran" > "$EMBED/.venv/bin/Activate.ps1"
printf 'version_info = 3.12.0\n' > "$EMBED/.venv/pyvenv.cfg"
(
    cd "$EMBED" || exit 1
    git init -q .
    git -c user.email=t@example.com -c user.name=t add -f .venv
    git -c user.email=t@example.com -c user.name=t commit -q -m "committed venv repository"
) >/dev/null 2>&1
# git before 2.38 has no safe.bareRepository and still reads that repository.
if git -c safe.bareRepository=explicit -C "$EMBED/.venv" rev-parse --git-dir >/dev/null 2>&1; then
    GIT_HAS_SAFE_BARE=0
else
    GIT_HAS_SAFE_BARE=1
fi

# A committed venv in a checkout whose path holds the words git uses for "no
# repository here": the refusal git prints for another reason quotes that path.
NAGR="$WORK/not a git repository"

# git reads a repo owned by another user only when safe.directory allows it;
# this makes it take every repo as one, whatever the tester's own config says.
GIT_AS_OTHER_OWNER="GIT_TEST_ASSUME_DIFFERENT_OWNER=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1"

# The tools va itself runs, without git.
NO_GIT_BIN="$WORK/no-git-bin"
mkdir -p "$NO_GIT_BIN"
for t in sed cut ls head tr; do ln -s "$(command -v "$t")" "$NO_GIT_BIN/$t"; done

# toggle-uv ON re-reads ~/.config/shell/python.sh: a HOME with the file under test
# there (the copy with the mock uv on PATH).
UV_HOME="$WORK/uv_home"
mkdir -p "$UV_HOME/.config/shell"
cp "$PYTHON_SH_TEST" "$UV_HOME/.config/shell/python.sh"

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

echo "[bash] pip redirect message (in a venv without a pip of its own)"
err=$(run_bash_stderr "$PYTHON_SH_TEST" "export VIRTUAL_ENV='$WORK/venv_nopip'; pip install foo")
assert_contains "bash/pip redirect" "→ uv pip" "$err"

echo "[bash] python redirect message"
err=$(run_bash_stderr "$PYTHON_SH_TEST" "cd '$NOPROJ' && unset VIRTUAL_ENV _DEN_VENV_PYTHON; python -c pass")
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

echo "[bash] va refuses a committed activate script whose case differs"
# On a case-insensitive file system (default APFS) the test for bin/activate also
# finds a committed bin/ACTIVATE, the same file there. Here they are two files,
# which is enough to show that git reports the committed one.
mk_venv "$WORK/venv_tracked_case" "3.12.0"
: > "$WORK/venv_tracked_case/.venv/bin/ACTIVATE"
(
    cd "$WORK/venv_tracked_case" || exit 1
    git init -q .
    git -c user.email=t@example.com -c user.name=t add -f .venv/bin/ACTIVATE
    git -c user.email=t@example.com -c user.name=t commit -q -m "committed ACTIVATE"
) >/dev/null 2>&1
err=$(run_bash_stderr "$PYTHON_SH_TEST" "cd '$WORK/venv_tracked_case' && va" || true)
assert_contains "bash/va refuses a tracked bin/ACTIVATE" "tracked by git (bin/ACTIVATE)" "$err"

echo "[bash] va still refuses a committed venv with GIT_LITERAL_PATHSPECS=1"
# That setting turns :(icase) into a plain file name: the exact names must match.
err=$(run_bash_stderr "$PYTHON_SH_TEST" "cd '$WORK/venv_tracked' && GIT_LITERAL_PATHSPECS=1 && export GIT_LITERAL_PATHSPECS && va" || true)
assert_contains "bash/va refuses under literal pathspecs" "tracked by git (bin/activate pyvenv.cfg)" "$err"

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

echo "[bash] va refuses a committed bin/ whose case differs"
# On a case-insensitive file system the test for bin/activate also finds a
# committed BIN/activate. Here BIN/ is a second directory, which is enough to show
# that git reports it.
mk_venv "$WORK/venv_tracked_dircase" "3.12.0"
mkdir -p "$WORK/venv_tracked_dircase/.venv/BIN"
: > "$WORK/venv_tracked_dircase/.venv/BIN/activate"
(
    cd "$WORK/venv_tracked_dircase" || exit 1
    git init -q .
    git -c user.email=t@example.com -c user.name=t add -f .venv/BIN/activate
    git -c user.email=t@example.com -c user.name=t commit -q -m "committed BIN/activate"
) >/dev/null 2>&1
err=$(run_bash_stderr "$PYTHON_SH_TEST" "cd '$WORK/venv_tracked_dircase' && va" || true)
assert_contains "bash/va refuses a tracked BIN/activate" "tracked by git (BIN/activate)" "$err"

mk_venv "$NAGR/r" "3.12.0"
(
    cd "$NAGR/r" || exit 1
    git init -q .
    git -c user.email=t@example.com -c user.name=t add -f .venv/bin/activate .venv/pyvenv.cfg
    git -c user.email=t@example.com -c user.name=t commit -q -m "committed venv"
) >/dev/null 2>&1

for sh in bash zsh; do
    echo "[$sh] va refuses a committed symlinked bin/ and runs nothing behind it"
    rm -f "$WORK/symbin_ran"
    err=$("$sh" -c "source '$PYTHON_SH_TEST'; cd '$SYMBIN' && va; echo \"rc=\$?\"" 2>&1 | tr -d '\r')
    assert_contains "$sh/va refuses a symlinked bin/" "bin/ or bin/activate is a symlink" "$err"
    assert_contains "$sh/va symlinked bin/ fails" "rc=1" "$err"
    assert_not_exists "$sh/va sources no script behind a symlinked bin/" "$WORK/symbin_ran"

    echo "[$sh] va refuses a symlinked activate script in a real bin/"
    rm -f "$WORK/symact_ran"
    err=$("$sh" -c "source '$PYTHON_SH_TEST'; cd '$SYMACT' && va; echo \"rc=\$?\"" 2>&1 | tr -d '\r')
    assert_contains "$sh/va refuses a symlinked activate" "bin/ or bin/activate is a symlink" "$err"
    assert_contains "$sh/va symlinked activate fails" "rc=1" "$err"
    assert_not_exists "$sh/va sources no script behind a symlinked activate" "$WORK/symact_ran"

    if [ "$GIT_HAS_SAFE_BARE" -eq 1 ]; then
        echo "[$sh] va refuses a venv committed as a repository of its own"
        rm -f "$WORK/embed_ran" "$WORK/embed_fsmonitor_ran"
        actual=$("$sh" -c "source '$PYTHON_SH_TEST'; cd '$EMBED' && va; echo \"rc=\$? PY=[\$_DEN_VENV_PYTHON]\"" 2>&1 | tr -d '\r')
        assert_contains "$sh/va names git's refusal of the venv repository" "git could not tell whether the venv is committed (fatal: cannot use bare repository" "$actual"
        assert_contains "$sh/va activates nothing from a venv repository" "rc=1 PY=[]" "$actual"
        assert_not_exists "$sh/va sources no script from a venv repository" "$WORK/embed_ran"
        assert_not_exists "$sh/va runs no fsmonitor of a venv repository" "$WORK/embed_fsmonitor_ran"
    else
        echo "  SKIP: $sh/va venv repository (git before 2.38 has no safe.bareRepository)"
    fi

    echo "[$sh] va takes only git's own fatal line as 'not a git repository'"
    # The dubious-ownership refusal quotes the checkout path, which here holds
    # those words; git's trace lines come before its fatal line.
    actual=$("$sh" -c "source '$PYTHON_SH_TEST'; cd '$NAGR/r' && export $GIT_AS_OTHER_OWNER && va; echo \"rc=\$? PY=[\$_DEN_VENV_PYTHON]\"" 2>&1 | tr -d '\r')
    assert_contains "$sh/va refuses when only the quoted path says not a git repository" "rc=1 PY=[]" "$actual"
    actual=$("$sh" -c "source '$PYTHON_SH_TEST'; cd '$WORK/venv_uv' && GIT_TRACE2=1 && export GIT_TRACE2 && va; echo \"rc=\$? PY=[\$_DEN_VENV_PYTHON]\"" 2>/dev/null | tr -d '\r')
    assert_eq "$sh/va outside a repo with git trace lines first" "rc=0 PY=[3.13.13]" "$actual"

    echo "[$sh] va refuses when git cannot read the repo (dubious ownership)"
    # git exits 128 with no output there; taking that as "not a repo" sourced the
    # committed activate script.
    actual=$("$sh" -c "source '$PYTHON_SH_TEST'; cd '$WORK/venv_tracked' && export $GIT_AS_OTHER_OWNER && va; echo \"rc=\$? PY=[\$_DEN_VENV_PYTHON]\"" 2>&1 | tr -d '\r')
    assert_contains "$sh/va names the git failure" "git could not tell whether the venv is committed (fatal: detected dubious ownership" "$actual"
    assert_contains "$sh/va activates nothing when git fails" "rc=1 PY=[]" "$actual"

    echo "[$sh] va still activates a venv outside any repo, and with no git at all"
    actual=$("$sh" -c "source '$PYTHON_SH_TEST'; cd '$WORK/venv_uv' && va; echo \"rc=\$? PY=[\$_DEN_VENV_PYTHON]\"" 2>&1 | tr -d '\r')
    assert_eq "$sh/va outside a repo" "rc=0 PY=[3.13.13]" "$actual"
    actual=$("$sh" -c "source '$PYTHON_SH_TEST'; cd '$WORK/venv_uv' && PATH='$NO_GIT_BIN' && va; echo \"rc=\$? PY=[\$_DEN_VENV_PYTHON]\"" 2>&1 | tr -d '\r')
    assert_eq "$sh/va with no git" "rc=0 PY=[3.13.13]" "$actual"
done

echo "[bash] vd no active venv"
err=$(run_bash_stderr "$PYTHON_SH_TEST" "unset VIRTUAL_ENV; vd" || true)
assert_contains "bash/vd no venv" "No active venv" "$err"

echo "[bash] toggle-uv OFF"
actual=$(run_bash "$PYTHON_SH_TEST" "toggle-uv" 2>/dev/null)
assert_contains "bash/toggle-uv OFF" "OFF" "$actual"

echo "[bash] toggle-uv sets env var"
actual=$(run_bash "$PYTHON_SH_TEST" "toggle-uv >/dev/null 2>&1; echo \$_DEN_UV_OVERRIDE")
assert_eq "bash/toggle-uv env" "0" "$actual"

# tgl-uv is the short name: a function (not an interactive-only alias) that
# does exactly what toggle-uv does, down to dropping the pip override.
echo "[bash] tgl-uv flips like toggle-uv"
actual=$(run_bash "$PYTHON_SH_TEST" "
    echo \"TYPE=\$(type -t tgl-uv)\"
    tgl-uv
    case \$(type pip 2>/dev/null) in *function*) pip=kept ;; *) pip=gone ;; esac
    echo \"ENV=\$_DEN_UV_OVERRIDE PIP=\$pip\"
" 2>/dev/null) || true
assert_eq "bash/tgl-uv OFF" "TYPE=function
uv override: OFF (using system python/pip)
ENV=0 PIP=gone" "$actual"

for sh in bash zsh; do
    echo "[$sh] pip/pip3 in a venv use its own pip, else uv pip, never another pip on PATH"
    # A uv venv has no pip: the PATH lookup found the system pip ahead of it.
    actual=$("$sh" -c "source '$PYTHON_SH_TEST'; export PATH='$MOCK_PIP_BIN':\$PATH VIRTUAL_ENV='$WORK/venv_nopip'; pip install requests; pip3 install rich" 2>/dev/null | tr -d '\r')
    assert_eq "$sh/pip in a venv without pip goes to uv pip" "mock-uv pip install requests
mock-uv pip install rich" "$actual"
    err=$("$sh" -c "source '$PYTHON_SH_TEST'; export PATH='$MOCK_PIP_BIN':\$PATH VIRTUAL_ENV='$WORK/venv_nopip'; pip install requests" 2>&1 >/dev/null | tr -d '\r')
    assert_eq "$sh/pip in a venv without pip says so" "pip install requests → uv pip install requests" "$err"
    actual=$("$sh" -c "source '$PYTHON_SH_TEST'; export PATH='$MOCK_PIP_BIN':\$PATH VIRTUAL_ENV='$WORK/venv_ownpip'; pip install requests; pip3 install rich" 2>&1 | tr -d '\r')
    assert_eq "$sh/pip in a venv with its own pip runs it" "venv-pip install requests
venv-pip3 install rich" "$actual"

    echo "[$sh] _DEN_UV_OVERRIDE=0 at load: no overrides, and one toggle-uv turns them on"
    # toggle-uv exports it, so a reload or a child shell starts with it; loading
    # the overrides anyway left them ON under an OFF, and the next toggle did nothing.
    actual=$(HOME="$UV_HOME" _DEN_UV_OVERRIDE=0 "$sh" -c "
        source '$PYTHON_SH_TEST'
        left=''
        for f in uv python python3 py pip pip3 _show_uv_only_message _den_py _den_py_marker _den_py_exe; do
            case \$(type \$f 2>/dev/null) in *function*) left=\"\$left \$f\" ;; esac
        done
        kept=''
        for f in va vd vv vva toggle-uv tgl-uv; do
            case \$(type \$f 2>/dev/null) in *function*) kept=\"\$kept \$f\" ;; esac
        done
        echo \"LOAD: LEFT=[\$left] KEPT=[\$kept]\"
        toggle-uv
        echo \"ENV=\$_DEN_UV_OVERRIDE\"
        export VIRTUAL_ENV='$WORK/venv_nopip'
        pip install rich
    " 2>/dev/null | tr -d '\r')
    assert_eq "$sh/_DEN_UV_OVERRIDE=0 at load" "LOAD: LEFT=[] KEPT=[ va vd vv vva toggle-uv tgl-uv]
uv override: ON (python/pip → uv)
ENV=1
mock-uv pip install rich" "$actual"
done

# =============================================================================
# Zsh tests
# =============================================================================

echo "[zsh] _show_uv_only_message format"
actual=$(run_zsh_stderr "$PYTHON_SH_TEST" "_show_uv_only_message 'pip' 'uv pip'")
assert_eq "zsh/_show_uv_only_message" "pip → uv pip" "$actual"

echo "[zsh] pip redirect message (in a venv without a pip of its own)"
err=$(run_zsh_stderr "$PYTHON_SH_TEST" "export VIRTUAL_ENV='$WORK/venv_nopip'; pip install foo")
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

echo "[zsh] tgl-uv flips like toggle-uv"
actual=$(run_zsh "$PYTHON_SH_TEST" "
    whence -w tgl-uv
    tgl-uv
    case \$(type pip 2>/dev/null) in *function*) pip=kept ;; *) pip=gone ;; esac
    echo \"ENV=\$_DEN_UV_OVERRIDE PIP=\$pip\"
" 2>/dev/null) || true
assert_eq "zsh/tgl-uv OFF" "tgl-uv: function
uv override: OFF (using system python/pip)
ENV=0 PIP=gone" "$actual"

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

echo "[pwsh] tgl-uv flips like toggle-uv"
actual=$(run_pwsh "$PYTHON_PS1_TEST" "
    Write-Output \"TYPE=\$((Get-Command tgl-uv -ErrorAction SilentlyContinue).CommandType)\"
    \$msg = @(tgl-uv 6>&1) -join ''
    \$pip = if (Get-Command pip -CommandType Function -ErrorAction SilentlyContinue) { 'kept' } else { 'gone' }
    Write-Output \"\$msg|ENV=\$env:_DEN_UV_OVERRIDE|PIP=\$pip\"
" 2>/dev/null | tr -d '\r') || true
assert_eq "pwsh/tgl-uv OFF" "TYPE=Function
uv override: OFF (using system python/pip)|ENV=0|PIP=gone" "$actual"

# ON dot-sources python.ps1 inside toggle-uv; the overrides must still exist once
# it returns, not only in its own scope.
echo "[pwsh] toggle-uv OFF then ON restores the override functions"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
    $PS_SET_PROFILE
    toggle-uv *>\$null
    toggle-uv *>\$null
    \$missing = 'uv', 'python', 'python3', 'pip', 'pip3', 'py', 'Show-UvOnlyMessage', '_DenPyMarker', '_DenPyExe', '_DenPyRun' |
        Where-Object { -not (Get-Command \$_ -CommandType Function -ErrorAction SilentlyContinue) }
    \"ENV=[\$env:_DEN_UV_OVERRIDE] MISSING=[\$(\$missing -join ',')]\"
" | tr -d '\r')
assert_eq "pwsh/toggle-uv ON restores every override" "ENV=[1] MISSING=[]" "$actual"

echo "[pwsh] toggle-uv OFF then ON redirects pip to uv pip again"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
    $PS_SET_PROFILE
    \$env:PATH = '$MOCK_PIP_BIN' + [IO.Path]::PathSeparator + \$env:PATH
    \$env:VIRTUAL_ENV = '$WORK/venv_nopip'
    toggle-uv *>\$null
    toggle-uv *>\$null
    pip install rich 6>\$null
" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/toggle-uv ON pip goes to uv pip" "mock-uv pip install rich" "$actual"

# den install rewrites python.ps1 in place, so the helpers python, python3 and
# py call can be older in a session than in the file, or missing from it. ON
# copies them from the file it reads, with python.
echo "[pwsh] toggle-uv OFF then ON after an update in place: python, python3 and py run"
for helpers in older missing; do
    case $helpers in
        older) setup="Set-Item \"Function:global:\$n\" { throw 'a helper from before the update ran' }" ;;
        *) setup="Remove-Item \"Function:\$n\"" ;;
    esac
    actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
        $PS_SET_PROFILE
        Set-Location -LiteralPath '$NOPROJ'
        foreach (\$n in '_DenPyMarker', '_DenPyExe', '_DenPyRun') { $setup }
        toggle-uv *>\$null
        toggle-uv *>\$null
        python -c 1 6>\$null
        python3 -c 2 6>\$null
        py -c 3 6>\$null
    " 2>&1 | tr -d '\r') || true
    assert_eq "pwsh/toggle-uv ON after an update, helpers $helpers" "mock-uv run -- python -c 1
mock-uv run -- python -c 2
mock-uv run -- python -c 3" "$actual"
done

# A session that loaded the python.ps1 from before the helpers existed (main at
# 8e5eeba) keeps that file's toggle-uv, whose list names none of them. Its ON
# dot-sources the updated file inside itself and copies only the names on its
# list to global scope, so a helper defined there ended with the call, and
# python could not find _DenPyRun. Such a session also still runs 8e5eeba's
# _helpers.ps1, which the update does not load again, so the updated python.ps1
# can call only the functions that file defines. Both old files come from git:
# the test image has no .git, so there this is skipped.
OLD_PY_PS1_COMMIT=8e5eeba21fd73828f96c232f0d3250f442c4aebc
OLD_PY_DIR="$WORK/old-python-ps1"
mkdir -p "$OLD_PY_DIR"
echo "[pwsh] toggle-uv OFF then ON in a session that loaded 8e5eeba's python.ps1 and _helpers.ps1, after an update in place: python, python3 and py run"
if git -C "$DOTFILES" show "$OLD_PY_PS1_COMMIT:shell/pwsh/python.ps1" > "$OLD_PY_DIR/python.ps1" 2>/dev/null &&
    git -C "$DOTFILES" show "$OLD_PY_PS1_COMMIT:shell/pwsh/_helpers.ps1" > "$OLD_PY_DIR/_helpers.ps1" 2>/dev/null; then
    {
        echo "\$env:PATH = '$WORK' + [IO.Path]::PathSeparator + \$env:PATH"
        echo ". '$OLD_PY_DIR/_helpers.ps1'"
        echo ". '$OLD_PY_DIR/python.ps1'"
    } > "$OLD_PY_DIR/session.ps1"
    actual=$(run_pwsh "$OLD_PY_DIR/session.ps1" "
        $PS_SET_PROFILE
        Set-Location -LiteralPath '$NOPROJ'
        \$oldToggle = (Get-Command toggle-uv).Definition
        python -c 0 6>\$null
        Copy-Item -LiteralPath '$PYTHON_PS1' -Destination '$OLD_PY_DIR/python.ps1' -Force
        toggle-uv *>\$null
        toggle-uv *>\$null
        python -c 1 6>\$null
        python3 -c 2 6>\$null
        py -c 3 6>\$null
        \"TOGGLE-UV FROM 8e5eeba=[\$((Get-Command toggle-uv).Definition -ceq \$oldToggle)]\"
    " 2>&1 | tr -d '\r') || true
    assert_eq "pwsh/toggle-uv ON after an update from 8e5eeba's python.ps1" "mock-uv run -- python -c 0
mock-uv run -- python -c 1
mock-uv run -- python -c 2
mock-uv run -- python -c 3
TOGGLE-UV FROM 8e5eeba=[True]" "$actual"
else
    echo "  SKIP: pwsh/toggle-uv ON after an update from 8e5eeba's python.ps1 (no git, or no commit $OLD_PY_PS1_COMMIT, at $DOTFILES)"
fi

echo "[pwsh] toggle-uv OFF removes every override, also after an ON"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
    $PS_SET_PROFILE
    \$names = 'uv', 'python', 'python3', 'pip', 'pip3', 'py', 'Show-UvOnlyMessage', '_DenPyMarker', '_DenPyExe', '_DenPyRun'
    toggle-uv *>\$null
    \$left1 = \$names | Where-Object { Get-Command \$_ -CommandType Function -ErrorAction SilentlyContinue }
    toggle-uv *>\$null
    toggle-uv *>\$null
    \$left2 = \$names | Where-Object { Get-Command \$_ -CommandType Function -ErrorAction SilentlyContinue }
    \"ENV=[\$env:_DEN_UV_OVERRIDE] OFF1=[\$(\$left1 -join ',')] OFF2=[\$(\$left2 -join ',')]\"
" | tr -d '\r')
assert_eq "pwsh/toggle-uv OFF leaves no override" "ENV=[0] OFF1=[] OFF2=[]" "$actual"

echo "[pwsh] toggle-uv ON reports ON with the arrow"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
    $PS_SET_PROFILE
    toggle-uv *>\$null
    toggle-uv 6>&1
" | tr -d '\r' | tr -d '\n')
assert_eq "pwsh/toggle-uv ON message" "uv override: ON (python/pip → uv)" "$actual"

# init.ps1 loads python.ps1 from its own directory, which is not $PROFILE's when
# it runs from a checkout; nothing loaded must not read as ON.
echo "[pwsh] toggle-uv ON warns and stays OFF when python.ps1 is not beside it"
actual=$(run_pwsh "$WORK/no-python-ps1/python_combined.ps1" "
    $PS_SET_EMPTY_PROFILE
    toggle-uv *>\$null
    toggle-uv 6>\$null 3>&1
    \$pip = if (Get-Command pip -CommandType Function -ErrorAction SilentlyContinue) { 'function' } else { 'none' }
    \"ENV=[\$env:_DEN_UV_OVERRIDE] PIP=[\$pip]\"
" | tr -d '\r')
assert_contains "pwsh/toggle-uv failed ON warns" "could not load the uv overrides" "$actual"
assert_contains "pwsh/toggle-uv failed ON stays OFF" "ENV=[0] PIP=[none]" "$actual"

echo "[pwsh] _DEN_UV_OVERRIDE=0 at load: no overrides, and one toggle-uv turns them on"
# toggle-uv leaves it in the environment, so a reload (a new pwsh) or a child pwsh
# starts with it; loading the overrides anyway left them ON under an OFF, and the
# next toggle took the OFF branch again.
actual=$(_DEN_UV_OVERRIDE=0 pwsh -NoProfile -NonInteractive -Command "
    . '$PYTHON_PS1_COMBINED'
    $PS_SET_PROFILE
    \$left = 'uv', 'python', 'python3', 'pip', 'pip3', 'py', 'Show-UvOnlyMessage', '_DenPyMarker', '_DenPyExe', '_DenPyRun' |
        Where-Object { Get-Command \$_ -CommandType Function -ErrorAction SilentlyContinue }
    \$missing = 'va', 'vd', 'vv', 'vva', 'toggle-uv', 'tgl-uv' |
        Where-Object { -not (Get-Command \$_ -CommandType Function -ErrorAction SilentlyContinue) }
    \"LOAD: ENV=[\$env:_DEN_UV_OVERRIDE] LEFT=[\$(\$left -join ',')] MISSING=[\$(\$missing -join ',')]\"
    \$msg = @(toggle-uv 6>&1) -join ''
    \"\$msg|ENV=[\$env:_DEN_UV_OVERRIDE]\"
    \$env:VIRTUAL_ENV = '$WORK/venv_nopip'
    pip install rich 6>\$null
" 2>&1 | tr -d '\r')
assert_eq "pwsh/_DEN_UV_OVERRIDE=0 at load" "LOAD: ENV=[0] LEFT=[] MISSING=[]
uv override: ON (python/pip → uv)|ENV=[1]
mock-uv pip install rich" "$actual"

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

# den's uv, pip and python3 take over the ones on PATH, so they are den's only
# when typed at the prompt of an interactive session: a user's script, and a
# pwsh -Command run that loaded the profile, get the uv, pip and python3 on
# PATH, as without den. py, which names nothing on PATH here, stays den's in a
# script too. Inside a venv den's uv run adds --python, which tells the two uv
# apart. Stubs stand in for the system pip and python3. The overrides resolve
# uv through _ResolveCmd, whose cache was once kept in $script:, which inside a
# user's .ps1 is that script's scope: there `uv` did not resolve and py ran
# `& $null`.
PY_SCRIPT_BIN="$WORK/py-script-bin"
mkdir -p "$PY_SCRIPT_BIN"
# The mock uv, but with no completion script for den's load to cache.
cat > "$PY_SCRIPT_BIN/uv" << 'MOCK'
#!/bin/sh
[ "$1" = generate-shell-completion ] && exit 0
echo "mock-uv $*"
MOCK
chmod +x "$PY_SCRIPT_BIN/uv"
for t in pip python3; do
    printf '#!/bin/sh\necho "system-%s $*"\n' "$t" > "$PY_SCRIPT_BIN/$t"
    chmod +x "$PY_SCRIPT_BIN/$t"
done
cat > "$WORK/usepy.ps1" <<'EOF'
uv run app.py
pip install rich
function Invoke-Py { python3 app.py }
Invoke-Py
py app.py
EOF
PY_SCRIPT_PRELUDE="Set-Location -LiteralPath '$NOPROJ'; \$env:PATH = '$PY_SCRIPT_BIN:/usr/bin:/bin'; \$env:VIRTUAL_ENV = '$WORK/novenv'; \$env:_DEN_VENV_PYTHON = '3.12'"
echo "[pwsh] a user script gets the uv, pip and python3 on PATH, and den's py"
actual=$(run_pwsh_den "$PY_SCRIPT_PRELUDE" "& '$WORK/usepy.ps1'" 2>/dev/null | tr -d '\r' || true)
assert_eq "pwsh/uv, pip, python3, py from a script" "mock-uv run app.py
system-pip install rich
system-python3 app.py
mock-uv run --python 3.12 -- python app.py" "$actual"
err=$(run_pwsh_den "$PY_SCRIPT_PRELUDE" "& '$WORK/usepy.ps1'" 2>&1 >/dev/null | tr -d '\r' || true)
assert_eq "pwsh/python names from a script: no errors" "" "$err"
echo "[pwsh] typed at the prompt, uv, pip and python3 are den's"
actual=$(run_pwsh_den "$PY_SCRIPT_PRELUDE" "uv run app.py; pip install rich 6>\$null; python3 app.py" 2>/dev/null | tr -d '\r' || true)
assert_eq "pwsh/typed uv, pip, python3" "mock-uv run --python 3.12 -- app.py
mock-uv pip install rich
mock-uv run --python 3.12 -- python app.py" "$actual"
echo "[pwsh] a pwsh -Command run that loaded den gets the python3 on PATH"
actual=$(run_pwsh_den "$PY_SCRIPT_PRELUDE; \$env:_DEN_FORCE_INTERACTIVE = \$null" "python3 app.py" 2>/dev/null | tr -d '\r' || true)
assert_eq "pwsh/python3 in a -Command run" "system-python3 app.py" "$actual"
# A session that starts with the redirects OFF (a reload or a child pwsh after
# toggle-uv turned them off) had no record of these names when den loaded, so
# once toggle-uv turned them on, its scripts got den's uv, pip and python3. The
# same holds after den loads again.
echo "[pwsh] after toggle-uv turns the redirects on, a script still gets the uv, pip and python3 on PATH"
actual=$(run_pwsh_den "$PY_SCRIPT_PRELUDE; \$env:_DEN_UV_OVERRIDE = '0'" "
    toggle-uv 6>\$null
    & '$WORK/usepy.ps1'
    python3 app.py
    . '$DOTFILES/shell/pwsh/init.ps1'
    & '$WORK/usepy.ps1'
" 2>/dev/null | tr -d '\r' || true)
assert_eq "pwsh/uv, pip, python3 from a script after toggle-uv; typed python3; after a reload" "mock-uv run app.py
system-pip install rich
system-python3 app.py
mock-uv run --python 3.12 -- python app.py
mock-uv run --python 3.12 -- python app.py
mock-uv run app.py
system-pip install rich
system-python3 app.py
mock-uv run --python 3.12 -- python app.py" "$actual"

echo "[pwsh] pip/pip3 in a venv use its own pip, else uv pip, never another pip on PATH"
# A uv venv has no pip: the PATH lookup found the system pip ahead of it.
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
    \$env:PATH = '$MOCK_PIP_BIN' + [IO.Path]::PathSeparator + \$env:PATH
    \$env:VIRTUAL_ENV = '$WORK/venv_nopip'
    pip install requests 6>\$null
    pip3 install rich 6>\$null
    \$env:VIRTUAL_ENV = '$WORK/venv_ownpip'
    pip install requests
    pip3 install rich
" 2>&1 | tr -d '\r')
assert_eq "pwsh/pip in a venv: uv pip without its own pip, else its own" "mock-uv pip install requests
mock-uv pip install rich
venv-pip install requests
venv-pip3 install rich" "$actual"
# Neither its own pip nor uv: an error, not the system pip.
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
    \$env:PATH = '$MOCK_PIP_BIN'
    \$env:VIRTUAL_ENV = '$WORK/venv_nopip'
    pip install requests 2>&1 | ForEach-Object { \"\$_\" }
" | tr -d '\r')
assert_contains "pwsh/pip in a venv without pip or uv fails" "the active venv has no pip and uv is not on PATH" "$actual"
assert_not_contains "pwsh/pip in a venv without pip or uv runs no system pip" "system-pip" "$actual"

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
# PowerShell adds its own "va: "; run_pwsh_stderr_oneline is the runner whose
# single-line command shows that prefix and the message together, which is the
# only form a hand-written second prefix is visible in (see helpers.sh).
assert_not_contains "pwsh/va tracked no double prefix" "va: va:" "$(run_pwsh_stderr_oneline "$PYTHON_PS1_COMBINED" "Set-Location '$WORK/ps_venv_tracked'; va")"

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
assert_not_contains "pwsh/va world-writable no double prefix" "va: va:" "$(run_pwsh_stderr_oneline "$PYTHON_PS1_COMBINED" "Set-Location '$WORK/ps_venv_ww'; \$env:VIRTUAL_ENV = \$null; va")"
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

# uv venv and virtualenv write bin/activate.ps1 in lower case; on a case-sensitive
# file system (Linux, case-sensitive macOS) a lookup for bin/Activate.ps1 misses it.
echo "[pwsh] va activates a venv whose script is bin/activate.ps1 (uv, virtualenv)"
mk_venv_ps "$WORK/ps_venv_lc" "3.12.0"
mv "$WORK/ps_venv_lc/.venv/bin/Activate.ps1" "$WORK/ps_venv_lc/.venv/bin/activate.ps1"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
    Set-Location '$WORK/ps_venv_lc'
    \$env:VIRTUAL_ENV = \$null
    va *>\$null
    \"VE=[\$env:VIRTUAL_ENV] PY=[\$env:_DEN_VENV_PYTHON]\"
" | tr -d '\r')
assert_eq "pwsh/va finds bin/activate.ps1" "VE=[fakevenv] PY=[3.12.0]" "$actual"

echo "[pwsh] va prefers bin/Activate.ps1 when both spellings exist"
mk_venv_ps "$WORK/ps_venv_both" "3.12.0"
printf '%s\n' '$env:VIRTUAL_ENV = "lowercase"' > "$WORK/ps_venv_both/.venv/bin/activate.ps1"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "Set-Location '$WORK/ps_venv_both'; \$env:VIRTUAL_ENV = \$null; va *>\$null; \$env:VIRTUAL_ENV" | tr -d '\r')
assert_eq "pwsh/va prefers bin/Activate.ps1" "fakevenv" "$actual"

echo "[pwsh] va refuses a venv whose bin/activate.ps1 is committed"
# Only the lower-case script is tracked, so the refusal must come from that file
# being in the git ls-files list, not from pyvenv.cfg.
mk_venv_ps "$WORK/ps_venv_lc_tracked" "3.12.0"
mv "$WORK/ps_venv_lc_tracked/.venv/bin/Activate.ps1" "$WORK/ps_venv_lc_tracked/.venv/bin/activate.ps1"
(
    cd "$WORK/ps_venv_lc_tracked" || exit 1
    git init -q .
    git -c user.email=t@example.com -c user.name=t add -f .venv/bin/activate.ps1
    git -c user.email=t@example.com -c user.name=t commit -q -m "committed activate.ps1"
) >/dev/null 2>&1
err=$(run_pwsh_stderr "$PYTHON_PS1_COMBINED" "Set-Location '$WORK/ps_venv_lc_tracked'; \$env:VIRTUAL_ENV = \$null; va")
assert_contains "pwsh/va refuses git-tracked bin/activate.ps1" "tracked by git (bin/activate.ps1)" "$err"

echo "[pwsh] va activates, or refuses when committed, a Scripts/activate.ps1"
mk_venv_ps "$WORK/ps_venv_scripts_lc" "3.12.0"
mkdir -p "$WORK/ps_venv_scripts_lc/.venv/Scripts"
mv "$WORK/ps_venv_scripts_lc/.venv/bin/Activate.ps1" "$WORK/ps_venv_scripts_lc/.venv/Scripts/activate.ps1"
rmdir "$WORK/ps_venv_scripts_lc/.venv/bin"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "Set-Location '$WORK/ps_venv_scripts_lc'; \$env:VIRTUAL_ENV = \$null; va *>\$null; \$env:VIRTUAL_ENV" | tr -d '\r')
assert_eq "pwsh/va finds Scripts/activate.ps1" "fakevenv" "$actual"
(
    cd "$WORK/ps_venv_scripts_lc" || exit 1
    git init -q .
    git -c user.email=t@example.com -c user.name=t add -f .venv/Scripts/activate.ps1
    git -c user.email=t@example.com -c user.name=t commit -q -m "committed activate.ps1"
) >/dev/null 2>&1
err=$(run_pwsh_stderr "$PYTHON_PS1_COMBINED" "Set-Location '$WORK/ps_venv_scripts_lc'; \$env:VIRTUAL_ENV = \$null; va")
assert_contains "pwsh/va refuses git-tracked Scripts/activate.ps1" "tracked by git (Scripts/activate.ps1)" "$err"

echo "[pwsh] va refuses a committed activate script whose case differs"
# On NTFS and default APFS, Test-Path for bin/Activate.ps1 also finds a committed
# bin/ACTIVATE.PS1, the same file there. Here they are two files, which is enough
# to show that git reports the committed one.
mk_venv_ps "$WORK/ps_venv_tracked_case" "3.12.0"
printf '%s\n' '$env:VIRTUAL_ENV = "committed"' > "$WORK/ps_venv_tracked_case/.venv/bin/ACTIVATE.PS1"
(
    cd "$WORK/ps_venv_tracked_case" || exit 1
    git init -q .
    git -c user.email=t@example.com -c user.name=t add -f .venv/bin/ACTIVATE.PS1
    git -c user.email=t@example.com -c user.name=t commit -q -m "committed ACTIVATE.PS1"
) >/dev/null 2>&1
err=$(run_pwsh_stderr "$PYTHON_PS1_COMBINED" "Set-Location '$WORK/ps_venv_tracked_case'; \$env:VIRTUAL_ENV = \$null; va")
assert_contains "pwsh/va refuses a tracked bin/ACTIVATE.PS1" "tracked by git (bin/ACTIVATE.PS1)" "$err"

echo "[pwsh] va still refuses a committed venv with GIT_LITERAL_PATHSPECS=1"
# That setting turns :(icase) into a plain file name: the exact names must match.
err=$(run_pwsh_stderr "$PYTHON_PS1_COMBINED" "Set-Location '$WORK/ps_venv_lc_tracked'; \$env:GIT_LITERAL_PATHSPECS = '1'; \$env:VIRTUAL_ENV = \$null; va")
assert_contains "pwsh/va refuses under literal pathspecs" "tracked by git (bin/activate.ps1)" "$err"

echo "[pwsh] va refuses a committed symlinked bin/ and runs nothing behind it"
rm -f "$WORK/symbin_ran"
err=$(run_pwsh_stderr "$PYTHON_PS1_COMBINED" "Set-Location '$SYMBIN'; \$env:VIRTUAL_ENV = \$null; va")
assert_contains "pwsh/va refuses a symlinked bin/" "is a symlink or junction" "$err"
assert_not_exists "pwsh/va dot-sources no script behind a symlinked bin/" "$WORK/symbin_ran"

echo "[pwsh] va refuses a symlinked Activate.ps1 in a real bin/"
rm -f "$WORK/symact_ran"
err=$(run_pwsh_stderr "$PYTHON_PS1_COMBINED" "Set-Location '$SYMACT'; \$env:VIRTUAL_ENV = \$null; va")
assert_contains "pwsh/va refuses a symlinked Activate.ps1" "Activate.ps1 is a symlink or junction" "$err"
assert_not_exists "pwsh/va dot-sources no script behind a symlinked Activate.ps1" "$WORK/symact_ran"

if [ "$GIT_HAS_SAFE_BARE" -eq 1 ]; then
    echo "[pwsh] va refuses a venv committed as a repository of its own"
    rm -f "$WORK/embed_ran" "$WORK/embed_fsmonitor_ran"
    actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
        Set-Location '$EMBED'
        \$env:VIRTUAL_ENV = \$null
        va 2>&1 | ForEach-Object { \"ERR=\$_\" }
        \"VE=[\$env:VIRTUAL_ENV] PY=[\$env:_DEN_VENV_PYTHON]\"
    " | tr -d '\r')
    assert_contains "pwsh/va names git's refusal of the venv repository" "git could not tell whether the venv is committed (fatal: cannot use bare repository" "$actual"
    assert_contains "pwsh/va activates nothing from a venv repository" "VE=[] PY=[]" "$actual"
    assert_not_exists "pwsh/va dot-sources no script from a venv repository" "$WORK/embed_ran"
    assert_not_exists "pwsh/va runs no fsmonitor of a venv repository" "$WORK/embed_fsmonitor_ran"
else
    echo "  SKIP: pwsh/va venv repository (git before 2.38 has no safe.bareRepository)"
fi

echo "[pwsh] va still refuses a committed bin/ next to the Scripts/ it activates"
mk_venv_ps "$WORK/ps_venv_other_dir" "3.12.0"
mkdir -p "$WORK/ps_venv_other_dir/.venv/Scripts"
printf '%s\n' '$env:VIRTUAL_ENV = "scripts"' > "$WORK/ps_venv_other_dir/.venv/Scripts/Activate.ps1"
(
    cd "$WORK/ps_venv_other_dir" || exit 1
    git init -q .
    git -c user.email=t@example.com -c user.name=t add -f .venv/bin/Activate.ps1
    git -c user.email=t@example.com -c user.name=t commit -q -m "committed bin/"
) >/dev/null 2>&1
err=$(run_pwsh_stderr "$PYTHON_PS1_COMBINED" "Set-Location '$WORK/ps_venv_other_dir'; \$env:VIRTUAL_ENV = \$null; va")
assert_contains "pwsh/va refuses a tracked bin/ beside Scripts/" "tracked by git (bin/Activate.ps1)" "$err"

echo "[pwsh] va accepts a symlinked venv"
# `ln -s ~/venvs/proj .venv` is a legitimate layout, not an attack.
mk_venv_ps "$WORK/ps_venv_symlink_target" "3.12.0"
mkdir -p "$WORK/ps_venv_symlink"
ln -sfn "$WORK/ps_venv_symlink_target/.venv" "$WORK/ps_venv_symlink/.venv"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "Set-Location '$WORK/ps_venv_symlink'; \$env:VIRTUAL_ENV = \$null; va *>\$null; \"VE=[\$env:VIRTUAL_ENV] PY=[\$env:_DEN_VENV_PYTHON]\"" | tr -d '\r')
assert_eq "pwsh/va accepts a symlinked venv" "VE=[fakevenv] PY=[3.12.0]" "$actual"

echo "[pwsh] va refuses when git cannot read the repo (dubious ownership)"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
    Set-Location '$WORK/ps_venv_tracked'
    \$env:GIT_TEST_ASSUME_DIFFERENT_OWNER = '1'; \$env:GIT_CONFIG_GLOBAL = '/dev/null'; \$env:GIT_CONFIG_NOSYSTEM = '1'
    \$env:VIRTUAL_ENV = \$null
    \$lcAll = [string]\$env:LC_ALL
    va 2>&1 | ForEach-Object { \"ERR=\$_\" }
    \"VE=[\$env:VIRTUAL_ENV] PY=[\$env:_DEN_VENV_PYTHON] LC_ALL_KEPT=[\$([string]\$env:LC_ALL -eq \$lcAll)]\"
" | tr -d '\r')
assert_contains "pwsh/va names the git failure" "git could not tell whether the venv is committed (fatal: detected dubious ownership" "$actual"
assert_contains "pwsh/va activates nothing when git fails" "VE=[] PY=[] LC_ALL_KEPT=[True]" "$actual"

echo "[pwsh] va takes only git's own fatal line as 'not a git repository'"
mk_venv_ps "$NAGR/ps" "3.12.0"
(
    cd "$NAGR/ps" || exit 1
    git init -q .
    git -c user.email=t@example.com -c user.name=t add -f .venv/bin/Activate.ps1 .venv/pyvenv.cfg
    git -c user.email=t@example.com -c user.name=t commit -q -m "committed venv"
) >/dev/null 2>&1
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
    Set-Location '$NAGR/ps'
    \$env:GIT_TEST_ASSUME_DIFFERENT_OWNER = '1'; \$env:GIT_CONFIG_GLOBAL = '/dev/null'; \$env:GIT_CONFIG_NOSYSTEM = '1'
    \$env:VIRTUAL_ENV = \$null
    va *>\$null
    \"VE=[\$env:VIRTUAL_ENV] PY=[\$env:_DEN_VENV_PYTHON]\"
" | tr -d '\r')
assert_eq "pwsh/va refuses when only the quoted path says not a git repository" "VE=[] PY=[]" "$actual"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
    Set-Location '$WORK/ps_venv5'
    \$env:GIT_TRACE2 = '1'
    \$env:VIRTUAL_ENV = \$null
    va *>\$null
    \"VE=[\$env:VIRTUAL_ENV] PY=[\$env:_DEN_VENV_PYTHON]\"
" | tr -d '\r')
assert_eq "pwsh/va outside a repo with git trace lines first" "VE=[fakevenv] PY=[3.11.4]" "$actual"

echo "[pwsh] va deactivates the active venv first, and only when it activates"
# python's Activate.ps1 and uv's activate.ps1 each undo only their own kind of
# venv, so va hands the switch to the active venv's own deactivate. A refused va
# must leave the active venv alone.
mk_venv_ps "$WORK/ps_venv_first" "3.12.0"
printf '%s\n' \
    'function global:deactivate { $global:DeactivatedBy = "first"; Remove-Item Env:VIRTUAL_ENV; Remove-Item function:deactivate }' \
    '$env:VIRTUAL_ENV = "first"' > "$WORK/ps_venv_first/.venv/bin/Activate.ps1"
mk_venv_ps "$WORK/ps_venv_second" "3.13.0"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
    \$env:VIRTUAL_ENV = \$null
    va '$WORK/ps_venv_first/.venv' *>\$null
    va '$WORK/ps_venv_second/.venv' *>\$null
    \"VE=[\$env:VIRTUAL_ENV] BY=[\$global:DeactivatedBy] PY=[\$env:_DEN_VENV_PYTHON]\"
" | tr -d '\r')
assert_eq "pwsh/va runs the active venv's deactivate before switching" "VE=[fakevenv] BY=[first] PY=[3.13.0]" "$actual"
chmod 666 "$WORK/ps_venv_second/.venv/bin/Activate.ps1"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
    \$env:VIRTUAL_ENV = \$null
    va '$WORK/ps_venv_first/.venv' *>\$null
    va '$WORK/ps_venv_second/.venv' *>\$null
    \"VE=[\$env:VIRTUAL_ENV] BY=[\$global:DeactivatedBy] PY=[\$env:_DEN_VENV_PYTHON]\"
" | tr -d '\r')
assert_eq "pwsh/va refused keeps the active venv" "VE=[first] BY=[] PY=[3.12.0]" "$actual"

echo "[pwsh] va leaves no version of the previous venv behind"
# The next venv has no pyvenv.cfg, or its activate script does not parse: either
# way the version va read for the previous venv must not outlive the switch.
mk_venv_ps "$WORK/ps_venv_nocfg" "3.13.0"
rm "$WORK/ps_venv_nocfg/.venv/pyvenv.cfg"
mk_venv_ps "$WORK/ps_venv_broken" "3.13.0"
printf '%s\n' 'this is { not valid' > "$WORK/ps_venv_broken/.venv/bin/Activate.ps1"
for next in nocfg broken; do
    actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
        \$env:VIRTUAL_ENV = \$null
        va '$WORK/ps_venv_first/.venv' *>\$null
        try { va '$WORK/ps_venv_$next/.venv' *>\$null } catch { }
        \"VE=[\$env:VIRTUAL_ENV] PY=[\$env:_DEN_VENV_PYTHON]\"
    " 2>/dev/null | tr -d '\r')
    case $next in nocfg) want="VE=[fakevenv] PY=[]" ;; *) want="VE=[] PY=[]" ;; esac
    assert_eq "pwsh/va to a $next venv drops the previous version" "$want" "$actual"
done

echo "[pwsh] va switches between the two kinds of activate script; vd restores PATH"
# python's Activate.ps1 keeps the old PATH in $env:_OLD_VIRTUAL_PATH, uv's and
# virtualenv's activate.ps1 in a global variable, and each one's own
# deactivate -NonDestructive restores only its own. These stand-ins keep just that
# part of each, so the switch is tested where uv is not installed (the CI image).
mkdir -p "$WORK/ps_kinds/std/bin" "$WORK/ps_kinds/uv/bin"
cat > "$WORK/ps_kinds/std/bin/Activate.ps1" << 'PS1'
function global:deactivate([switch]$NonDestructive) {
    if (Test-Path Env:_OLD_VIRTUAL_PATH) {
        $env:PATH = $env:_OLD_VIRTUAL_PATH
        Remove-Item Env:_OLD_VIRTUAL_PATH
    }
    Remove-Item Env:VIRTUAL_ENV -ErrorAction SilentlyContinue
    if (-not $NonDestructive) { Remove-Item function:deactivate }
}
deactivate -NonDestructive
$env:VIRTUAL_ENV = Split-Path -Parent $PSScriptRoot
$env:_OLD_VIRTUAL_PATH = $env:PATH
$env:PATH = $PSScriptRoot + [IO.Path]::PathSeparator + $env:PATH
PS1
cat > "$WORK/ps_kinds/uv/bin/activate.ps1" << 'PS1'
function global:deactivate([switch]$NonDestructive) {
    if (Test-Path variable:_OLD_VIRTUAL_PATH) {
        $env:PATH = $variable:_OLD_VIRTUAL_PATH
        Remove-Variable _OLD_VIRTUAL_PATH -Scope global
    }
    Remove-Item Env:VIRTUAL_ENV -ErrorAction SilentlyContinue
    if (-not $NonDestructive) { Remove-Item function:deactivate }
}
deactivate -NonDestructive
$env:VIRTUAL_ENV = Split-Path -Parent $PSScriptRoot
New-Variable -Scope global -Name _OLD_VIRTUAL_PATH -Value $env:PATH
$env:PATH = $PSScriptRoot + [IO.Path]::PathSeparator + $env:PATH
PS1
for pair in "std uv" "uv std"; do
    first=${pair% *} second=${pair#* }
    actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
        \$env:VIRTUAL_ENV = \$null
        \$p0 = \$env:PATH
        va '$WORK/ps_kinds/$first' *>\$null
        va '$WORK/ps_kinds/$second' *>\$null
        \$leaf = if (\$env:VIRTUAL_ENV) { Split-Path -Leaf \$env:VIRTUAL_ENV } else { '' }
        \$venvDirs = @(\$env:PATH -split [IO.Path]::PathSeparator | Where-Object { \$_ -like '*ps_kinds*' }).Count
        \"VE=[\$leaf] VENV_DIRS_ON_PATH=[\$venvDirs]\"
        vd
        \"PATH=[\$(\$env:PATH -eq \$p0)]\"
    " 2>&1 | tr -d '\r')
    assert_eq "pwsh/va $first-kind then $second-kind stand-in, then vd" "VE=[$second] VENV_DIRS_ON_PATH=[1]
PATH=[True]" "$actual"
done

# =============================================================================
# python, python3, py and pip where uv would build or run a clone's code
# =============================================================================
# uv run in a directory with a pyproject.toml, or below one, builds that project
# (its build backend is the repository's own code, and `python --version` built
# it too), and with a .venv here or above it runs that .venv's python, which a
# clone may commit; uv pip with no venv active picks that .venv as well. uv
# takes a directory that holds a pyvenv.cfg for a venv, whatever its name, so
# uv run in it or below it runs the python there too (cfgvenv/).
# ROUTE_BIN's uv writes each call to ROUTE_LOG and answers `uv python find` with
# a stand-in system python (--no-managed-python) or a stand-in uv-managed one
# (--managed-python); ROUTE_NO_SYSTEM and ROUTE_NO_MANAGED make it find none.
# Any other command prints "mock-uv <args>". Each stand-in python prints its
# kind and its arguments.
R="$WORK/route"
ROUTE_BIN="$R/bin"
ROUTE_LOG="$R/uvcalls"
mkdir -p "$ROUTE_BIN" "$R/sys" "$R/managed" "$R/venv/bin" "$R/proj/sub" "$R/vproj/.venv" "$R/cfgvenv/bin" "$R/cfgvenv/sub"
cat > "$ROUTE_BIN/uv" << EOF
#!/bin/sh
echo "\$*" >> "$ROUTE_LOG"
case "\$1 \$2" in
"python find")
    case " \$* " in
    *" --no-managed-python "*) [ -z "\${ROUTE_NO_SYSTEM-}" ] || exit 2; echo "$R/sys/python3" ;;
    *) [ -z "\${ROUTE_NO_MANAGED-}" ] || exit 2; echo "$R/managed/python3.13" ;;
    esac
    exit 0 ;;
esac
echo "mock-uv \$*"
EOF
printf '#!/bin/sh\necho "system-python $*"\n' > "$R/sys/python3"
printf '#!/bin/sh\necho "managed-python $*"\n' > "$R/managed/python3.13"
printf '#!/bin/sh\necho "venv-python $*"\n' > "$R/venv/bin/python"
printf '#!/bin/sh\necho "cfgvenv-python $*"\n' > "$R/cfgvenv/bin/python"
chmod +x "$ROUTE_BIN/uv" "$R/sys/python3" "$R/managed/python3.13" "$R/venv/bin/python" "$R/cfgvenv/bin/python"
: > "$R/proj/pyproject.toml"
printf 'home = /usr/bin\n' > "$R/cfgvenv/pyvenv.cfg"
ln -s "$R/proj/sub" "$R/link"
# uv starts from the current directory with its symbolic links resolved, and so
# does python.sh: it names a project found that way under this spelling of $R.
RP=$(cd "$R" && pwd -P)

# route_posix <shell> <dir> <command> - run the command in <dir> with python.sh
# loaded, ROUTE_BIN first on PATH and no venv active; print its stdout and then
# "rc=<status>". Its stderr goes to $R/err, and ROUTE_LOG starts empty.
route_posix() {
    : > "$ROUTE_LOG"
    "$1" -c "export PATH='$ROUTE_BIN':\$PATH; . '$PYTHON_SH_SOURCE'; unset VIRTUAL_ENV _DEN_VENV_PYTHON; cd '$2' || exit 99; $3; echo \"rc=\$?\"" \
        2>"$R/err" | tr -d '\r'
}

for sh in bash zsh; do
    echo "[$sh] python under a pyproject.toml: the system python, not uv run, and a line that says so"
    actual=$(route_posix "$sh" "$R/proj/sub" "python -c pass")
    assert_eq "$sh/python in a project runs the system python" "system-python -c pass
rc=0" "$actual"
    assert_eq "$sh/python in a project says so" \
        "python: running $R/sys/python3, not uv run: uv run would build or run code from $RP/proj/pyproject.toml" "$(cat "$R/err")"
    assert_eq "$sh/python in a project asks uv only for a system python, ignoring the config here" \
        "python find --system --no-config --no-managed-python" "$(cat "$ROUTE_LOG")"

    echo "[$sh] python3 beside a .venv: the same"
    actual=$(route_posix "$sh" "$R/vproj" "python3 -c pass")
    assert_eq "$sh/python3 beside a .venv runs the system python" "system-python -c pass
rc=0" "$actual"
    assert_contains "$sh/python3 beside a .venv names it" "uv run would build or run code from $RP/vproj/.venv" "$(cat "$R/err")"

    echo "[$sh] python below a directory with a pyvenv.cfg: the same"
    actual=$(route_posix "$sh" "$R/cfgvenv/sub" "python -c pass")
    assert_eq "$sh/python below a pyvenv.cfg runs the system python" "system-python -c pass
rc=0" "$actual"
    assert_eq "$sh/python below a pyvenv.cfg names it" \
        "python: running $R/sys/python3, not uv run: uv run would build or run code from $RP/cfgvenv/pyvenv.cfg" "$(cat "$R/err")"

    echo "[$sh] py through a symbolic link into a project still finds the project"
    actual=$(route_posix "$sh" "$R/link" "py -c pass")
    assert_eq "$sh/py through a link runs the system python" "system-python -c pass
rc=0" "$actual"
    assert_contains "$sh/py through a link names the project" "code from $RP/proj/pyproject.toml" "$(cat "$R/err")"

    echo "[$sh] --version and -V anywhere: the python directly, and nothing on stderr"
    actual=$(route_posix "$sh" "$NOPROJ" "py --version; python -V")
    assert_eq "$sh/--version and -V run the system python" "system-python --version
system-python -V
rc=0" "$actual"
    assert_eq "$sh/--version and -V outside a project print no line" "" "$(cat "$R/err")"

    echo "[$sh] outside a project: uv run, as before"
    actual=$(route_posix "$sh" "$NOPROJ" "python -c pass")
    assert_eq "$sh/python outside a project goes through uv run" "mock-uv run -- python -c pass
rc=0" "$actual"
    assert_eq "$sh/python outside a project says so" "python -c pass → uv run -- python -c pass" "$(cat "$R/err")"

    echo "[$sh] no system python: one uv installed; neither: an error, and nothing runs"
    actual=$(route_posix "$sh" "$R/proj" "export ROUTE_NO_SYSTEM=1; python -c pass")
    assert_eq "$sh/python falls back to a uv-managed python" "managed-python -c pass
rc=0" "$actual"
    actual=$(route_posix "$sh" "$R/proj" "export ROUTE_NO_SYSTEM=1 ROUTE_NO_MANAGED=1; python -c pass")
    assert_eq "$sh/python with no python to run fails" "rc=1" "$actual"
    assert_eq "$sh/python with no python to run says so" \
        "python: no Python found to run in place of uv run; uv python install installs one" "$(cat "$R/err")"
    assert_eq "$sh/python with no python to run only asks uv" "python find --system --no-config --no-managed-python
python find --system --no-config --managed-python" "$(cat "$ROUTE_LOG")"

    echo "[$sh] in a venv va activated, in a project: the venv's python, not uv run --python"
    actual=$(route_posix "$sh" "$R/proj" "export VIRTUAL_ENV='$R/venv' _DEN_VENV_PYTHON=3.12; python -c pass")
    assert_eq "$sh/python in a venv in a project runs the venv's python" "venv-python -c pass
rc=0" "$actual"
    assert_eq "$sh/python in a venv in a project says so" \
        "python: running $R/venv/bin/python, not uv run: uv run would build or run code from $RP/proj/pyproject.toml" "$(cat "$R/err")"
    actual=$(route_posix "$sh" "$NOPROJ" "export VIRTUAL_ENV='$R/venv' _DEN_VENV_PYTHON=3.12; python -c pass")
    assert_eq "$sh/python in a venv outside a project: uv run --python, as before" "mock-uv run --python 3.12 -- python -c pass
rc=0" "$actual"

    echo "[$sh] pip and pip3 with no venv active: nothing runs, and they say what to do"
    actual=$(route_posix "$sh" "$R/vproj" "pip install foo; echo \"pip=\$?\"; pip3 list")
    assert_eq "$sh/pip and pip3 with no venv fail" "pip=1
rc=1" "$actual"
    assert_eq "$sh/pip and pip3 with no venv say what to do" "pip: no venv is active; activate one with va, or type uv pip install foo directly
pip3: no venv is active; activate one with va, or type uv pip list directly" "$(cat "$R/err")"
    assert_eq "$sh/pip and pip3 with no venv run no uv" "" "$(cat "$ROUTE_LOG")"
done

# The same on pwsh. route_pwsh <dir> <command> runs the command in <dir> with
# python.ps1 loaded, ROUTE_BIN first on PATH and no venv active, and prints, in
# order, each output line, a warning as "WARNING: <text>", an error as
# "ERROR: <text>" and a Write-Host line as "HOST: <text>". ROUTE_LOG starts
# empty. pwsh walks up the directory as it has it, and follows a symbolic link
# on the way, so it names a project by the path it found it under.
PYTHON_PS1_ROUTE="$TESTTMP/python_route.ps1"
{
    echo "\$env:PATH = '$ROUTE_BIN' + [IO.Path]::PathSeparator + \$env:PATH"
    echo ". '$DOTFILES/shell/pwsh/_helpers.ps1'"
    cat "$PYTHON_PS1"
} > "$PYTHON_PS1_ROUTE"
route_pwsh() {
    : > "$ROUTE_LOG"
    pwsh -NoProfile -NonInteractive -Command "
        . '$PYTHON_PS1_ROUTE'
        Remove-Item Env:\\VIRTUAL_ENV, Env:\\_DEN_VENV_PYTHON -ErrorAction SilentlyContinue
        Set-Location -LiteralPath '$1'
        & { $2 } *>&1 | ForEach-Object {
            if (\$_ -is [System.Management.Automation.WarningRecord]) { \"WARNING: \$(\$_.Message)\" }
            elseif (\$_ -is [System.Management.Automation.ErrorRecord]) { \"ERROR: \$(\$_.Exception.Message)\" }
            elseif (\$_ -is [System.Management.Automation.InformationRecord]) { \"HOST: \$_\" }
            else { \"\$_\" }
        }
    " 2>&1 | tr -d '\r'
}

echo "[pwsh] python under a pyproject.toml: the system python, not uv run, and a warning"
actual=$(route_pwsh "$R/proj/sub" "python -c pass")
assert_eq "pwsh/python in a project runs the system python" "WARNING: python: running $R/sys/python3, not uv run: uv run would build or run code from $R/proj/pyproject.toml
system-python -c pass" "$actual"
assert_eq "pwsh/python in a project asks uv only for a system python, ignoring the config here" \
    "python find --system --no-config --no-managed-python" "$(cat "$ROUTE_LOG")"

echo "[pwsh] python3 beside a .venv, and py through a symbolic link into a project"
actual=$(route_pwsh "$R/vproj" "python3 -c pass")
assert_eq "pwsh/python3 beside a .venv runs the system python" "WARNING: python3: running $R/sys/python3, not uv run: uv run would build or run code from $R/vproj/.venv
system-python -c pass" "$actual"
actual=$(route_pwsh "$R/link" "py -c pass")
assert_eq "pwsh/py through a link finds the project" "WARNING: py: running $R/sys/python3, not uv run: uv run would build or run code from $R/proj/pyproject.toml
system-python -c pass" "$actual"

echo "[pwsh] python below a directory with a pyvenv.cfg: the same"
actual=$(route_pwsh "$R/cfgvenv/sub" "python -c pass")
assert_eq "pwsh/python below a pyvenv.cfg runs the system python" "WARNING: python: running $R/sys/python3, not uv run: uv run would build or run code from $R/cfgvenv/pyvenv.cfg
system-python -c pass" "$actual"

echo "[pwsh] --version and -V anywhere: the python directly, and no other line"
actual=$(route_pwsh "$NOPROJ" "py --version; python -V")
assert_eq "pwsh/--version and -V run the system python" "system-python --version
system-python -V" "$actual"

echo "[pwsh] outside a project: uv run, as before"
actual=$(route_pwsh "$NOPROJ" "python -c pass")
assert_eq "pwsh/python outside a project goes through uv run" "HOST: python -c pass → uv run -- python -c pass
mock-uv run -- python -c pass" "$actual"

echo "[pwsh] no system python: one uv installed; neither: an error under python's own name"
actual=$(route_pwsh "$R/proj" "\$env:ROUTE_NO_SYSTEM = '1'; python -c pass")
assert_eq "pwsh/python falls back to a uv-managed python" "WARNING: python: running $R/managed/python3.13, not uv run: uv run would build or run code from $R/proj/pyproject.toml
managed-python -c pass" "$actual"
actual=$(route_pwsh "$R/proj" "\$env:ROUTE_NO_SYSTEM = '1'; \$env:ROUTE_NO_MANAGED = '1'; python -c pass")
assert_eq "pwsh/python with no python to run fails" \
    "ERROR: no Python found to run in place of uv run; uv python install installs one" "$actual"
# PowerShell names the function that wrote an error: python's own, not a helper's.
err=$(run_pwsh_stderr_oneline "$PYTHON_PS1_ROUTE" "Remove-Item Env:\\VIRTUAL_ENV -ErrorAction SilentlyContinue; Set-Location -LiteralPath '$R/proj'; \$env:ROUTE_NO_SYSTEM = '1'; \$env:ROUTE_NO_MANAGED = '1'; python -c pass")
assert_contains "pwsh/python's error is python's" "python: no Python found" "$err"

echo "[pwsh] in a venv va activated, in a project: the venv's python, not uv run --python"
actual=$(route_pwsh "$R/proj" "\$env:VIRTUAL_ENV = '$R/venv'; \$env:_DEN_VENV_PYTHON = '3.12'; python -c pass")
assert_eq "pwsh/python in a venv in a project runs the venv's python" "WARNING: python: running $R/venv/bin/python, not uv run: uv run would build or run code from $R/proj/pyproject.toml
venv-python -c pass" "$actual"
actual=$(route_pwsh "$NOPROJ" "\$env:VIRTUAL_ENV = '$R/venv'; \$env:_DEN_VENV_PYTHON = '3.12'; python -c pass")
assert_eq "pwsh/python in a venv outside a project: uv run --python, as before" \
    "mock-uv run --python 3.12 -- python -c pass" "$actual"

echo "[pwsh] pip and pip3 with no venv active: nothing runs, and they say what to do"
actual=$(route_pwsh "$R/vproj" "pip install foo; pip3 list")
assert_eq "pwsh/pip and pip3 with no venv say what to do" "ERROR: no venv is active; activate one with va, or type uv pip install foo directly
ERROR: no venv is active; activate one with va, or type uv pip list directly" "$actual"
assert_eq "pwsh/pip and pip3 with no venv run no uv" "" "$(cat "$ROUTE_LOG")"

# =============================================================================
# uv-created venvs (the real uv, when it is installed and has a Python to use)
# =============================================================================

REAL_UV="$(command -v uv 2>/dev/null || true)"
# No network and no user uv.toml: a venv from an interpreter uv already has, or a skip.
export UV_OFFLINE=1 UV_PYTHON_DOWNLOADS=never UV_NO_CONFIG=1
if [ -n "$REAL_UV" ] && "$REAL_UV" venv -q "$WORK/uv_probe" >/dev/null 2>&1; then
    # python.ps1 against the real uv: no mock uv on PATH in front of it.
    PYTHON_PS1_REAL_UV="$TESTTMP/python_real_uv.ps1"
    {
        echo ". '$DOTFILES/shell/pwsh/_helpers.ps1'"
        cat "$PYTHON_PS1"
    } > "$PYTHON_PS1_REAL_UV"

    for sh in bash zsh; do
        echo "[$sh] va and vd on a venv made by uv venv"
        rm -rf "$WORK/uv_posix"
        mkdir -p "$WORK/uv_posix"
        "$REAL_UV" venv -q "$WORK/uv_posix/.venv" >/dev/null 2>&1
        actual=$("$sh" -c "
            source '$PYTHON_SH_SOURCE'
            cd '$WORK/uv_posix' || exit 1
            p0=\$PATH
            va || exit 1
            case \$PATH in \"\$VIRTUAL_ENV/bin:\"*) head=venv ;; *) head=other ;; esac
            echo \"VE=[\${VIRTUAL_ENV##*/}] HEAD=[\$head] PY=[\${_DEN_VENV_PYTHON:+set}]\"
            vd
            [ \"\$PATH\" = \"\$p0\" ] && restored=yes || restored=no
            echo \"VE=[\$VIRTUAL_ENV] PATH=[\$restored] PY=[\$_DEN_VENV_PYTHON]\"
        " 2>&1 | tr -d '\r')
        assert_eq "$sh/va and vd round-trip a uv venv" "VE=[.venv] HEAD=[venv] PY=[set]
VE=[] PATH=[yes] PY=[]" "$actual"
    done

    echo "[pwsh] vva creates and activates a uv venv; vd undoes it"
    # uv's activate.ps1 is virtualenv's: it wraps prompt by returning a string and
    # keeps the old PATH in a global variable, where python's Activate.ps1 keeps it
    # in the environment. Both must come back on vd.
    rm -rf "$WORK/uv_pwsh"
    mkdir -p "$WORK/uv_pwsh"
    actual=$(run_pwsh "$PYTHON_PS1_REAL_UV" "
        Set-Location '$WORK/uv_pwsh'
        function global:prompt { 'PS> ' }
        \$env:VIRTUAL_ENV = \$null
        \$p0 = \$env:PATH
        vva .venv *>\$null
        \$head = (\$env:PATH -split [IO.Path]::PathSeparator)[0]
        \$onPath = \$env:VIRTUAL_ENV -and \$head -eq (Join-Path \$env:VIRTUAL_ENV 'bin')
        \$leaf = if (\$env:VIRTUAL_ENV) { Split-Path -Leaf \$env:VIRTUAL_ENV } else { '' }
        \"VE=[\$leaf] HEAD=[\$onPath] PY=[\$([bool]\$env:_DEN_VENV_PYTHON)] PROMPT=[\$(prompt)]\"
        vd
        \$deact = [bool](Get-Command deactivate -ErrorAction SilentlyContinue)
        \"VE=[\$env:VIRTUAL_ENV] PATH=[\$(\$env:PATH -eq \$p0)] PY=[\$env:_DEN_VENV_PYTHON] PROMPT=[\$(prompt)] DEACTIVATE=[\$deact]\"
    " 2>&1 | tr -d '\r')
    assert_eq "pwsh/vva and vd round-trip a uv venv" "VE=[.venv] HEAD=[True] PY=[True] PROMPT=[(.venv) PS> ]
VE=[] PATH=[True] PY=[] PROMPT=[PS> ] DEACTIVATE=[False]" "$actual"

    # python -m venv from the interpreter uv found: the other kind of activate.ps1.
    if "$WORK/uv_probe/bin/python" -m venv --without-pip "$WORK/uv_mixed/std" >/dev/null 2>&1 &&
        "$REAL_UV" venv -q "$WORK/uv_mixed/uv" >/dev/null 2>&1; then
        echo "[pwsh] va switches between python -m venv and uv venv; vd restores PATH"
        for pair in "std uv" "uv std"; do
            first=${pair% *} second=${pair#* }
            actual=$(run_pwsh "$PYTHON_PS1_REAL_UV" "
                function global:prompt { 'PS> ' }
                \$env:VIRTUAL_ENV = \$null
                \$p0 = \$env:PATH
                va '$WORK/uv_mixed/$first' *>\$null
                va '$WORK/uv_mixed/$second' *>\$null
                \$leaf = if (\$env:VIRTUAL_ENV) { Split-Path -Leaf \$env:VIRTUAL_ENV } else { '' }
                \$venvDirs = @(\$env:PATH -split [IO.Path]::PathSeparator | Where-Object { \$_ -like '*uv_mixed*' }).Count
                # python's prompt writes its prefix with Write-Host: 6>&1 collects it.
                \"VE=[\$leaf] VENV_DIRS_ON_PATH=[\$venvDirs] PROMPT=[\$(@(prompt 6>&1) -join '')]\"
                vd
                \"PATH=[\$(\$env:PATH -eq \$p0)] PROMPT=[\$(@(prompt 6>&1) -join '')]\"
            " 2>&1 | tr -d '\r')
            assert_eq "pwsh/va $first then $second, then vd" "VE=[$second] VENV_DIRS_ON_PATH=[1] PROMPT=[($second) PS> ]
PATH=[True] PROMPT=[PS> ]" "$actual"
        done
    else
        echo "  SKIP: pwsh/va between python -m venv and uv venv (python -m venv failed)"
    fi

    # mk_clones <dir> - three clones under <dir>, each piece of whose code
    # writes its name to <dir>/marks when it runs: build/ has a pyproject.toml
    # whose build backend is in the repository, venv/ commits a .venv and a
    # .python-version that names a program in the repository, and cfg/ commits
    # a pyvenv.cfg and a bin/python at its top, with no pyproject.toml and no
    # .venv. uv run built the first, for `python --version` too, and left a
    # .venv and a uv.lock in it; in the second it ran the .venv's python, and
    # the .python-version's program when it read that file; below the third it
    # ran its bin/python, as uv takes a directory with a pyvenv.cfg for a venv.
    mk_clones() {
        mkdir -p "$1/marks" "$1/build/src" "$1/venv/.venv/bin" "$1/venv/tools" "$1/config" "$1/cfg/bin" "$1/cfg/src"
        printf '[project]\nname = "probe"\nversion = "0.1"\n[build-system]\nrequires = []\nbuild-backend = "backend"\nbackend-path = ["."]\n' \
            > "$1/build/pyproject.toml"
        printf 'open("%s/marks/backend", "a").write("ran\\n")\n' "$1" > "$1/build/backend.py"
        printf '#!/bin/sh\necho ran >> "%s/marks/%s"\nexec "%s" "$@"\n' "$1" venv-python "$WORK/uv_probe/bin/python" > "$1/venv/.venv/bin/python"
        printf 'home = /usr/bin\nversion_info = 3.12.0\n' > "$1/venv/.venv/pyvenv.cfg"
        printf '#!/bin/sh\necho ran >> "%s/marks/%s"\nexec "%s" "$@"\n' "$1" python-version-program "$WORK/uv_probe/bin/python" > "$1/venv/tools/py"
        chmod +x "$1/venv/.venv/bin/python" "$1/venv/tools/py"
        printf './tools/py\n' > "$1/venv/.python-version"
        printf 'home = /usr/bin\nversion_info = 3.12.0\n' > "$1/cfg/pyvenv.cfg"
        printf '#!/bin/sh\necho ran >> "%s/marks/%s"\nexec "%s" "$@"\n' "$1" cfg-python "$WORK/uv_probe/bin/python" > "$1/cfg/bin/python"
        chmod +x "$1/cfg/bin/python"
    }
    # Run with the config files read (UV_NO_CONFIG unset, with no user uv.toml in
    # XDG_CONFIG_HOME), as in a shell of one's own: uv reads a .python-version only then.
    for sh in bash zsh; do
        echo "[$sh] in clones, python, python3, py and pip run none of their code (the real uv)"
        C="$WORK/clones-$sh"
        mk_clones "$C"
        actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$C/config" "$sh" -c "
            . '$PYTHON_SH_SOURCE'
            unset VIRTUAL_ENV _DEN_VENV_PYTHON
            cd '$C/build/src' || exit 1
            python --version
            python3 -c 'print(1)'
            cd '$C/venv' || exit 1
            py -c 'print(2)'
            pip list
            echo \"pip=\$?\"
        " 2>/dev/null | tr -d '\r')
        assert_match "$sh/python --version in a clone answers" "^Python 3\.[0-9]+" "$(printf '%s\n' "$actual" | head -n 1)"
        assert_eq "$sh/python3, py and pip in clones" "1
2
pip=1" "$(printf '%s\n' "$actual" | tail -n +2)"
        assert_eq "$sh/no code of the clones ran" "" "$(ls "$C/marks")"
        assert_not_exists "$sh/no .venv appears in a clone" "$C/build/.venv"
        assert_not_exists "$sh/no uv.lock appears in a clone" "$C/build/uv.lock"

        echo "[$sh] below a clone's pyvenv.cfg, python, python3 and py run none of its code (the real uv)"
        actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$C/config" "$sh" -c "
            . '$PYTHON_SH_SOURCE'
            unset VIRTUAL_ENV _DEN_VENV_PYTHON
            cd '$C/cfg/src' || exit 1
            python -c 'print(3)'
            python3 -c 'print(4)'
            py -c 'print(5)'
        " 2>/dev/null | tr -d '\r') || true
        assert_eq "$sh/python, python3 and py below a pyvenv.cfg" "3
4
5" "$actual"
        assert_not_exists "$sh/the clone's bin/python did not run" "$C/marks/cfg-python"
    done

    echo "[pwsh] in clones, python, python3, py and pip run none of their code (the real uv)"
    C="$WORK/clones-pwsh"
    mk_clones "$C"
    actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$C/config" pwsh -NoProfile -NonInteractive -Command "
        . '$PYTHON_PS1_REAL_UV'
        Remove-Item Env:\\VIRTUAL_ENV, Env:\\_DEN_VENV_PYTHON -ErrorAction SilentlyContinue
        Set-Location -LiteralPath '$C/build/src'
        python --version 3>\$null
        python3 -c 'print(1)' 3>\$null
        Set-Location -LiteralPath '$C/venv'
        py -c 'print(2)' 3>\$null
        pip list 2>\$null
        'pip done'
    " 2>/dev/null | tr -d '\r')
    assert_match "pwsh/python --version in a clone answers" "^Python 3\.[0-9]+" "$(printf '%s\n' "$actual" | head -n 1)"
    assert_eq "pwsh/python3, py and pip in clones" "1
2
pip done" "$(printf '%s\n' "$actual" | tail -n +2)"
    assert_eq "pwsh/no code of the clones ran" "" "$(ls "$C/marks")"
    assert_not_exists "pwsh/no .venv appears in a clone" "$C/build/.venv"
    assert_not_exists "pwsh/no uv.lock appears in a clone" "$C/build/uv.lock"

    echo "[pwsh] below a clone's pyvenv.cfg, python, python3 and py run none of its code (the real uv)"
    actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$C/config" pwsh -NoProfile -NonInteractive -Command "
        . '$PYTHON_PS1_REAL_UV'
        Remove-Item Env:\\VIRTUAL_ENV, Env:\\_DEN_VENV_PYTHON -ErrorAction SilentlyContinue
        Set-Location -LiteralPath '$C/cfg/src'
        python -c 'print(3)' 3>\$null
        python3 -c 'print(4)' 3>\$null
        py -c 'print(5)' 3>\$null
    " 2>/dev/null | tr -d '\r') || true
    assert_eq "pwsh/python, python3 and py below a pyvenv.cfg" "3
4
5" "$actual"
    assert_not_exists "pwsh/the clone's bin/python did not run" "$C/marks/cfg-python"
else
    echo "  SKIP: uv-created venv tests (uv not installed, or no Python it can use offline)"
fi

# =============================================================================
# Summary
# =============================================================================
print_summary "test_python"
[ "$FAIL" -eq 0 ]
