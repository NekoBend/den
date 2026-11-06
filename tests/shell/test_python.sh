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
# pyproject.toml, a .venv or another file uv run would read (see the route
# tests below) in the current directory or one above it they run a python
# directly. The suite itself may run from a checkout, which has a
# pyproject.toml, so a test that wants uv run starts in this directory.
NOPROJ="$WORK/noproj"
mkdir -p "$NOPROJ"

# pip, vv and vva have uv read your own uv.toml, the one uv reads besides a
# project's, in place of a uv.toml or pyproject.toml here or above, which a
# clone can ship; with none, nothing (see the uv.toml checks below). Here no
# such file is found, wherever the suite runs, but in the checks that make one:
# no user one in XDG_CONFIG_HOME, and no system one (UV_NO_SYSTEM_CONFIG, as
# /etc/uv/uv.toml lies outside XDG_CONFIG_DIRS).
export XDG_CONFIG_HOME="$WORK/xdg-config" XDG_CONFIG_DIRS="$WORK/xdg-dirs" UV_NO_SYSTEM_CONFIG=1
# No UV_WORKING_DIR, UV_WORKING_DIRECTORY or UV_PROJECT either, which move
# where uv venv reads (see the vv --directory checks).
unset UV_CONFIG_FILE UV_NO_CONFIG UV_WORKING_DIR UV_WORKING_DIRECTORY UV_PROJECT
mkdir -p "$XDG_CONFIG_HOME" "$XDG_CONFIG_DIRS"
# What the lines pip, pip3, vv and vva print say uv reads, with a uv.toml of
# your own (KEEPS) and without one (NONE).
PIP_KEEPS="reads your uv settings, not a uv.toml or pyproject.toml here or above, which a clone can ship; type uv pip to read those"
PIP_NONE="reads no uv.toml or pyproject.toml here or above, which a clone can ship; type uv pip to read those"
VV_KEEPS="reads your uv settings, not a .python-version, uv.toml or pyproject.toml here or above, which a clone can ship, nor your global .python-version; pick a python with --python, or type uv venv to read those"
VV_NONE="reads no .python-version, uv.toml or pyproject.toml here or above, which a clone can ship, nor your global .python-version; pick a python with --python, or type uv venv to read those"
# The same for vv and vva when --directory or --project points uv elsewhere.
VV_KEEPS_THERE="reads your uv settings, not a .python-version, uv.toml or pyproject.toml there or above, which a clone can ship, nor your global .python-version; pick a python with --python, or type uv venv to read those"
VV_NONE_THERE="reads no .python-version, uv.toml or pyproject.toml there or above, which a clone can ship, nor your global .python-version; pick a python with --python, or type uv venv to read those"

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

# Two checkouts whose .git/config names a core.fsmonitor program, as one that
# came in an archive or a shared folder can: git runs it when it reads the
# index, and va's own git check ran it, before it refused the committed venv
# in fsm_tracked/ and for the venv the user made in fsm_mine/. The program
# leaves a marker. FSM_RUNS is 1 when a plain git ls-files here runs it, so
# the checks below have something to keep from running.
FSM_HOOK="$WORK/fsm_hook"
printf '#!/bin/sh\necho ran >> "%s"\nexit 1\n' "$WORK/fsm_ran" > "$FSM_HOOK"
chmod +x "$FSM_HOOK"
for d in fsm_tracked fsm_mine; do
    mkdir -p "$WORK/$d/.venv/bin"
    : > "$WORK/$d/.venv/bin/activate"
    printf '%s\n' '$env:VIRTUAL_ENV = "fakevenv"' > "$WORK/$d/.venv/bin/Activate.ps1"
    printf 'version_info = 3.12.0\n' > "$WORK/$d/.venv/pyvenv.cfg"
done
(
    cd "$WORK/fsm_tracked" || exit 1
    git init -q .
    git -c user.email=t@example.com -c user.name=t add -f .venv
    git -c user.email=t@example.com -c user.name=t commit -q -m "committed venv"
    git config core.fsmonitor "$FSM_HOOK"
) >/dev/null 2>&1
(
    cd "$WORK/fsm_mine" || exit 1
    git init -q .
    printf '.venv/\n' > .gitignore
    git -c user.email=t@example.com -c user.name=t add .gitignore
    git -c user.email=t@example.com -c user.name=t commit -q -m "ignore venv"
    git config core.fsmonitor "$FSM_HOOK"
) >/dev/null 2>&1
rm -f "$WORK/fsm_ran"
git -C "$WORK/fsm_mine" ls-files >/dev/null 2>&1 || true
FSM_RUNS=0
[ -e "$WORK/fsm_ran" ] && FSM_RUNS=1
rm -f "$WORK/fsm_ran"

# va's git calls turn core.fsmonitor off with an empty value, not false: git
# 2.36 and later read the key as a boolean first, and an empty value is false
# (fsmonitor-settings.c, lookup_fsmonitor_settings); git 2.16 to 2.35 read it
# as the path of a hook alone and take an empty one for none (config.c,
# git_config_get_fsmonitor), where false names a program, which they run. One
# git runs here, so the spelling is checked in the code.
echo "[va] every git call in python.sh and python.ps1 sets core.fsmonitor empty"
for f in "$PYTHON_SH_GUARDED" "$PYTHON_PS1"; do
    calls=$(grep -cE '(command git|& \$gitExe) ' "$f" || true)
    empty=$(grep -cE '(command git|& \$gitExe) -c core\.fsmonitor= ' "$f" || true)
    assert_eq "va: every git call in ${f##*/} sets core.fsmonitor empty, not false" \
        "2 git calls, 2 with core.fsmonitor=" "$calls git calls, $empty with core.fsmonitor="
done

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
assert_contains "bash/pip redirect" "→ uv --no-config pip install foo ($PIP_NONE)" "$err"

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

    if [ "$FSM_RUNS" -eq 1 ]; then
        echo "[$sh] va runs no core.fsmonitor program the checkout's .git/config names"
        rm -f "$WORK/fsm_ran"
        actual=$("$sh" -c "source '$PYTHON_SH_TEST'; cd '$WORK/fsm_tracked' && va; echo \"rc=\$? PY=[\$_DEN_VENV_PYTHON]\"" 2>&1 | tr -d '\r')
        assert_contains "$sh/va still refuses a committed venv there" "venv content is tracked by git" "$actual"
        assert_contains "$sh/va activates nothing from the committed venv there" "rc=1 PY=[]" "$actual"
        assert_not_exists "$sh/va runs no core.fsmonitor program before it refuses" "$WORK/fsm_ran"
        rm -f "$WORK/fsm_ran"
        actual=$("$sh" -c "source '$PYTHON_SH_TEST'; cd '$WORK/fsm_mine' && va; echo \"rc=\$? PY=[\$_DEN_VENV_PYTHON]\"" 2>&1 | tr -d '\r')
        assert_eq "$sh/va activates the user's venv there" "rc=0 PY=[3.12.0]" "$actual"
        assert_not_exists "$sh/va runs no core.fsmonitor program for the user's venv" "$WORK/fsm_ran"
    else
        echo "  SKIP: $sh/va and core.fsmonitor (git here ran no core.fsmonitor program for ls-files)"
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
    # uv pip with --no-config, as you have no uv.toml here (see the uv.toml
    # checks below): pip reads no uv.toml or pyproject.toml, and a clone's in
    # or above the current directory can have uv run a python the clone ships
    # or install a package from its files (see the real-uv checks).
    actual=$("$sh" -c "source '$PYTHON_SH_TEST'; export PATH='$MOCK_PIP_BIN':\$PATH VIRTUAL_ENV='$WORK/venv_nopip'; pip install requests; pip3 install rich" 2>/dev/null | tr -d '\r')
    assert_eq "$sh/pip in a venv without pip goes to uv --no-config pip" "mock-uv --no-config pip install requests
mock-uv --no-config pip install rich" "$actual"
    err=$("$sh" -c "source '$PYTHON_SH_TEST'; export PATH='$MOCK_PIP_BIN':\$PATH VIRTUAL_ENV='$WORK/venv_nopip'; pip install requests; pip3 list" 2>&1 >/dev/null | tr -d '\r')
    assert_eq "$sh/pip in a venv without pip says so, and that no uv settings are read without a uv.toml of yours" "pip install requests → uv --no-config pip install requests ($PIP_NONE)
pip3 list → uv --no-config pip list ($PIP_NONE)" "$err"
    # The uv on PATH, as the other commands den wraps: not a uv function.
    actual=$("$sh" -c "source '$PYTHON_SH_TEST'; uv() { echo \"shadow-uv \$*\"; }; export VIRTUAL_ENV='$WORK/venv_nopip'; pip install requests; pip3 list" 2>/dev/null | tr -d '\r')
    assert_eq "$sh/pip runs the uv on PATH past a uv function" "mock-uv --no-config pip install requests
mock-uv --no-config pip list" "$actual"
    actual=$("$sh" -c "source '$PYTHON_SH_TEST'; export PATH='$MOCK_PIP_BIN':\$PATH VIRTUAL_ENV='$WORK/venv_ownpip'; pip install requests; pip3 install rich" 2>&1 | tr -d '\r')
    assert_eq "$sh/pip in a venv with its own pip runs it" "venv-pip install requests
venv-pip3 install rich" "$actual"

    echo "[$sh] _DEN_UV_OVERRIDE=0 at load: no overrides, and one toggle-uv turns them on"
    # toggle-uv exports it, so a reload or a child shell starts with it; loading
    # the overrides anyway left them ON under an OFF, and the next toggle did nothing.
    actual=$(HOME="$UV_HOME" _DEN_UV_OVERRIDE=0 "$sh" -c "
        source '$PYTHON_SH_TEST'
        left=''
        for f in uv python python3 py pip pip3 _show_uv_only_message _den_py _den_py_exe; do
            case \$(type \$f 2>/dev/null) in *function*) left=\"\$left \$f\" ;; esac
        done
        kept=''
        for f in va vd vv vva toggle-uv tgl-uv _den_py_marker _den_uv_where _den_uv_marker _den_uv_venv _den_uv_config; do
            case \$(type \$f 2>/dev/null) in *function*) kept=\"\$kept \$f\" ;; esac
        done
        echo \"LOAD: LEFT=[\$left] KEPT=[\$kept]\"
        toggle-uv
        echo \"ENV=\$_DEN_UV_OVERRIDE\"
        export VIRTUAL_ENV='$WORK/venv_nopip'
        pip install rich
    " 2>/dev/null | tr -d '\r')
    assert_eq "$sh/_DEN_UV_OVERRIDE=0 at load" "LOAD: LEFT=[] KEPT=[ va vd vv vva toggle-uv tgl-uv _den_py_marker _den_uv_where _den_uv_marker _den_uv_venv _den_uv_config]
uv override: ON (python/pip → uv)
ENV=1
mock-uv --no-config pip install rich" "$actual"
done

# =============================================================================
# Zsh tests
# =============================================================================

echo "[zsh] _show_uv_only_message format"
actual=$(run_zsh_stderr "$PYTHON_SH_TEST" "_show_uv_only_message 'pip' 'uv pip'")
assert_eq "zsh/_show_uv_only_message" "pip → uv pip" "$actual"

echo "[zsh] pip redirect message (in a venv without a pip of its own)"
err=$(run_zsh_stderr "$PYTHON_SH_TEST" "export VIRTUAL_ENV='$WORK/venv_nopip'; pip install foo")
assert_contains "zsh/pip redirect" "→ uv --no-config pip install foo ($PIP_NONE)" "$err"

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
    \$missing = 'uv', 'python', 'python3', 'pip', 'pip3', 'py', 'Show-UvOnlyMessage', '_DenPyMarker', '_DenUvMarker', '_DenPyExe', '_DenPyRun' |
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
assert_eq "pwsh/toggle-uv ON pip goes to uv pip" "mock-uv --no-config pip install rich" "$actual"

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
        foreach (\$n in '_DenPyMarker', '_DenUvMarker', '_DenPyExe', '_DenPyRun') { $setup }
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

echo "[pwsh] toggle-uv OFF removes every override, also after an ON, and keeps what vv and vva ask"
actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
    $PS_SET_PROFILE
    \$names = 'uv', 'python', 'python3', 'pip', 'pip3', 'py', 'Show-UvOnlyMessage', '_DenPyExe', '_DenPyRun'
    \$keep = 'vv', 'vva', '_DenPyMarker', '_DenUvMarker', '_DenUvVenvOptions', '_DenUvConfig'
    toggle-uv *>\$null
    \$left1 = \$names | Where-Object { Get-Command \$_ -CommandType Function -ErrorAction SilentlyContinue }
    \$gone1 = \$keep | Where-Object { -not (Get-Command \$_ -CommandType Function -ErrorAction SilentlyContinue) }
    toggle-uv *>\$null
    toggle-uv *>\$null
    \$left2 = \$names | Where-Object { Get-Command \$_ -CommandType Function -ErrorAction SilentlyContinue }
    \$gone2 = \$keep | Where-Object { -not (Get-Command \$_ -CommandType Function -ErrorAction SilentlyContinue) }
    \"ENV=[\$env:_DEN_UV_OVERRIDE] OFF1=[\$(\$left1 -join ',')] OFF2=[\$(\$left2 -join ',')] GONE1=[\$(\$gone1 -join ',')] GONE2=[\$(\$gone2 -join ',')]\"
" | tr -d '\r')
assert_eq "pwsh/toggle-uv OFF leaves no override, and keeps vv's helpers" "ENV=[0] OFF1=[] OFF2=[] GONE1=[] GONE2=[]" "$actual"

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
    \$left = 'uv', 'python', 'python3', 'pip', 'pip3', 'py', 'Show-UvOnlyMessage', '_DenPyExe', '_DenPyRun' |
        Where-Object { Get-Command \$_ -CommandType Function -ErrorAction SilentlyContinue }
    \$missing = 'va', 'vd', 'vv', 'vva', 'toggle-uv', 'tgl-uv', '_DenPyMarker', '_DenUvMarker', '_DenUvVenvOptions', '_DenUvConfig' |
        Where-Object { -not (Get-Command \$_ -CommandType Function -ErrorAction SilentlyContinue) }
    \"LOAD: ENV=[\$env:_DEN_UV_OVERRIDE] LEFT=[\$(\$left -join ',')] MISSING=[\$(\$missing -join ',')]\"
    \$msg = @(toggle-uv 6>&1) -join ''
    \"\$msg|ENV=[\$env:_DEN_UV_OVERRIDE]\"
    \$env:VIRTUAL_ENV = '$WORK/venv_nopip'
    pip install rich 6>\$null
" 2>&1 | tr -d '\r')
assert_eq "pwsh/_DEN_UV_OVERRIDE=0 at load" "LOAD: ENV=[0] LEFT=[] MISSING=[]
uv override: ON (python/pip → uv)|ENV=[1]
mock-uv --no-config pip install rich" "$actual"

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

# On Linux and macOS pwsh expands a wildcard in a program's argument unless the
# call writes it in quotes, and uv, pip, pip3 and python handed theirs on as
# @Args: a quoted word was expanded too, so `pip install 'foo[x1]'` beside foox
# installed foox. Now a quoted word reaches uv as it is, and one typed without
# quotes is still expanded, as for uv typed by name.
echo "[pwsh] uv, pip and python hand a quoted wildcard on as it is; a bare one is expanded"
mkdir -p "$WORK/g6py" && : > "$WORK/g6py/foo1" && : > "$WORK/g6py/foox"
actual=$(cd "$WORK/g6py" && run_pwsh "$PYTHON_PS1_COMBINED" "
    uv pip install 'foo[x1]'
    \$env:VIRTUAL_ENV = '$WORK/venv_nopip'; \$env:_DEN_VENV_PYTHON = '3.12'
    uv run 'foo*'
    pip install 'foo[x1]' 6>\$null
    python 'foo*' 6>\$null
    uv run foo?
" 2>&1 | tr -d '\r')
assert_eq "pwsh/uv, pip and python: 'foo[x1]' and 'foo*' as they are, foo? expanded" "mock-uv pip install foo[x1]
mock-uv run --python 3.12 -- foo*
mock-uv --no-config pip install foo[x1]
mock-uv run --python 3.12 -- python foo*
mock-uv run --python 3.12 -- foo1 foox" "$actual"
rm -rf "$WORK/g6py"

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
mock-uv --no-config pip install rich
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
assert_eq "pwsh/pip in a venv: uv --no-config pip without its own pip, else its own" "mock-uv --no-config pip install requests
mock-uv --no-config pip install rich
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

if [ "$FSM_RUNS" -eq 1 ]; then
    echo "[pwsh] va runs no core.fsmonitor program the checkout's .git/config names"
    rm -f "$WORK/fsm_ran"
    actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
        Set-Location '$WORK/fsm_tracked'
        \$env:VIRTUAL_ENV = \$null
        va 2>&1 | ForEach-Object { \"ERR=\$_\" }
        \"VE=[\$env:VIRTUAL_ENV] PY=[\$env:_DEN_VENV_PYTHON]\"
    " | tr -d '\r')
    assert_contains "pwsh/va still refuses a committed venv there" "venv content is tracked by git" "$actual"
    assert_contains "pwsh/va activates nothing from the committed venv there" "VE=[] PY=[]" "$actual"
    assert_not_exists "pwsh/va runs no core.fsmonitor program before it refuses" "$WORK/fsm_ran"
    rm -f "$WORK/fsm_ran"
    actual=$(run_pwsh "$PYTHON_PS1_COMBINED" "
        Set-Location '$WORK/fsm_mine'
        \$env:VIRTUAL_ENV = \$null
        va *>\$null
        \"VE=[\$env:VIRTUAL_ENV] PY=[\$env:_DEN_VENV_PYTHON]\"
    " | tr -d '\r')
    assert_eq "pwsh/va activates the user's venv there" "VE=[fakevenv] PY=[3.12.0]" "$actual"
    assert_not_exists "pwsh/va runs no core.fsmonitor program for the user's venv" "$WORK/fsm_ran"
else
    echo "  SKIP: pwsh/va and core.fsmonitor (git here ran no core.fsmonitor program for ls-files)"
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
# uv run in it or below it runs the python there too (cfgvenv/). A uv.toml's
# settings can have uv install and run a python the clone ships (uvtoml/), and
# uv runs the program a .python-version or .python-versions names (pyver/,
# pyverbs/, pyvers/); one of version requests alone is no marker (pyveronly/),
# and neither is a path in a comment line.
# ROUTE_BIN's uv writes each call to ROUTE_LOG and answers `uv python find` with
# a stand-in system python (--no-managed-python) or a stand-in uv-managed one
# (--managed-python); ROUTE_NO_SYSTEM and ROUTE_NO_MANAGED make it find none.
# Any other command prints "mock-uv <args>". Each stand-in python prints its
# kind and its arguments.
R="$WORK/route"
ROUTE_BIN="$R/bin"
ROUTE_LOG="$R/uvcalls"
mkdir -p "$ROUTE_BIN" "$R/sys" "$R/managed" "$R/venv/bin" "$R/proj/sub" "$R/vproj/.venv" "$R/cfgvenv/bin" "$R/cfgvenv/sub" \
    "$R/uvtoml/sub" "$R/pyver/sub" "$R/pyverbs" "$R/pyveronly" "$R/nopyvenv/bin" "$R/pyvers/sub" \
    "$R/pyverzw" "$R/pyverbom" "$R/pyverdir/tools" "$R/pyverdir/sub" "$R/pyverdir/sub2/tools" "$R/pyverpad/tools" \
    "$R/pyver313/3.13" "$R/pyverlong" "$R/pyvermany"
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
: > "$R/uvtoml/uv.toml"
printf '# pinned to the one in tools/\n\n  ../tools/py\n' > "$R/pyver/.python-version"
printf '%s\n' '.\tools\py' > "$R/pyverbs/.python-version"
printf '3.13\ncpython@3.13\npypy3.10\n  # not ./tools/py\n' > "$R/pyveronly/.python-version"
# uv reads a .python-versions the same way (pyvers/).
printf './tools/py\n' > "$R/pyvers/.python-versions"
# uv trims white space alone and keeps a byte order mark, so a line that
# starts with U+200B or a byte order mark and then # names a path to it
# (pyverzw/, pyverbom/). pwsh compared # by culture, which passes over
# U+200B, and read the file with ReadAllText, which drops the mark: to it
# both lines were comments.
printf '\342\200\213#x/tools/py\n' > "$R/pyverzw/.python-version"
printf '\357\273\277#x/tools/py\n' > "$R/pyverbom/.python-version"
# uv looks a bare name up in the current directory, not beside the file, and
# takes a directory for a venv, whose python it runs (pyverdir/; from its
# sub2/, which holds a tools/ as well, too; from its sub/, which holds none,
# not). It trims the line of every Unicode White_Space character first
# (pyverpad/), and a version request that names a directory here counts as
# well (pyver313/). A line over 128 characters, or a 65th one, counts as it
# is (pyverlong/, pyvermany/).
printf 'tools\n' > "$R/pyverdir/.python-version"
printf '\302\240\t tools \343\200\200\r\n' > "$R/pyverpad/.python-version"
printf '3.13\n' > "$R/pyver313/.python-version"
printf '%200s3.13\n' '' > "$R/pyverlong/.python-version"
for _ in $(seq 65); do printf '3.13\n'; done > "$R/pyvermany/.python-version"
# uv reads a regular file only: one that links to /dev/zero is skipped, and
# reading it would not end (pyverzero/).
mkdir -p "$R/pyverzero"
ln -s /dev/zero "$R/pyverzero/.python-version"
# A directory whose name ends in a newline, as an archive or a shared folder
# can name one, with a .python-version that names ./evil (pyvernl<newline>/).
# $( ) drops a newline at the end of what it captures, so the walk read the
# directory back as pyvernl/, which is not there, and found no marker. The
# route directory itself holds none.
NL=$'\n'
NLD="$R/pyvernl$NL"
mkdir -p "$NLD"
printf './evil\n' > "$NLD/.python-version"
ln -s "$R/proj/sub" "$R/link"
# rlink/ is link/ with a relative target, deep/a/up/ a link whose target
# climbs with .., and loop/ a link to itself. The system takes a .. after a
# link from where the link led, and enters no loop: neither does uv.
ln -s proj/sub "$R/rlink"
mkdir -p "$R/deep/a"
ln -s ../../proj/sub "$R/deep/a/up"
ln -s loop "$R/loop"
# uv starts from the current directory with its symbolic links resolved, and so
# does python.sh: it names a project found that way under this spelling of $R.
RP=$(cd "$R" && pwd -P)
# A venv that vva's mock uv leaves in a directory with no marker (sete/myenv/),
# outside a git checkout, for vva under set -e.
mkdir -p "$R/sete/myenv/bin"
printf 'VIRTUAL_ENV=%s/sete/myenv; export VIRTUAL_ENV\n' "$R" > "$R/sete/myenv/bin/activate"
printf 'version_info = 3.13.1\n' > "$R/sete/myenv/pyvenv.cfg"
# vva's fixtures, outside a git checkout. vvadir/, with no marker, holds a
# myenv/, whose name vva took from here: a decoy that vva must not take for
# the one uv made in vvadir/elsewhere/myenv/. via/ links to elsewhere/deep/,
# so that via/.. is elsewhere/ to the system and to uv, and vvadir/ by name.
# vvadot/.venv/ is where vva -p 3.13 has uv make one. Each activate script
# sets VIRTUAL_ENV to its own venv.
for v in vvadir/myenv vvadir/elsewhere/myenv vvadot/.venv; do
    mkdir -p "$R/$v/bin"
    printf 'VIRTUAL_ENV=%s/%s; export VIRTUAL_ENV\n' "$R" "$v" > "$R/$v/bin/activate"
    printf '$env:VIRTUAL_ENV = "%s/%s"\n' "$R" "$v" > "$R/$v/bin/Activate.ps1"
    printf 'version_info = 3.13.1\n' > "$R/$v/pyvenv.cfg"
done
mkdir -p "$R/vvadir/elsewhere/deep"
ln -s elsewhere/deep "$R/vvadir/via"
# vvaplant/ is a tree that came in an archive: a pyproject.toml, beside which
# vva says to pick a python with --python, and a directory named after that
# option, and one after -p, each with activate scripts vva must never run.
mkdir -p "$R/vvaplant/--python/bin" "$R/vvaplant/-p/bin"
: > "$R/vvaplant/pyproject.toml"
for d in --python -p; do
    printf 'echo PLANTED%s\n' "$d" > "$R/vvaplant/$d/bin/activate"
    printf "'PLANTED%s'\n" "$d" > "$R/vvaplant/$d/bin/Activate.ps1"
done
# Your own uv settings, which pip, vv and vva have uv read in place of a
# uv.toml or pyproject.toml here or above (--config-file): a user uv.toml in
# an XDG_CONFIG_HOME (uvuser/), one in a HOME's .config (uvhome/), which uv
# reads when XDG_CONFIG_HOME is not absolute, and a system one in the second
# directory of an XDG_CONFIG_DIRS (uvsys/b/), the first having none. uvrel/
# holds a cfg/uv/uv.toml and a sys/uv/uv.toml, where a relative XDG_CONFIG_HOME
# or XDG_CONFIG_DIRS entry (cfg, sys) would find them, as a clone can ship
# them: uv takes no such XDG_CONFIG_HOME, and den no such entry, which uv reads
# from the current directory.
UVU="$R/uvuser"
UVH="$R/uvhome"
mkdir -p "$UVU/uv" "$UVH/.config/uv" "$R/uvsys/a" "$R/uvsys/b/uv" "$R/uvrel/cfg/uv" "$R/uvrel/sys/uv"
: > "$UVU/uv/uv.toml"
: > "$UVH/.config/uv/uv.toml"
: > "$R/uvsys/b/uv/uv.toml"
: > "$R/uvrel/cfg/uv/uv.toml"
: > "$R/uvrel/sys/uv/uv.toml"
# uv's last place for a system uv.toml, which this suite cannot make or move.
ETC_UV=""
[ -f /etc/uv/uv.toml ] && ETC_UV=/etc/uv/uv.toml

# route_posix <shell> <dir> <command> - run the command in <dir> with python.sh
# loaded, ROUTE_BIN first on PATH and no venv active; print its stdout and then
# "rc=<status>". Its stderr goes to $R/err, and ROUTE_LOG starts empty. A run
# that does not end is stopped after 120 s (ROUTE_TIMEOUT), and fails its check.
ROUTE_TIMEOUT=""
command -v timeout >/dev/null 2>&1 && ROUTE_TIMEOUT="timeout 120"
route_posix() {
    : > "$ROUTE_LOG"
    $ROUTE_TIMEOUT "$1" -c "export PATH='$ROUTE_BIN':\$PATH; . '$PYTHON_SH_SOURCE'; unset VIRTUAL_ENV _DEN_VENV_PYTHON; cd '$2' || exit 99; $3; echo \"rc=\$?\"" \
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

    echo "[$sh] python below a uv.toml: the same"
    actual=$(route_posix "$sh" "$R/uvtoml/sub" "python -c pass")
    assert_eq "$sh/python below a uv.toml runs the system python" "system-python -c pass
rc=0" "$actual"
    assert_eq "$sh/python below a uv.toml names it" \
        "python: running $R/sys/python3, not uv run: uv run would build or run code from $RP/uvtoml/uv.toml" "$(cat "$R/err")"

    echo "[$sh] python3 below a .python-version that names a path, and py beside one with a \\ in it: the same"
    actual=$(route_posix "$sh" "$R/pyver/sub" "python3 -c pass")
    assert_eq "$sh/python3 below a .python-version that names a path runs the system python" "system-python -c pass
rc=0" "$actual"
    assert_eq "$sh/python3 below a .python-version that names a path names it" \
        "python3: running $R/sys/python3, not uv run: uv run would build or run code from $RP/pyver/.python-version" "$(cat "$R/err")"
    actual=$(route_posix "$sh" "$R/pyverbs" "py -c pass")
    assert_eq "$sh/py beside a .python-version with a \\ path runs the system python" "system-python -c pass
rc=0" "$actual"
    assert_contains "$sh/py beside a .python-version with a \\ path names it" "code from $RP/pyverbs/.python-version" "$(cat "$R/err")"

    echo "[$sh] python below a .python-versions that names a path: the same"
    actual=$(route_posix "$sh" "$R/pyvers/sub" "python -c pass")
    assert_eq "$sh/python below a .python-versions that names a path runs the system python" "system-python -c pass
rc=0" "$actual"
    assert_eq "$sh/python below a .python-versions that names a path names it" \
        "python: running $R/sys/python3, not uv run: uv run would build or run code from $RP/pyvers/.python-versions" "$(cat "$R/err")"

    echo "[$sh] beside a .python-version whose path line starts with U+200B, or a byte order mark, and then #: the same"
    for c in pyverzw pyverbom; do
        actual=$(route_posix "$sh" "$R/$c" "python -c pass")
        assert_eq "$sh/python beside $c's .python-version runs the system python" "system-python -c pass
rc=0" "$actual"
        assert_eq "$sh/python beside $c's .python-version names it" \
            "python: running $R/sys/python3, not uv run: uv run would build or run code from $RP/$c/.python-version" "$(cat "$R/err")"
    done

    echo "[$sh] beside a .python-version whose line names a directory here, with no / in it: the same"
    actual=$(route_posix "$sh" "$R/pyverdir" "python -c pass")
    assert_eq "$sh/python beside a .python-version that names a directory here runs the system python" "system-python -c pass
rc=0" "$actual"
    assert_eq "$sh/python beside a .python-version that names a directory here names it" \
        "python: running $R/sys/python3, not uv run: uv run would build or run code from $RP/pyverdir/.python-version" "$(cat "$R/err")"
    echo "[$sh] below it, the name counts where the current directory holds it, as uv looks it up there"
    actual=$(route_posix "$sh" "$R/pyverdir/sub2" "python3 -c pass")
    assert_eq "$sh/python3 below that .python-version, in a directory that holds the name too, runs the system python" "system-python -c pass
rc=0" "$actual"
    assert_eq "$sh/python3 below that .python-version, in a directory that holds the name too, names it" \
        "python3: running $R/sys/python3, not uv run: uv run would build or run code from $RP/pyverdir/.python-version" "$(cat "$R/err")"
    actual=$(route_posix "$sh" "$R/pyverdir/sub" "python3 -c pass")
    assert_eq "$sh/python3 below that .python-version, in a directory that does not hold the name, goes through uv run" "mock-uv run -- python -c pass
rc=0" "$actual"

    echo "[$sh] the name padded with Unicode white space, a version request that names a directory here, a line over 128 characters, a 65th line: the same"
    for c in pyverpad pyver313 pyverlong pyvermany; do
        actual=$(route_posix "$sh" "$R/$c" "python -c pass")
        assert_eq "$sh/python beside $c's .python-version runs the system python" "system-python -c pass
rc=0" "$actual"
        assert_eq "$sh/python beside $c's .python-version names it" \
            "python: running $R/sys/python3, not uv run: uv run would build or run code from $RP/$c/.python-version" "$(cat "$R/err")"
    done

    echo "[$sh] beside a .python-version of version requests alone, a path only in a comment: uv run, as before"
    actual=$(route_posix "$sh" "$R/pyveronly" "python -c pass")
    assert_eq "$sh/python beside a version-only .python-version goes through uv run" "mock-uv run -- python -c pass
rc=0" "$actual"

    echo "[$sh] beside a .python-version that links to /dev/zero: uv run, and python ends"
    actual=$(route_posix "$sh" "$R/pyverzero" "python -c pass")
    assert_eq "$sh/python beside a .python-version that links to /dev/zero goes through uv run" "mock-uv run -- python -c pass
rc=0" "$actual"

    echo "[$sh] py through a symbolic link into a project still finds the project"
    actual=$(route_posix "$sh" "$R/link" "py -c pass")
    assert_eq "$sh/py through a link runs the system python" "system-python -c pass
rc=0" "$actual"
    assert_contains "$sh/py through a link names the project" "code from $RP/proj/pyproject.toml" "$(cat "$R/err")"

    # A pwd function of yours replaced the one the walk asks where it starts,
    # and here named a directory with no marker: python went through uv run
    # and vv ran plain uv venv in a project.
    echo "[$sh] python and vv in a project past a pwd function that names another directory: the walk starts here"
    actual=$(route_posix "$sh" "$R/proj/sub" "pwd() { printf '%s\n' '$NOPROJ'; }; python -c pass; vv")
    assert_eq "$sh/python and vv past a pwd function find the project" "system-python -c pass
mock-uv --no-config venv
rc=0" "$actual"
    assert_eq "$sh/python and vv past a pwd function name the project" "python: running $R/sys/python3, not uv run: uv run would build or run code from $RP/proj/pyproject.toml
vv: uv --no-config venv, as $RP/proj/pyproject.toml is here or above ($VV_NONE)" "$(cat "$R/err")"

    echo "[$sh] python --version in a directory whose name ends in a newline, beside a .python-version that names ./evil: the system python"
    actual=$(route_posix "$sh" "$NLD" "python --version")
    assert_eq "$sh/python in a directory whose name ends in a newline runs the system python" "system-python --version
rc=0" "$actual"
    assert_eq "$sh/python in a directory whose name ends in a newline names its .python-version" \
        "python: running $R/sys/python3, not uv run: uv run would build or run code from $RP/pyvernl$NL/.python-version" "$(cat "$R/err")"

    echo "[$sh] --version and -V outside a project: uv run, as any other call"
    actual=$(route_posix "$sh" "$NOPROJ" "py --version; python -V")
    assert_eq "$sh/--version and -V outside a project go through uv run" "mock-uv run -- python --version
mock-uv run -- python -V
rc=0" "$actual"
    assert_eq "$sh/--version and -V outside a project say so" "py --version → uv run -- python --version
python -V → uv run -- python -V" "$(cat "$R/err")"

    echo "[$sh] --version in a project: the system python, after the line"
    actual=$(route_posix "$sh" "$R/proj/sub" "python --version")
    assert_eq "$sh/--version in a project runs the system python" "system-python --version
rc=0" "$actual"
    assert_eq "$sh/--version in a project says so" \
        "python: running $R/sys/python3, not uv run: uv run would build or run code from $RP/proj/pyproject.toml" "$(cat "$R/err")"

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

    echo "[$sh] in a venv va activated, in a project: the venv's python, not uv run --python, and no line, as on cmd"
    actual=$(route_posix "$sh" "$R/proj" "export VIRTUAL_ENV='$R/venv' _DEN_VENV_PYTHON=3.12; python -c pass")
    assert_eq "$sh/python in a venv in a project runs the venv's python" "venv-python -c pass
rc=0" "$actual"
    assert_eq "$sh/python in a venv in a project prints no line" "" "$(cat "$R/err")"
    actual=$(route_posix "$sh" "$R/proj" "export VIRTUAL_ENV='$R/nopyvenv' _DEN_VENV_PYTHON=3.12; python -c pass")
    assert_eq "$sh/python in a venv with no python of its own, in a project, runs the system python" "system-python -c pass
rc=0" "$actual"
    assert_eq "$sh/python in a venv with no python of its own, in a project, says so" \
        "python: running $R/sys/python3, not uv run: uv run would build or run code from $RP/proj/pyproject.toml" "$(cat "$R/err")"
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

    # uv venv runs the program a .python-version names, and a uv.toml's settings
    # can have it install and run a python the clone ships, --python given or
    # not (see the real-uv checks): where python runs a python directly, vv and
    # vva add --no-config, also with the overrides off.
    echo "[$sh] vv in a project, and below a uv.toml with --python or -p: uv --no-config venv, and a line that says so"
    actual=$(route_posix "$sh" "$R/proj/sub" "vv; vv --python 3.13 myenv")
    assert_eq "$sh/vv in a project runs uv --no-config venv" "mock-uv --no-config venv
mock-uv --no-config venv --python 3.13 myenv
rc=0" "$actual"
    assert_eq "$sh/vv in a project says so" "vv: uv --no-config venv, as $RP/proj/pyproject.toml is here or above ($VV_NONE)
vv: uv --no-config venv, as $RP/proj/pyproject.toml is here or above ($VV_NONE)" "$(cat "$R/err")"
    actual=$(route_posix "$sh" "$R/uvtoml/sub" "vv -p 3.13")
    assert_eq "$sh/vv -p below a uv.toml runs uv --no-config venv" "mock-uv --no-config venv -p 3.13
rc=0" "$actual"
    assert_eq "$sh/vv -p below a uv.toml says so" "vv: uv --no-config venv, as $RP/uvtoml/uv.toml is here or above ($VV_NONE)" "$(cat "$R/err")"

    echo "[$sh] vva below a .python-version that names a path: uv --no-config venv, then va"
    route_posix "$sh" "$R/pyver/sub" "vva" >/dev/null
    assert_eq "$sh/vva below a .python-version that names a path runs uv --no-config venv" "--no-config venv .venv" "$(cat "$ROUTE_LOG")"
    assert_eq "$sh/vva below a .python-version that names a path says so, then va runs" "vva: uv --no-config venv, as $RP/pyver/.python-version is here or above ($VV_NONE)
activate script not found: .venv/bin/activate" "$(cat "$R/err")"

    echo "[$sh] vv with the overrides off: still uv --no-config venv in a project"
    actual=$(route_posix "$sh" "$R/proj" "toggle-uv >/dev/null; vv")
    assert_eq "$sh/vv with toggle-uv off runs uv --no-config venv" "mock-uv --no-config venv
rc=0" "$actual"
    assert_eq "$sh/vv with toggle-uv off says so" "vv: uv --no-config venv, as $RP/proj/pyproject.toml is here or above ($VV_NONE)" "$(cat "$R/err")"

    echo "[$sh] vv and vva outside a project, and beside a .python-version of version requests alone: uv venv, as before"
    actual=$(route_posix "$sh" "$NOPROJ" "vv; vva myenv")
    assert_eq "$sh/vv and vva outside a project run uv venv" "mock-uv venv
mock-uv venv myenv
rc=1" "$actual"
    assert_eq "$sh/vv and vva outside a project print no line but va's" "activate script not found: myenv/bin/activate" "$(cat "$R/err")"
    actual=$(route_posix "$sh" "$R/pyveronly" "vv")
    assert_eq "$sh/vv beside a version-only .python-version runs uv venv" "mock-uv venv
rc=0" "$actual"
    assert_eq "$sh/vv beside a version-only .python-version prints no line" "" "$(cat "$R/err")"

    # The walk fails where it finds no marker, and vv assigned what it printed
    # plainly: under set -e the shell ended there, and uv venv never ran.
    echo "[$sh] vv under set -e, with no marker here or where --directory points: uv venv, and the shell goes on"
    actual=$(route_posix "$sh" "$NOPROJ" "set -e; vv; vv --directory '$NOPROJ' v; echo after") || true
    assert_eq "$sh/vv under set -e with no marker runs uv venv" "mock-uv venv
mock-uv venv --directory $NOPROJ v
after
rc=0" "$actual"
    assert_eq "$sh/vv under set -e with no marker prints no line" "" "$(cat "$R/err")"
    # vva runs va, whose git fails outside a checkout, and va assigned git's
    # message plainly to name a failure it then found none of.
    echo "[$sh] vva under set -e, outside a git checkout: uv venv, then va activates, and the shell goes on"
    actual=$(route_posix "$sh" "$R/sete" "set -e; vva myenv; echo \"after VE=[\${VIRTUAL_ENV#'$R/'}] PY=[\$_DEN_VENV_PYTHON]\"") || true
    assert_eq "$sh/vva under set -e outside a checkout activates the venv" "mock-uv venv myenv
after VE=[sete/myenv] PY=[3.13.1]
rc=0" "$actual"
    assert_eq "$sh/vva under set -e outside a checkout prints no line" "" "$(cat "$R/err")"

    # uv venv first enters the directory --directory (else UV_WORKING_DIR,
    # else UV_WORKING_DIRECTORY) names and reads from there; --project (else
    # UV_PROJECT) moves its walk alone, to that directory taken from the one
    # uv runs in by name, or to the directory of a pyproject.toml it names,
    # and uv still looks a .python-version's bare name up where it runs (the
    # real-uv checks run uv so). vv and vva walked from here alone, so from a
    # directory with no marker they ran plain uv venv at a clone.
    echo "[$sh] vv and vva with --directory, from a directory with no marker: uv --no-config venv, as the walk starts there"
    actual=$(route_posix "$sh" "$NOPROJ" "vv --directory '$R/pyver'; vv --directory=../route/pyverdir v; vva myenv --directory '$R/uvtoml/sub'")
    assert_eq "$sh/vv and vva with --directory run uv --no-config venv" "mock-uv --no-config venv --directory $R/pyver
mock-uv --no-config venv --directory=../route/pyverdir v
mock-uv --no-config venv myenv --directory $R/uvtoml/sub
rc=1" "$actual"
    assert_eq "$sh/vv and vva with --directory name what they found there" "vv: uv --no-config venv, as $RP/pyver/.python-version is in or above $RP/pyver ($VV_NONE_THERE)
vv: uv --no-config venv, as $RP/pyverdir/.python-version is in or above $RP/pyverdir ($VV_NONE_THERE)
vva: uv --no-config venv, as $RP/uvtoml/uv.toml is in or above $RP/uvtoml/sub ($VV_NONE_THERE)
activate script not found: $R/uvtoml/sub/myenv/bin/activate" "$(cat "$R/err")"

    echo "[$sh] vv with UV_WORKING_DIR, UV_WORKING_DIRECTORY or UV_PROJECT, as uv ranks them and --directory: the same"
    actual=$(route_posix "$sh" "$NOPROJ" "
        export UV_WORKING_DIR='$R/pyver'; vv
        unset UV_WORKING_DIR; export UV_WORKING_DIRECTORY='$R/pyver'; vv
        export UV_WORKING_DIR='$NOPROJ'; vv; vv --directory '$R/pyver'
        unset UV_WORKING_DIR UV_WORKING_DIRECTORY; export UV_PROJECT='$R/proj/sub'; vv
        export XDG_CONFIG_HOME='$UVU'; vv")
    assert_eq "$sh/vv with UV_WORKING_DIR, UV_WORKING_DIRECTORY or UV_PROJECT runs uv --no-config venv" "mock-uv --no-config venv
mock-uv --no-config venv
mock-uv venv
mock-uv --no-config venv --directory $R/pyver
mock-uv --no-config venv
mock-uv --no-config --config-file $UVU/uv/uv.toml venv
rc=0" "$actual"
    assert_eq "$sh/vv with UV_WORKING_DIR, UV_WORKING_DIRECTORY or UV_PROJECT names what it found there" "vv: uv --no-config venv, as $RP/pyver/.python-version is in or above $RP/pyver ($VV_NONE_THERE)
vv: uv --no-config venv, as $RP/pyver/.python-version is in or above $RP/pyver ($VV_NONE_THERE)
vv: uv --no-config venv, as $RP/pyver/.python-version is in or above $RP/pyver ($VV_NONE_THERE)
vv: uv --no-config venv, as $R/proj/pyproject.toml is in or above $R/proj/sub ($VV_NONE_THERE)
vv: uv --no-config --config-file $UVU/uv/uv.toml venv, as $R/proj/pyproject.toml is in or above $R/proj/sub ($VV_KEEPS_THERE)" "$(cat "$R/err")"

    # uv run, too, reads from where UV_WORKING_DIR, UV_WORKING_DIRECTORY or
    # UV_PROJECT moves it. python, python3 and py walked from here alone, so
    # from a directory with no marker they ran uv run at a clone (the real-uv
    # checks show it build one). Where uv cannot enter the directory, it stops
    # before it reads anything.
    echo "[$sh] python, python3 and py with UV_WORKING_DIR, UV_WORKING_DIRECTORY or UV_PROJECT at a project, from a directory with no marker: the system python, not uv run"
    actual=$(route_posix "$sh" "$NOPROJ" "
        export UV_WORKING_DIR='$R/pyver'; python -c 1
        unset UV_WORKING_DIR; export UV_WORKING_DIRECTORY='$R/uvtoml/sub'; python3 -c 2
        unset UV_WORKING_DIRECTORY; export UV_PROJECT='$R/proj/sub'; py -c 3
        export UV_PROJECT=../route/proj; python -c 4
        export UV_PROJECT='$NOPROJ'; python -c 5
        unset UV_PROJECT; export UV_WORKING_DIR='$R/nope'; python -c 6
        export VIRTUAL_ENV='$R/venv' _DEN_VENV_PYTHON=3.12 UV_WORKING_DIR='$R/proj'; python -c 7")
    assert_eq "$sh/python, python3 and py with UV_WORKING_DIR, UV_WORKING_DIRECTORY or UV_PROJECT at a project run the system python" "system-python -c 1
system-python -c 2
system-python -c 3
system-python -c 4
mock-uv run -- python -c 5
mock-uv run -- python -c 6
venv-python -c 7
rc=0" "$actual"
    assert_eq "$sh/python, python3 and py with UV_WORKING_DIR, UV_WORKING_DIRECTORY or UV_PROJECT at a project name what they found there" "python: running $R/sys/python3, not uv run: uv run would build or run code from $RP/pyver/.python-version
python3: running $R/sys/python3, not uv run: uv run would build or run code from $RP/uvtoml/uv.toml
py: running $R/sys/python3, not uv run: uv run would build or run code from $R/proj/pyproject.toml
python: running $R/sys/python3, not uv run: uv run would build or run code from $RP/proj/pyproject.toml
python -c 5 → uv run -- python -c 5
python -c 6 → uv run -- python -c 6" "$(cat "$R/err")"

    # vva took its first argument for the venv's name, an option too, and
    # the name from here where uv made the venv elsewhere: it activated
    # another venv than the one uv made, or ran a --python/bin/activate.
    echo "[$sh] vva hands uv venv the name it activates, and activates it where uv made it"
    actual=$(route_posix "$sh" "$R/vvadir" "
        vva myenv --directory elsewhere; echo \"VE=[\${VIRTUAL_ENV#'$R/'}]\"
        export UV_WORKING_DIR=elsewhere; vva myenv; echo \"VE=[\${VIRTUAL_ENV#'$R/'}]\"
        unset UV_WORKING_DIR; export UV_WORKING_DIRECTORY='$R/vvadir/elsewhere'; vva myenv --python 3.13; echo \"VE=[\${VIRTUAL_ENV#'$R/'}]\"
        unset UV_WORKING_DIRECTORY; vva myenv --directory=via/..; echo \"VE=[\${VIRTUAL_ENV#'$R/'}]\"
        vva '$R/vvadir/myenv' --directory elsewhere; echo \"VE=[\${VIRTUAL_ENV#'$R/'}]\"")
    assert_eq "$sh/vva activates the venv uv made, not one of the same name here" "mock-uv venv myenv --directory elsewhere
VE=[vvadir/elsewhere/myenv]
mock-uv venv myenv
VE=[vvadir/elsewhere/myenv]
mock-uv venv myenv --python 3.13
VE=[vvadir/elsewhere/myenv]
mock-uv venv myenv --directory=via/..
VE=[vvadir/elsewhere/myenv]
mock-uv venv $R/vvadir/myenv --directory elsewhere
VE=[vvadir/myenv]
rc=0" "$actual"
    assert_eq "$sh/vva activates the venv uv made, and prints no line" "" "$(cat "$R/err")"
    actual=$(route_posix "$sh" "$R/vvadot" "vva -p 3.13; echo \"VE=[\${VIRTUAL_ENV#'$R/'}]\"")
    assert_eq "$sh/vva with an option first activates the .venv it names to uv" "mock-uv --no-config venv .venv -p 3.13
VE=[vvadot/.venv]
rc=0" "$actual"

    echo "[$sh] vva with an option first, in a tree with a --python/ and a -p/: runs no activate script there"
    actual=$(route_posix "$sh" "$R/vvaplant" "vva --python 3.13; vva -p 3.13")
    assert_eq "$sh/vva with an option first names .venv to uv" "mock-uv --no-config venv .venv --python 3.13
mock-uv --no-config venv .venv -p 3.13
rc=1" "$actual"
    assert_not_contains "$sh/vva with an option first runs no --python/bin/activate or -p/bin/activate" "PLANTED" "$actual$(cat "$R/err")"

    # link/ is proj/sub/ under another name: from the directory uv runs in,
    # .. is proj/, and by name link/.. is the route directory, which holds
    # no marker. pyverdir/.python-version names tools, which its sub2/ holds
    # and the directory with no marker does not.
    echo "[$sh] vv with --project: the walk starts there, as uv takes it, and a bare name is looked up where uv runs"
    actual=$(route_posix "$sh" "$NOPROJ" "
        vv --project ../route/proj/pyproject.toml
        vv --directory '$R/link' --project ..
        vv --project '$R/link/..'
        vv --directory '$R/pyverdir/sub2' --project ..
        vv --project '$R/pyverdir'")
    assert_eq "$sh/vv with --project runs uv --no-config venv where uv would read a marker" "mock-uv --no-config venv --project ../route/proj/pyproject.toml
mock-uv --no-config venv --directory $R/link --project ..
mock-uv venv --project $R/link/..
mock-uv --no-config venv --directory $R/pyverdir/sub2 --project ..
mock-uv venv --project $R/pyverdir
rc=0" "$actual"
    assert_eq "$sh/vv with --project names what it found there" "vv: uv --no-config venv, as $RP/proj/pyproject.toml is in or above $RP/proj ($VV_NONE_THERE)
vv: uv --no-config venv, as $RP/proj/pyproject.toml is in or above $RP/proj ($VV_NONE_THERE)
vv: uv --no-config venv, as $RP/pyverdir/.python-version is in or above $RP/pyverdir ($VV_NONE_THERE)" "$(cat "$R/err")"

    # uv enters --directory as the system does: through each link, a .. after
    # one going up from where it led. By name, link/.. and deep/a/up/.. are
    # the route directory and deep/a/, which hold no marker; loop/ is never
    # entered.
    echo "[$sh] vv --directory through symbolic links, and from inside one: the walk starts where the system takes uv"
    actual=$(route_posix "$sh" "$NOPROJ" "
        vv --directory '$R/link/..'
        vv --directory '$R/rlink/..'
        vv --directory '$R/deep/a/up/..'
        vv --directory '$R/loop'
        cd '$R/link'; vv --directory ..")
    assert_eq "$sh/vv --directory through links runs uv --no-config venv where the system takes uv" "mock-uv --no-config venv --directory $R/link/..
mock-uv --no-config venv --directory $R/rlink/..
mock-uv --no-config venv --directory $R/deep/a/up/..
mock-uv venv --directory $R/loop
mock-uv --no-config venv --directory ..
rc=0" "$actual"
    assert_eq "$sh/vv --directory through links names what it found there" "vv: uv --no-config venv, as $RP/proj/pyproject.toml is in or above $RP/proj ($VV_NONE_THERE)
vv: uv --no-config venv, as $RP/proj/pyproject.toml is in or above $RP/proj ($VV_NONE_THERE)
vv: uv --no-config venv, as $RP/proj/pyproject.toml is in or above $RP/proj ($VV_NONE_THERE)
vv: uv --no-config venv, as $RP/proj/pyproject.toml is in or above $RP/proj ($VV_NONE_THERE)" "$(cat "$R/err")"

    # The cd function and the chpwd hook write to a file: vv's cd sends what
    # it prints to /dev/null.
    echo "[$sh] vv after a --, and at a directory that is not there from here: uv venv as typed; its cd runs no cd function, chpwd hook or CDPATH entry"
    rm -f "$R/hooks"
    actual=$(route_posix "$sh" "$NOPROJ" "
        cd() { echo cd-function >> '$R/hooks'; }; chpwd() { echo chpwd-hook >> '$R/hooks'; }; export CDPATH='$R'
        vv -- --directory '$R/pyver'
        vv --directory pyver
        vv --directory '$R/pyver'")
    assert_eq "$sh/vv after a -- or at a directory not there runs uv venv" "mock-uv venv -- --directory $R/pyver
mock-uv venv --directory pyver
mock-uv --no-config venv --directory $R/pyver
rc=0" "$actual"
    assert_eq "$sh/vv after a -- or at a directory not there prints no line" "vv: uv --no-config venv, as $RP/pyver/.python-version is in or above $RP/pyver ($VV_NONE_THERE)" "$(cat "$R/err")"
    assert_not_exists "$sh/vv's cd runs no cd function or chpwd hook" "$R/hooks"

    echo "[$sh] vv --directory at a directory whose name ends in a newline, from directories with no marker: uv --no-config venv, as the walk starts there"
    actual=$(route_posix "$sh" "$R" "vv --directory 'pyvernl$NL' v; vv --directory='$NLD'")
    assert_eq "$sh/vv at a directory whose name ends in a newline runs uv --no-config venv" "mock-uv --no-config venv --directory pyvernl$NL v
mock-uv --no-config venv --directory=$NLD
rc=0" "$actual"
    assert_eq "$sh/vv at a directory whose name ends in a newline names what it found there" "vv: uv --no-config venv, as $RP/pyvernl$NL/.python-version is in or above $RP/pyvernl$NL ($VV_NONE_THERE)
vv: uv --no-config venv, as $RP/pyvernl$NL/.python-version is in or above $RP/pyvernl$NL ($VV_NONE_THERE)" "$(cat "$R/err")"

    # --no-config skipped your own uv settings too (an index, TLS settings):
    # with a uv.toml of yours, uv --config-file reads it in place of a
    # uv.toml or pyproject.toml here or above, as uv pip does not need
    # --no-config for that; uv venv does, to read no .python-version.
    echo "[$sh] pip and pip3 in a venv without pip, with a uv.toml of yours: uv --config-file it, and a line that says so"
    actual=$(route_posix "$sh" "$R/proj" "export VIRTUAL_ENV='$WORK/venv_nopip' XDG_CONFIG_HOME='$UVU'; pip install foo; pip3 list")
    assert_eq "$sh/pip and pip3 with a uv.toml of yours run uv --config-file it" "mock-uv --config-file $UVU/uv/uv.toml pip install foo
mock-uv --config-file $UVU/uv/uv.toml pip list
rc=0" "$actual"
    assert_eq "$sh/pip and pip3 with a uv.toml of yours say so" "pip install foo → uv --config-file $UVU/uv/uv.toml pip install foo ($PIP_KEEPS)
pip3 list → uv --config-file $UVU/uv/uv.toml pip list ($PIP_KEEPS)" "$(cat "$R/err")"

    echo "[$sh] vv and vva in a project, with a uv.toml of yours: uv --no-config --config-file it, also with the overrides off"
    actual=$(route_posix "$sh" "$R/proj/sub" "export XDG_CONFIG_HOME='$UVU'; vv -p 3.13; toggle-uv >/dev/null; vva")
    assert_eq "$sh/vv and vva in a project with a uv.toml of yours run uv --no-config --config-file it" "mock-uv --no-config --config-file $UVU/uv/uv.toml venv -p 3.13
mock-uv --no-config --config-file $UVU/uv/uv.toml venv .venv
rc=1" "$actual"
    assert_eq "$sh/vv and vva in a project with a uv.toml of yours say so" "vv: uv --no-config --config-file $UVU/uv/uv.toml venv, as $RP/proj/pyproject.toml is here or above ($VV_KEEPS)
vva: uv --no-config --config-file $UVU/uv/uv.toml venv, as $RP/proj/pyproject.toml is here or above ($VV_KEEPS)
activate script not found: .venv/bin/activate" "$(cat "$R/err")"

    echo "[$sh] the uv.toml they read is the one uv reads besides a project's"
    actual=$(route_posix "$sh" "$R/uvrel" "
        export XDG_CONFIG_HOME='$UVU'; echo \"user=[\$(_den_uv_config)]\"
        export XDG_CONFIG_HOME=cfg HOME='$UVH'; echo \"relative XDG_CONFIG_HOME=[\$(_den_uv_config)]\"
        export XDG_CONFIG_HOME='$UVU' UV_NO_CONFIG=True; echo \"UV_NO_CONFIG=[\$(_den_uv_config)]\"
        export UV_CONFIG_FILE='$R/mine.toml'; echo \"UV_CONFIG_FILE=[\$(_den_uv_config)]\"
        unset UV_CONFIG_FILE UV_NO_CONFIG UV_NO_SYSTEM_CONFIG
        export XDG_CONFIG_DIRS='sys:$R/uvsys/a::$R/uvsys/b'
        echo \"user and system=[\$(_den_uv_config)]\"
        export XDG_CONFIG_HOME='$R/uvsys/a'; echo \"system=[\$(_den_uv_config)]\"
        export UV_NO_SYSTEM_CONFIG=yes; echo \"UV_NO_SYSTEM_CONFIG=[\$(_den_uv_config)]\"
        export UV_NO_SYSTEM_CONFIG=0 XDG_CONFIG_DIRS=sys; echo \"relative XDG_CONFIG_DIRS=[\$(_den_uv_config)]\"")
    assert_eq "$sh/_den_uv_config: your uv.toml, as uv finds it" "user=[$UVU/uv/uv.toml]
relative XDG_CONFIG_HOME=[$UVH/.config/uv/uv.toml]
UV_NO_CONFIG=[]
UV_CONFIG_FILE=[$R/mine.toml]
user and system=[$UVU/uv/uv.toml]
system=[$R/uvsys/b/uv/uv.toml]
UV_NO_SYSTEM_CONFIG=[]
relative XDG_CONFIG_DIRS=[$ETC_UV]
rc=0" "$actual"
    actual=$(route_posix "$sh" "$R/proj" "export VIRTUAL_ENV='$WORK/venv_nopip' XDG_CONFIG_HOME='$UVU' UV_NO_CONFIG=on; pip list")
    assert_eq "$sh/pip with UV_NO_CONFIG true runs uv --no-config pip" "mock-uv --no-config pip list
rc=0" "$actual"
    assert_eq "$sh/pip with UV_NO_CONFIG true says it reads no uv.toml" "pip list → uv --no-config pip list ($PIP_NONE)" "$(cat "$R/err")"

    # uv reads the file UV_CONFIG_FILE names as it is, a newline at its end
    # too; $( ) dropped it, and pip, pip3 and vv named uv another file.
    echo "[$sh] pip, pip3 and vv with a UV_CONFIG_FILE whose name ends in a newline: uv --config-file that file"
    actual=$(route_posix "$sh" "$R/proj" "export VIRTUAL_ENV='$WORK/venv_nopip' UV_CONFIG_FILE='$R/mine.toml$NL'; pip list; pip3 list; vv")
    assert_eq "$sh/pip, pip3 and vv pass a UV_CONFIG_FILE that ends in a newline as it is" "mock-uv --config-file $R/mine.toml$NL pip list
mock-uv --config-file $R/mine.toml$NL pip list
mock-uv --no-config --config-file $R/mine.toml$NL venv
rc=0" "$actual"
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
    $ROUTE_TIMEOUT pwsh -NoProfile -NonInteractive -Command "
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

echo "[pwsh] python below a uv.toml: the same"
actual=$(route_pwsh "$R/uvtoml/sub" "python -c pass")
assert_eq "pwsh/python below a uv.toml runs the system python" "WARNING: python: running $R/sys/python3, not uv run: uv run would build or run code from $R/uvtoml/uv.toml
system-python -c pass" "$actual"

echo "[pwsh] python3 below a .python-version that names a path, and py beside one with a \\ in it: the same"
actual=$(route_pwsh "$R/pyver/sub" "python3 -c pass")
assert_eq "pwsh/python3 below a .python-version that names a path runs the system python" "WARNING: python3: running $R/sys/python3, not uv run: uv run would build or run code from $R/pyver/.python-version
system-python -c pass" "$actual"
actual=$(route_pwsh "$R/pyverbs" "py -c pass")
assert_eq "pwsh/py beside a .python-version with a \\ path runs the system python" "WARNING: py: running $R/sys/python3, not uv run: uv run would build or run code from $R/pyverbs/.python-version
system-python -c pass" "$actual"

echo "[pwsh] python below a .python-versions that names a path: the same"
actual=$(route_pwsh "$R/pyvers/sub" "python -c pass")
assert_eq "pwsh/python below a .python-versions that names a path runs the system python" "WARNING: python: running $R/sys/python3, not uv run: uv run would build or run code from $R/pyvers/.python-versions
system-python -c pass" "$actual"

echo "[pwsh] beside a .python-version whose path line starts with U+200B, or a byte order mark, and then #: the same"
for c in pyverzw pyverbom; do
    actual=$(route_pwsh "$R/$c" "python -c pass")
    assert_eq "pwsh/python beside $c's .python-version runs the system python" "WARNING: python: running $R/sys/python3, not uv run: uv run would build or run code from $R/$c/.python-version
system-python -c pass" "$actual"
done

echo "[pwsh] beside a .python-version whose line names a directory here, with no / in it: the same"
actual=$(route_pwsh "$R/pyverdir" "python -c pass")
assert_eq "pwsh/python beside a .python-version that names a directory here runs the system python" "WARNING: python: running $R/sys/python3, not uv run: uv run would build or run code from $R/pyverdir/.python-version
system-python -c pass" "$actual"
echo "[pwsh] below it, the name counts where the current directory holds it, as uv looks it up there"
actual=$(route_pwsh "$R/pyverdir/sub2" "python3 -c pass")
assert_eq "pwsh/python3 below that .python-version, in a directory that holds the name too, runs the system python" "WARNING: python3: running $R/sys/python3, not uv run: uv run would build or run code from $R/pyverdir/.python-version
system-python -c pass" "$actual"
actual=$(route_pwsh "$R/pyverdir/sub" "python3 -c pass")
assert_eq "pwsh/python3 below that .python-version, in a directory that does not hold the name, goes through uv run" "HOST: python3 -c pass → uv run -- python -c pass
mock-uv run -- python -c pass" "$actual"

echo "[pwsh] the name padded with Unicode white space, a version request that names a directory here, a line over 128 characters, a 65th line: the same"
for c in pyverpad pyver313 pyverlong pyvermany; do
    actual=$(route_pwsh "$R/$c" "python -c pass")
    assert_eq "pwsh/python beside $c's .python-version runs the system python" "WARNING: python: running $R/sys/python3, not uv run: uv run would build or run code from $R/$c/.python-version
system-python -c pass" "$actual"
done

echo "[pwsh] beside a .python-version of version requests alone, a path only in a comment: uv run, as before"
actual=$(route_pwsh "$R/pyveronly" "python -c pass")
assert_eq "pwsh/python beside a version-only .python-version goes through uv run" "HOST: python -c pass → uv run -- python -c pass
mock-uv run -- python -c pass" "$actual"

echo "[pwsh] beside a .python-version that links to /dev/zero: uv run, and python ends"
actual=$(route_pwsh "$R/pyverzero" "python -c pass")
assert_eq "pwsh/python beside a .python-version that links to /dev/zero goes through uv run" "HOST: python -c pass → uv run -- python -c pass
mock-uv run -- python -c pass" "$actual"

echo "[pwsh] --version and -V outside a project: uv run, as any other call"
actual=$(route_pwsh "$NOPROJ" "py --version; python -V")
assert_eq "pwsh/--version and -V outside a project go through uv run" "HOST: py --version → uv run -- python --version
mock-uv run -- python --version
HOST: python -V → uv run -- python -V
mock-uv run -- python -V" "$actual"

echo "[pwsh] --version in a project: the system python, after the warning"
actual=$(route_pwsh "$R/proj/sub" "python --version")
assert_eq "pwsh/--version in a project runs the system python" "WARNING: python: running $R/sys/python3, not uv run: uv run would build or run code from $R/proj/pyproject.toml
system-python --version" "$actual"

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

echo "[pwsh] in a venv va activated, in a project: the venv's python, not uv run --python, and no warning, as on cmd"
actual=$(route_pwsh "$R/proj" "\$env:VIRTUAL_ENV = '$R/venv'; \$env:_DEN_VENV_PYTHON = '3.12'; python -c pass")
assert_eq "pwsh/python in a venv in a project runs the venv's python, with no warning" "venv-python -c pass" "$actual"
actual=$(route_pwsh "$R/proj" "\$env:VIRTUAL_ENV = '$R/nopyvenv'; \$env:_DEN_VENV_PYTHON = '3.12'; python -c pass")
assert_eq "pwsh/python in a venv with no python of its own, in a project, runs the system python after the warning" "WARNING: python: running $R/sys/python3, not uv run: uv run would build or run code from $R/proj/pyproject.toml
system-python -c pass" "$actual"
actual=$(route_pwsh "$NOPROJ" "\$env:VIRTUAL_ENV = '$R/venv'; \$env:_DEN_VENV_PYTHON = '3.12'; python -c pass")
assert_eq "pwsh/python in a venv outside a project: uv run --python, as before" \
    "mock-uv run --python 3.12 -- python -c pass" "$actual"

echo "[pwsh] pip and pip3 with no venv active: nothing runs, and they say what to do"
actual=$(route_pwsh "$R/vproj" "pip install foo; pip3 list")
assert_eq "pwsh/pip and pip3 with no venv say what to do" "ERROR: no venv is active; activate one with va, or type uv pip install foo directly
ERROR: no venv is active; activate one with va, or type uv pip list directly" "$actual"
assert_eq "pwsh/pip and pip3 with no venv run no uv" "" "$(cat "$ROUTE_LOG")"

echo "[pwsh] pip and pip3 in a venv without pip: uv --no-config pip, and a line that says so"
actual=$(route_pwsh "$R/proj" "\$env:VIRTUAL_ENV = '$WORK/venv_nopip'; pip install foo; pip3 list")
assert_eq "pwsh/pip and pip3 in a venv without pip run uv --no-config pip, and say so" "HOST: pip install foo → uv --no-config pip install foo ($PIP_NONE)
mock-uv --no-config pip install foo
HOST: pip3 list → uv --no-config pip list ($PIP_NONE)
mock-uv --no-config pip list" "$actual"

echo "[pwsh] vv in a project, and below a uv.toml with --python or -p: uv --no-config venv, and a warning"
actual=$(route_pwsh "$R/proj/sub" "vv; vv --python 3.13 myenv")
assert_eq "pwsh/vv in a project runs uv --no-config venv after a warning" "WARNING: vv: uv --no-config venv, as $R/proj/pyproject.toml is here or above ($VV_NONE)
mock-uv --no-config venv
WARNING: vv: uv --no-config venv, as $R/proj/pyproject.toml is here or above ($VV_NONE)
mock-uv --no-config venv --python 3.13 myenv" "$actual"
actual=$(route_pwsh "$R/uvtoml/sub" "vv -p 3.13")
assert_eq "pwsh/vv -p below a uv.toml runs uv --no-config venv after a warning" "WARNING: vv: uv --no-config venv, as $R/uvtoml/uv.toml is here or above ($VV_NONE)
mock-uv --no-config venv -p 3.13" "$actual"

echo "[pwsh] vva below a .python-version that names a path: uv --no-config venv, then va"
actual=$(route_pwsh "$R/pyver/sub" "vva")
assert_eq "pwsh/vva below a .python-version that names a path runs uv --no-config venv after a warning, then va" "WARNING: vva: uv --no-config venv, as $R/pyver/.python-version is here or above ($VV_NONE)
mock-uv --no-config venv .venv
ERROR: activate script not found under '.venv' (Scripts/ or bin/)" "$actual"

echo "[pwsh] vv with the overrides off: still uv --no-config venv in a project"
actual=$(route_pwsh "$R/proj" "toggle-uv *>\$null; vv")
assert_eq "pwsh/vv with toggle-uv off runs uv --no-config venv after a warning" "WARNING: vv: uv --no-config venv, as $R/proj/pyproject.toml is here or above ($VV_NONE)
mock-uv --no-config venv" "$actual"

echo "[pwsh] vv outside a project, and beside a .python-version of version requests alone: uv venv, as before"
actual=$(route_pwsh "$NOPROJ" "vv")
assert_eq "pwsh/vv outside a project runs uv venv" "mock-uv venv" "$actual"
actual=$(route_pwsh "$R/pyveronly" "vv")
assert_eq "pwsh/vv beside a version-only .python-version runs uv venv" "mock-uv venv" "$actual"

# vv and vva walk from where uv venv reads, as on bash and zsh: the directory
# --directory names, read back with its symbolic links resolved, and
# --project's, taken from there by name.
echo "[pwsh] vv and vva with --directory, from a directory with no marker: uv --no-config venv, as the walk starts there"
actual=$(route_pwsh "$NOPROJ" "vv --directory '$R/pyver'; vv --directory=../route/pyverdir v; vva myenv --directory '$R/uvtoml/sub'")
assert_eq "pwsh/vv and vva with --directory run uv --no-config venv after a warning" "WARNING: vv: uv --no-config venv, as $RP/pyver/.python-version is in or above $RP/pyver ($VV_NONE_THERE)
mock-uv --no-config venv --directory $R/pyver
WARNING: vv: uv --no-config venv, as $RP/pyverdir/.python-version is in or above $RP/pyverdir ($VV_NONE_THERE)
mock-uv --no-config venv --directory=../route/pyverdir v
WARNING: vva: uv --no-config venv, as $RP/uvtoml/uv.toml is in or above $RP/uvtoml/sub ($VV_NONE_THERE)
mock-uv --no-config venv myenv --directory $R/uvtoml/sub
ERROR: activate script not found under '$RP/uvtoml/sub/myenv' (Scripts/ or bin/)" "$actual"

echo "[pwsh] vv with UV_WORKING_DIR, UV_WORKING_DIRECTORY or UV_PROJECT, as uv ranks them and --directory: the same"
actual=$(route_pwsh "$NOPROJ" "
    \$env:UV_WORKING_DIR = '$R/pyver'; vv
    Remove-Item Env:\\UV_WORKING_DIR; \$env:UV_WORKING_DIRECTORY = '$R/pyver'; vv
    \$env:UV_WORKING_DIR = '$NOPROJ'; vv; vv --directory '$R/pyver'
    Remove-Item Env:\\UV_WORKING_DIR, Env:\\UV_WORKING_DIRECTORY; \$env:UV_PROJECT = '$R/proj/sub'; vv
    \$env:XDG_CONFIG_HOME = '$UVU'; vv")
assert_eq "pwsh/vv with UV_WORKING_DIR, UV_WORKING_DIRECTORY or UV_PROJECT runs uv --no-config venv after a warning" "WARNING: vv: uv --no-config venv, as $RP/pyver/.python-version is in or above $RP/pyver ($VV_NONE_THERE)
mock-uv --no-config venv
WARNING: vv: uv --no-config venv, as $RP/pyver/.python-version is in or above $RP/pyver ($VV_NONE_THERE)
mock-uv --no-config venv
mock-uv venv
WARNING: vv: uv --no-config venv, as $RP/pyver/.python-version is in or above $RP/pyver ($VV_NONE_THERE)
mock-uv --no-config venv --directory $R/pyver
WARNING: vv: uv --no-config venv, as $R/proj/pyproject.toml is in or above $R/proj/sub ($VV_NONE_THERE)
mock-uv --no-config venv
WARNING: vv: uv --no-config --config-file $UVU/uv/uv.toml venv, as $R/proj/pyproject.toml is in or above $R/proj/sub ($VV_KEEPS_THERE)
mock-uv --no-config --config-file $UVU/uv/uv.toml venv" "$actual"

# python, python3 and py read from where uv run reads, as on bash and zsh.
echo "[pwsh] python, python3 and py with UV_WORKING_DIR, UV_WORKING_DIRECTORY or UV_PROJECT at a project, from a directory with no marker: the system python, not uv run"
actual=$(route_pwsh "$NOPROJ" "
    \$env:UV_WORKING_DIR = '$R/pyver'; python -c 1
    Remove-Item Env:\\UV_WORKING_DIR; \$env:UV_WORKING_DIRECTORY = '$R/uvtoml/sub'; python3 -c 2
    Remove-Item Env:\\UV_WORKING_DIRECTORY; \$env:UV_PROJECT = '$R/proj/sub'; py -c 3
    \$env:UV_PROJECT = '../route/proj'; python -c 4
    \$env:UV_PROJECT = '$NOPROJ'; python -c 5
    Remove-Item Env:\\UV_PROJECT; \$env:UV_WORKING_DIR = '$R/nope'; python -c 6
    \$env:VIRTUAL_ENV = '$R/venv'; \$env:_DEN_VENV_PYTHON = '3.12'; \$env:UV_WORKING_DIR = '$R/proj'; python -c 7")
assert_eq "pwsh/python, python3 and py with UV_WORKING_DIR, UV_WORKING_DIRECTORY or UV_PROJECT at a project run the system python after a warning" "WARNING: python: running $R/sys/python3, not uv run: uv run would build or run code from $RP/pyver/.python-version
system-python -c 1
WARNING: python3: running $R/sys/python3, not uv run: uv run would build or run code from $RP/uvtoml/uv.toml
system-python -c 2
WARNING: py: running $R/sys/python3, not uv run: uv run would build or run code from $R/proj/pyproject.toml
system-python -c 3
WARNING: python: running $R/sys/python3, not uv run: uv run would build or run code from $RP/proj/pyproject.toml
system-python -c 4
HOST: python -c 5 → uv run -- python -c 5
mock-uv run -- python -c 5
HOST: python -c 6 → uv run -- python -c 6
mock-uv run -- python -c 6
venv-python -c 7" "$actual"

# vva hands uv venv the name it activates, as on bash and zsh, and takes a
# relative one from where uv runs as _DenUvMarker reads it: PowerShell takes
# a .. after a link by name (via/.. would be vvadir/).
echo "[pwsh] vva hands uv venv the name it activates, and activates it where uv made it"
actual=$(route_pwsh "$R/vvadir" "
    vva myenv --directory elsewhere; \"VE=[\$(\$env:VIRTUAL_ENV -replace '^$R/')]\"
    \$env:UV_WORKING_DIR = 'elsewhere'; vva myenv; \"VE=[\$(\$env:VIRTUAL_ENV -replace '^$R/')]\"
    Remove-Item Env:\\UV_WORKING_DIR; \$env:UV_WORKING_DIRECTORY = '$R/vvadir/elsewhere'; vva myenv --python 3.13; \"VE=[\$(\$env:VIRTUAL_ENV -replace '^$R/')]\"
    Remove-Item Env:\\UV_WORKING_DIRECTORY; vva myenv --directory=via/..; \"VE=[\$(\$env:VIRTUAL_ENV -replace '^$R/')]\"
    vva '$R/vvadir/myenv' --directory elsewhere; \"VE=[\$(\$env:VIRTUAL_ENV -replace '^$R/')]\"")
assert_eq "pwsh/vva activates the venv uv made, not one of the same name here" "mock-uv venv myenv --directory elsewhere
VE=[vvadir/elsewhere/myenv]
mock-uv venv myenv
VE=[vvadir/elsewhere/myenv]
mock-uv venv myenv --python 3.13
VE=[vvadir/elsewhere/myenv]
mock-uv venv myenv --directory=via/..
VE=[vvadir/elsewhere/myenv]
mock-uv venv $R/vvadir/myenv --directory elsewhere
VE=[vvadir/myenv]" "$actual"
actual=$(route_pwsh "$R/vvadot" "vva -p 3.13 3>\$null; \"VE=[\$(\$env:VIRTUAL_ENV -replace '^$R/')]\"")
assert_eq "pwsh/vva with an option first activates the .venv it names to uv" "mock-uv --no-config venv .venv -p 3.13
VE=[vvadot/.venv]" "$actual"

echo "[pwsh] vva with an option first, in a tree with a --python/ and a -p/: dot-sources no activate script there"
actual=$(route_pwsh "$R/vvaplant" "vva --python 3.13; vva -p 3.13")
assert_not_contains "pwsh/vva with an option first dot-sources no --python/bin/Activate.ps1 or -p/bin/Activate.ps1" "PLANTED" "$actual"
assert_contains "pwsh/vva with an option first names .venv to uv" "mock-uv --no-config venv .venv -p 3.13" "$actual"

echo "[pwsh] vv with --project: the walk starts there, as uv takes it, and a bare name is looked up where uv runs"
actual=$(route_pwsh "$NOPROJ" "
    vv --project ../route/proj/pyproject.toml
    vv --directory '$R/link' --project ..
    vv --project '$R/link/..'
    vv --directory '$R/pyverdir/sub2' --project ..
    vv --project '$R/pyverdir'")
assert_eq "pwsh/vv with --project runs uv --no-config venv where uv would read a marker" "WARNING: vv: uv --no-config venv, as $RP/proj/pyproject.toml is in or above $RP/proj ($VV_NONE_THERE)
mock-uv --no-config venv --project ../route/proj/pyproject.toml
WARNING: vv: uv --no-config venv, as $RP/proj/pyproject.toml is in or above $RP/proj ($VV_NONE_THERE)
mock-uv --no-config venv --directory $R/link --project ..
mock-uv venv --project $R/link/..
WARNING: vv: uv --no-config venv, as $RP/pyverdir/.python-version is in or above $RP/pyverdir ($VV_NONE_THERE)
mock-uv --no-config venv --directory $R/pyverdir/sub2 --project ..
mock-uv venv --project $R/pyverdir" "$actual"

# vv works out where uv runs name by name, as the system enters a directory
# for it (see the same checks on bash and zsh). .NET's SetCurrentDirectory,
# which vv used, takes a path by name first: it read <link>/.. back as the
# directory that holds the link, here one with no marker.
echo "[pwsh] vv --directory through symbolic links, and from inside one: the walk starts where the system takes uv"
actual=$(route_pwsh "$NOPROJ" "
    vv --directory '$R/link/..'
    vv --directory '$R/rlink/..'
    vv --directory '$R/deep/a/up/..'
    vv --directory '$R/loop'
    Set-Location -LiteralPath '$R/link'; vv --directory ..")
assert_eq "pwsh/vv --directory through links walks where the system takes uv" "WARNING: vv: uv --no-config venv, as $RP/proj/pyproject.toml is in or above $RP/proj ($VV_NONE_THERE)
mock-uv --no-config venv --directory $R/link/..
WARNING: vv: uv --no-config venv, as $RP/proj/pyproject.toml is in or above $RP/proj ($VV_NONE_THERE)
mock-uv --no-config venv --directory $R/rlink/..
WARNING: vv: uv --no-config venv, as $RP/proj/pyproject.toml is in or above $RP/proj ($VV_NONE_THERE)
mock-uv --no-config venv --directory $R/deep/a/up/..
mock-uv venv --directory $R/loop
WARNING: vv: uv --no-config venv, as $RP/proj/pyproject.toml is in or above $RP/proj ($VV_NONE_THERE)
mock-uv --no-config venv --directory .." "$actual"

# The process's current directory is one for all its runspaces: vv set it to
# read uv's directory back, and a runspace that ran meanwhile
# (ForEach-Object -Parallel, Start-ThreadJob) found itself there. Here one
# runspace works out vv's options over and over while another watches.
echo "[pwsh] vv works out uv's directory without moving the process's, which another runspace would see"
actual=$($ROUTE_TIMEOUT pwsh -NoProfile -NonInteractive -Command "
    \$sync = [hashtable]::Synchronized(@{ Ready = \$false; Done = \$false; Moved = 0; Runs = 0 })
    1..2 | ForEach-Object -ThrottleLimit 2 -Parallel {
        \$s = \$using:sync
        \$clock = [System.Diagnostics.Stopwatch]::StartNew()
        if (\$_ -eq 1) {
            try {
                . '$PYTHON_PS1_ROUTE'
                \$WarningPreference = 'SilentlyContinue'
                Set-Location -LiteralPath '$NOPROJ'
                while (-not \$s.Ready -and \$clock.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 1 }
                for (\$i = 0; \$i -lt 100; \$i++) {
                    if (@(_DenUvVenvOptions 'vv' @('--directory', '$R/pyver')) -ccontains '--no-config') { \$s.Runs++ }
                }
            }
            finally { \$s.Done = \$true }
        }
        else {
            \$before = [System.IO.Directory]::GetCurrentDirectory()
            \$s.Ready = \$true
            while (-not \$s.Done -and \$clock.Elapsed.TotalSeconds -lt 60) {
                if ([System.IO.Directory]::GetCurrentDirectory() -ne \$before) { \$s.Moved++ }
            }
        }
    }
    \"runs=[\$(\$sync.Runs)] moved=[\$(\$sync.Moved -gt 0)]\"
" 2>&1 | tr -d '\r') || true
assert_eq "pwsh/vv leaves the process's directory alone for another runspace" "runs=[100] moved=[False]" "$actual"

# /proc/self names the process that reads it. A clone's link to
# /proc/self/cwd leads uv (started in the session's location) back into the
# clone, while this process, whose directory is elsewhere, would read its own:
# vv takes --no-config there, as for a marker.
if [ -d /proc/self ]; then
    echo "[pwsh] vv --directory through a clone's link to /proc/self/cwd takes uv --no-config venv"
    mkdir -p "$R/procrel"
    printf '3.13\n' > "$R/procrel/.python-version"
    ln -sfn /proc/self/cwd "$R/procrel/work"
    actual=$(route_pwsh "$R/procrel" "
        [System.IO.Directory]::SetCurrentDirectory('$NOPROJ')
        vv --directory work")
    assert_eq "pwsh/vv --directory through a link to /proc/self/cwd runs uv --no-config venv" "WARNING: vv: uv --no-config venv, as /proc/self is on the way there, which uv reads for its own process ($VV_NONE_THERE)
mock-uv --no-config venv --directory work" "$actual"
    # Nor can vva tell where uv made the venv there: it activates none.
    actual=$(route_pwsh "$R/procrel" "
        [System.IO.Directory]::SetCurrentDirectory('$NOPROJ')
        vva v --directory work 3>\$null")
    assert_eq "pwsh/vva --directory through a link to /proc/self/cwd activates nothing" "mock-uv --no-config venv v --directory work
ERROR: uv venv made 'v' where vva cannot tell; activate it with va <its path>" "$actual"
fi

# PowerShell drops a typed -- from $Args, so uv gets --directory as an option.
# PowerShell's location, and so its LocationChangedAction, and the process's
# current directory stay as they were.
echo "[pwsh] vv after a --, and at a directory that is not there from here; the process's directory stays"
actual=$(route_pwsh "$NOPROJ" "
    \$ExecutionContext.InvokeCommand.LocationChangedAction = { \$global:moved = 'yes' }
    \$before = [System.IO.Directory]::GetCurrentDirectory()
    vv -- --directory '$R/pyver'
    vv --directory pyver
    \"moved=[\$global:moved] kept=[\$([System.IO.Directory]::GetCurrentDirectory() -eq \$before)]\"")
assert_eq "pwsh/vv after a -- or at a directory not there, and the process's directory after" "WARNING: vv: uv --no-config venv, as $RP/pyver/.python-version is in or above $RP/pyver ($VV_NONE_THERE)
mock-uv --no-config venv --directory $R/pyver
mock-uv venv --directory pyver
moved=[] kept=[True]" "$actual"

# vv, vva and _DenUvVenvOptions are global: as well. In a session that loaded
# 8e5eeba's python.ps1, whose toggle-uv copies none of them, ON defined them
# inside itself after an update in place, and that file's vv and vva, which
# run uv venv as typed, stayed. The old files come from git, as above.
OLD_VV_DIR="$WORK/old-python-ps1-vv"
mkdir -p "$OLD_VV_DIR"
echo "[pwsh] toggle-uv OFF then ON in a session that loaded 8e5eeba's python.ps1, after an update in place: vv and vva are the updated ones"
if git -C "$DOTFILES" show "$OLD_PY_PS1_COMMIT:shell/pwsh/python.ps1" > "$OLD_VV_DIR/python.ps1" 2>/dev/null &&
    git -C "$DOTFILES" show "$OLD_PY_PS1_COMMIT:shell/pwsh/_helpers.ps1" > "$OLD_VV_DIR/_helpers.ps1" 2>/dev/null; then
    {
        echo "\$env:PATH = '$ROUTE_BIN' + [IO.Path]::PathSeparator + \$env:PATH"
        echo ". '$OLD_VV_DIR/_helpers.ps1'"
        echo ". '$OLD_VV_DIR/python.ps1'"
    } > "$OLD_VV_DIR/session.ps1"
    actual=$(run_pwsh "$OLD_VV_DIR/session.ps1" "
        $PS_SET_PROFILE
        Set-Location -LiteralPath '$R/proj'
        Copy-Item -LiteralPath '$PYTHON_PS1' -Destination '$OLD_VV_DIR/python.ps1' -Force
        toggle-uv *>\$null
        toggle-uv *>\$null
        vv 3>\$null
        vva v 3>\$null 2>\$null
    " 2>&1 | tr -d '\r') || true
    assert_eq "pwsh/vv and vva after an update from 8e5eeba's python.ps1 run uv --no-config venv in a project" "mock-uv --no-config venv
mock-uv --no-config venv v" "$actual"
else
    echo "  SKIP: pwsh/vv and vva after an update from 8e5eeba's python.ps1 (no git, or no commit $OLD_PY_PS1_COMMIT, at $DOTFILES)"
fi

# --no-config skipped your own uv settings too: with a uv.toml of yours, uv
# --config-file reads it in place of a uv.toml or pyproject.toml here or
# above, and uv venv still takes --no-config, to read no .python-version.
echo "[pwsh] pip and pip3 in a venv without pip, with a uv.toml of yours: uv --config-file it, and a line that says so"
actual=$(route_pwsh "$R/proj" "\$env:VIRTUAL_ENV = '$WORK/venv_nopip'; \$env:XDG_CONFIG_HOME = '$UVU'; pip install foo; pip3 list")
assert_eq "pwsh/pip and pip3 with a uv.toml of yours run uv --config-file it, and say so" "HOST: pip install foo → uv --config-file $UVU/uv/uv.toml pip install foo ($PIP_KEEPS)
mock-uv --config-file $UVU/uv/uv.toml pip install foo
HOST: pip3 list → uv --config-file $UVU/uv/uv.toml pip list ($PIP_KEEPS)
mock-uv --config-file $UVU/uv/uv.toml pip list" "$actual"

echo "[pwsh] vv and vva in a project, with a uv.toml of yours: uv --no-config --config-file it, also with the overrides off"
actual=$(route_pwsh "$R/proj/sub" "\$env:XDG_CONFIG_HOME = '$UVU'; vv -p 3.13; toggle-uv *>\$null; vva")
assert_eq "pwsh/vv and vva in a project with a uv.toml of yours run uv --no-config --config-file it after a warning" "WARNING: vv: uv --no-config --config-file $UVU/uv/uv.toml venv, as $R/proj/pyproject.toml is here or above ($VV_KEEPS)
mock-uv --no-config --config-file $UVU/uv/uv.toml venv -p 3.13
WARNING: vva: uv --no-config --config-file $UVU/uv/uv.toml venv, as $R/proj/pyproject.toml is here or above ($VV_KEEPS)
mock-uv --no-config --config-file $UVU/uv/uv.toml venv .venv
ERROR: activate script not found under '.venv' (Scripts/ or bin/)" "$actual"

echo "[pwsh] the uv.toml they read is the one uv reads besides a project's, on Windows too"
# On Windows, uv\uv.toml in APPDATA, else in SYSTEMDRIVE's ProgramData:
# _OnWindows stands in for Windows here, where SYSTEMDRIVE's backslash is part
# of a directory name (winsd\).
mkdir -p "$R/winsd\\/ProgramData/uv"
: > "$R/winsd\\/ProgramData/uv/uv.toml"
actual=$(route_pwsh "$R/uvrel" "
    \$env:XDG_CONFIG_HOME = '$UVU'; \"user=[\$(_DenUvConfig)]\"
    \$env:XDG_CONFIG_HOME = 'cfg'; \$env:HOME = '$UVH'; \"relative XDG_CONFIG_HOME=[\$(_DenUvConfig)]\"
    \$env:XDG_CONFIG_HOME = '$UVU'; \$env:UV_NO_CONFIG = 'True'; \"UV_NO_CONFIG=[\$(_DenUvConfig)]\"
    \$env:UV_CONFIG_FILE = '$R/mine.toml'; \"UV_CONFIG_FILE=[\$(_DenUvConfig)]\"
    Remove-Item Env:\\UV_CONFIG_FILE, Env:\\UV_NO_CONFIG, Env:\\UV_NO_SYSTEM_CONFIG
    \$env:XDG_CONFIG_DIRS = 'sys:$R/uvsys/a::$R/uvsys/b'; \"user and system=[\$(_DenUvConfig)]\"
    \$env:XDG_CONFIG_HOME = '$R/uvsys/a'; \"system=[\$(_DenUvConfig)]\"
    \$env:UV_NO_SYSTEM_CONFIG = 'yes'; \"UV_NO_SYSTEM_CONFIG=[\$(_DenUvConfig)]\"
    \$env:UV_NO_SYSTEM_CONFIG = '0'; \$env:XDG_CONFIG_DIRS = 'sys'; \"relative XDG_CONFIG_DIRS=[\$(_DenUvConfig)]\"
    function global:_OnWindows { \$true }
    \$env:APPDATA = '$UVU'; \$env:SYSTEMDRIVE = '$R/winsd'; \"Windows user=[\$(_DenUvConfig)]\"
    \$env:APPDATA = '$R/uvsys/a'; \"Windows system=[\$(_DenUvConfig)]\"
    \$env:UV_NO_SYSTEM_CONFIG = 'TRUE'; \"Windows UV_NO_SYSTEM_CONFIG=[\$(_DenUvConfig)]\"
")
assert_eq "pwsh/_DenUvConfig: your uv.toml, as uv finds it" "user=[$UVU/uv/uv.toml]
relative XDG_CONFIG_HOME=[$UVH/.config/uv/uv.toml]
UV_NO_CONFIG=[]
UV_CONFIG_FILE=[$R/mine.toml]
user and system=[$UVU/uv/uv.toml]
system=[$R/uvsys/b/uv/uv.toml]
UV_NO_SYSTEM_CONFIG=[]
relative XDG_CONFIG_DIRS=[$ETC_UV]
Windows user=[$UVU/uv/uv.toml]
Windows system=[$R/winsd\\/ProgramData/uv/uv.toml]
Windows UV_NO_SYSTEM_CONFIG=[]" "$actual"
actual=$(route_pwsh "$R/proj" "\$env:VIRTUAL_ENV = '$WORK/venv_nopip'; \$env:XDG_CONFIG_HOME = '$UVU'; \$env:UV_NO_CONFIG = 'on'; pip list")
assert_eq "pwsh/pip with UV_NO_CONFIG true runs uv --no-config pip, and says it reads no uv.toml" "HOST: pip list → uv --no-config pip list ($PIP_NONE)
mock-uv --no-config pip list" "$actual"

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

        # uv venv refuses a second name, so with an option first vva names
        # .venv to it and a name after the option fails there: nothing is made
        # and nothing activated. uv made `other`, and vva looked for an
        # --relocatable/bin/activate.
        echo "[$sh] vva with an option first: uv refuses a second name, and nothing is made or activated (the real uv)"
        rm -rf "$WORK/uv_vva_$sh"
        mkdir -p "$WORK/uv_vva_$sh"
        actual=$("$sh" -c "
            source '$PYTHON_SH_SOURCE'
            cd '$WORK/uv_vva_$sh' || exit 1
            vva --relocatable other >/dev/null 2>&1 && echo ok || echo failed
            echo \"VE=[\${VIRTUAL_ENV:-}] OTHER=[\$([ -d other ] && echo made)] VENV=[\$([ -d .venv ] && echo made)]\"
            mkdir elsewhere
            vva v --directory elsewhere >/dev/null 2>&1 || echo failed
            [ \"\$VIRTUAL_ENV\" -ef elsewhere/v ] && echo 'VE=[elsewhere/v]' || echo \"VE=[\${VIRTUAL_ENV:-}]\"
        " 2>&1 | tr -d '\r')
        assert_eq "$sh/vva with an option first makes no venv it cannot activate; with the name first it activates the one uv made" "failed
VE=[] OTHER=[] VENV=[]
VE=[elsewhere/v]" "$actual"
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

    echo "[pwsh] vva with an option first: uv refuses a second name, and nothing is made or activated (the real uv)"
    rm -rf "$WORK/uv_vva_pwsh"
    mkdir -p "$WORK/uv_vva_pwsh"
    actual=$(run_pwsh "$PYTHON_PS1_REAL_UV" "
        Set-Location '$WORK/uv_vva_pwsh'
        \$env:VIRTUAL_ENV = \$null
        vva --relocatable other *>\$null
        \"VE=[\$env:VIRTUAL_ENV] OTHER=[\$(Test-Path other)] VENV=[\$(Test-Path .venv)]\"
    " 2>&1 | tr -d '\r')
    assert_eq "pwsh/vva with an option first makes no venv it cannot activate" "VE=[] OTHER=[False] VENV=[False]" "$actual"

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

    # mk_uvtoml_clone <dir> - <dir>/uvtoml, a clone with a uv.toml at its top
    # and none of the other files: its settings have uv install a "python" the
    # clone ships and run it, whose program writes uvtoml-python to <dir>/marks.
    # A real clone names an https URL; here the download list and the archive
    # are files (file:// URLs), so it works offline.
    mk_uvtoml_clone() {
        local b="$1/uvtoml-src/python" n sha os=linux libc=gnu arch
        arch=$(uname -m)
        case $arch in arm64) arch=aarch64 ;; esac
        case "$(uname -s)" in Darwin) os=macos libc=none ;; esac
        mkdir -p "$1/marks" "$1/config" "$1/uvtoml/sub" "$b/bin" "$b/lib/python3.13"
        for n in python3 python3.13; do
            printf '#!/bin/sh\necho ran >> "%s/marks/uvtoml-python"\nexec "%s" "$@"\n' "$1" "$WORK/uv_probe/bin/python" > "$b/bin/$n"
            chmod +x "$b/bin/$n"
        done
        printf '# system configuration generated and used by the sysconfig module\nbuild_time_vars = {}\n' \
            > "$b/lib/python3.13/_sysconfigdata__${os}_$arch.py"
        tar -czf "$1/uvtoml/python.tar.gz" -C "$1/uvtoml-src" python
        sha=$(sha256sum "$1/uvtoml/python.tar.gz" 2>/dev/null || shasum -a 256 "$1/uvtoml/python.tar.gz")
        printf '{"cpython-3.13.99-%s-%s-%s": {"name": "cpython", "arch": {"family": "%s", "variant": null}, "os": "%s", "libc": "%s", "major": 3, "minor": 13, "patch": 99, "prerelease": "", "url": "file://%s/uvtoml/python.tar.gz", "sha256": "%s", "variant": null}}\n' \
            "$os" "$arch" "$libc" "$arch" "$os" "$libc" "$1" "${sha%% *}" > "$1/uvtoml/downloads.json"
        printf 'python-downloads-json-url = "%s/uvtoml/downloads.json"\npython-preference = "only-managed"\npython-downloads = "automatic"\n' \
            "$1" > "$1/uvtoml/uv.toml"
    }
    # in_uvtoml_env <dir> <command...> - run the command as in a shell of one's
    # own, where a uv.toml may have uv download a python (the suite turns that
    # off above): config read, downloads allowed, installs under <dir>. Every
    # proxy is a closed local port, so nothing reaches the network.
    in_uvtoml_env() {
        local d=$1
        shift
        env -u UV_NO_CONFIG -u UV_OFFLINE -u UV_PYTHON_DOWNLOADS -u NO_PROXY -u no_proxy \
            HTTP_PROXY=http://127.0.0.1:9 HTTPS_PROXY=http://127.0.0.1:9 ALL_PROXY=http://127.0.0.1:9 \
            http_proxy=http://127.0.0.1:9 https_proxy=http://127.0.0.1:9 all_proxy=http://127.0.0.1:9 \
            UV_PYTHON_INSTALL_DIR="$d/pythons" UV_PYTHON_BIN_DIR="$d/bin" UV_CACHE_DIR="$d/uvcache" \
            XDG_CONFIG_HOME="$d/config" "$@"
    }
    # mk_clones <dir> - seven clones under <dir>, each piece of whose code
    # writes its name to <dir>/marks when it runs: build/ has a pyproject.toml
    # whose build backend is in the repository, venv/ commits a .venv and a
    # .python-version that names a program in the repository, cfg/ commits
    # a pyvenv.cfg and a bin/python at its top, with no pyproject.toml and no
    # .venv, pyver/ commits only the .python-version and its program, pyvers/
    # the same as a .python-versions, uvtoml/ is mk_uvtoml_clone's, and bare/
    # commits a .python-version that holds the name tools alone, with no /,
    # and a tools/bin/python. uv run built the first, for `python --version`
    # too, and left a .venv and a uv.lock in it; in the second it ran the
    # .venv's python, and the .python-version's program when it read that
    # file; below the third it ran its bin/python, as uv takes a directory with
    # a pyvenv.cfg for a venv; in the fourth and fifth it ran the program; in
    # the sixth it installed the clone's python and ran it; and in the seventh
    # it took tools/ for a venv and ran its python.
    mk_clones() {
        mk_uvtoml_clone "$1"
        mkdir -p "$1/bare/tools/bin"
        printf '#!/bin/sh\necho ran >> "%s/marks/%s"\nexec "%s" "$@"\n' "$1" bare-python "$WORK/uv_probe/bin/python" > "$1/bare/tools/bin/python"
        chmod +x "$1/bare/tools/bin/python"
        printf 'tools\n' > "$1/bare/.python-version"
        mkdir -p "$1/pyver/tools" "$1/pyvers/tools"
        printf '#!/bin/sh\necho ran >> "%s/marks/%s"\nexec "%s" "$@"\n' "$1" pyver-program "$WORK/uv_probe/bin/python" > "$1/pyver/tools/py"
        printf '#!/bin/sh\necho ran >> "%s/marks/%s"\nexec "%s" "$@"\n' "$1" pyvers-program "$WORK/uv_probe/bin/python" > "$1/pyvers/tools/py"
        chmod +x "$1/pyver/tools/py" "$1/pyvers/tools/py"
        printf './tools/py\n' > "$1/pyver/.python-version"
        printf './tools/py\n' > "$1/pyvers/.python-versions"
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
    # pyver/, pyvers/, uvtoml/ and bare/ are a threat only while the real uv
    # here runs their code: plain uv run shows that once, in clones of their
    # own, or their checks are skipped, as there would be nothing to keep from
    # running.
    mk_clones "$WORK/clones-uv"
    (cd "$WORK/clones-uv/pyver" && env -u UV_NO_CONFIG XDG_CONFIG_HOME="$WORK/clones-uv/config" "$REAL_UV" run -- python -c pass) >/dev/null 2>&1 || true
    PYVER_THREAT=0
    [ -e "$WORK/clones-uv/marks/pyver-program" ] && PYVER_THREAT=1
    (cd "$WORK/clones-uv/pyvers" && env -u UV_NO_CONFIG XDG_CONFIG_HOME="$WORK/clones-uv/config" "$REAL_UV" run -- python -c pass) >/dev/null 2>&1 || true
    PYVERS_THREAT=0
    [ -e "$WORK/clones-uv/marks/pyvers-program" ] && PYVERS_THREAT=1
    (cd "$WORK/clones-uv/uvtoml" && in_uvtoml_env "$WORK/clones-uv" "$REAL_UV" run -- python -c pass) >/dev/null 2>&1 || true
    UVTOML_THREAT=0
    [ -e "$WORK/clones-uv/marks/uvtoml-python" ] && UVTOML_THREAT=1
    (cd "$WORK/clones-uv/bare" && env -u UV_NO_CONFIG XDG_CONFIG_HOME="$WORK/clones-uv/config" "$REAL_UV" run -- python -c pass) >/dev/null 2>&1 || true
    BARE_THREAT=0
    [ -e "$WORK/clones-uv/marks/bare-python" ] && BARE_THREAT=1
    # mk_dir_clones <dir> - two clones in <dir>, which holds no marker, each
    # with a program that writes its name to <dir>/marks when it runs: clone/
    # commits a .python-version that names its tools/py from itself, where
    # uv venv --directory clone runs, and proj/ one that names proj/tools/py,
    # from <dir>, where uv venv --project proj runs and looks it up. Plain
    # uv venv so, from <dir>, ran each program. via/ links to clone/deep/:
    # via/.. is clone/ to the system and to uv, and <dir> by name.
    mk_dir_clones() {
        mkdir -p "$1/marks" "$1/config" "$1/clone/tools" "$1/clone/deep" "$1/proj/tools"
        ln -s clone/deep "$1/via"
        printf '#!/bin/sh\necho ran >> "%s/marks/%s"\nexec "%s" "$@"\n' "$1" clone-program "$WORK/uv_probe/bin/python" > "$1/clone/tools/py"
        printf '#!/bin/sh\necho ran >> "%s/marks/%s"\nexec "%s" "$@"\n' "$1" proj-program "$WORK/uv_probe/bin/python" > "$1/proj/tools/py"
        chmod +x "$1/clone/tools/py" "$1/proj/tools/py"
        printf './tools/py\n' > "$1/clone/.python-version"
        printf 'proj/tools/py\n' > "$1/proj/.python-version"
    }
    mk_dir_clones "$WORK/dirclones-uv"
    (cd "$WORK/dirclones-uv" && env -u UV_NO_CONFIG XDG_CONFIG_HOME="$WORK/dirclones-uv/config" "$REAL_UV" venv --directory clone v0) >/dev/null 2>&1 || true
    DIR_THREAT=0
    [ -e "$WORK/dirclones-uv/marks/clone-program" ] && DIR_THREAT=1
    (cd "$WORK/dirclones-uv" && env -u UV_NO_CONFIG XDG_CONFIG_HOME="$WORK/dirclones-uv/config" "$REAL_UV" venv --project proj v0) >/dev/null 2>&1 || true
    PROJECT_THREAT=0
    [ -e "$WORK/dirclones-uv/marks/proj-program" ] && PROJECT_THREAT=1
    mk_dir_clones "$WORK/linkclones-uv"
    (cd "$WORK/linkclones-uv" && env -u UV_NO_CONFIG XDG_CONFIG_HOME="$WORK/linkclones-uv/config" "$REAL_UV" venv --directory via/.. v0) >/dev/null 2>&1 || true
    LINK_THREAT=0
    [ -e "$WORK/linkclones-uv/marks/clone-program" ] && LINK_THREAT=1
    # mk_nl_clone <dir> - in <dir>, which holds no marker, a clone whose
    # directory's name ends in a newline (clone<newline>/), with a
    # .python-version that names its ./evil, a program that writes nl-program
    # to <dir>/marks when it runs. Plain uv run in it, and plain uv venv
    # --directory at it, ran the program.
    mk_nl_clone() {
        mkdir -p "$1/marks" "$1/config" "$1/clone$NL"
        printf '#!/bin/sh\necho ran >> "%s/marks/nl-program"\nexec "%s" "$@"\n' "$1" "$WORK/uv_probe/bin/python" > "$1/clone$NL/evil"
        chmod +x "$1/clone$NL/evil"
        printf './evil\n' > "$1/clone$NL/.python-version"
    }
    mk_nl_clone "$WORK/nlclone-uv-run"
    (cd "$WORK/nlclone-uv-run/clone$NL" && env -u UV_NO_CONFIG XDG_CONFIG_HOME="$WORK/nlclone-uv-run/config" "$REAL_UV" run -- python --version) >/dev/null 2>&1 || true
    NL_RUN_THREAT=0
    [ -e "$WORK/nlclone-uv-run/marks/nl-program" ] && NL_RUN_THREAT=1
    mk_nl_clone "$WORK/nlclone-uv-venv"
    (cd "$WORK/nlclone-uv-venv" && env -u UV_NO_CONFIG XDG_CONFIG_HOME="$WORK/nlclone-uv-venv/config" "$REAL_UV" venv --directory "clone$NL" v0) >/dev/null 2>&1 || true
    NL_VENV_THREAT=0
    [ -e "$WORK/nlclone-uv-venv/marks/nl-program" ] && NL_VENV_THREAT=1
    # mk_wheel <dir> <name> <version> - an empty pure-Python wheel of that
    # name and version in <dir>.
    mk_wheel() {
        "$WORK/uv_probe/bin/python" -I -B -c '
import sys, zipfile
out, name, version = sys.argv[1:4]
info = name + "-" + version + ".dist-info/"
files = {
    name + "/__init__.py": "",
    info + "METADATA": "Metadata-Version: 2.1\nName: " + name + "\nVersion: " + version + "\n",
    info + "WHEEL": "Wheel-Version: 1.0\nGenerator: den-test\nRoot-Is-Purelib: true\nTag: py3-none-any\n",
}
files[info + "RECORD"] = "".join(n + ",,\n" for n in files) + info + "RECORD,,\n"
with zipfile.ZipFile(out + "/" + name + "-" + version + "-py3-none-any.whl", "w") as z:
    for n, text in files.items():
        z.writestr(n, text)
' "$1" "$2" "$3"
    }
    # mk_pip_clones <dir> - two clones whose uv settings uv pip reads, and
    # <dir>/venv, a venv the user made elsewhere with uv venv, which has no
    # pip: pipcfg/ has a uv.toml whose [pip] python names a program in the
    # clone, which writes pip-python to <dir>/marks, and findlinks/ one whose
    # find-links and no-index have uv install the requests 99.0.0 wheel in the
    # clone's wheels/. pip reads neither file.
    mk_pip_clones() {
        mkdir -p "$1/marks" "$1/config" "$1/pipcfg" "$1/findlinks/wheels"
        printf '#!/bin/sh\necho ran >> "%s/marks/pip-python"\nexec "%s" "$@"\n' "$1" "$WORK/uv_probe/bin/python" > "$1/pipcfg/evil"
        chmod +x "$1/pipcfg/evil"
        printf '[pip]\npython = "./evil"\n' > "$1/pipcfg/uv.toml"
        printf 'no-index = true\nfind-links = ["./wheels"]\n' > "$1/findlinks/uv.toml"
        mk_wheel "$1/findlinks/wheels" requests 99.0.0
        "$REAL_UV" venv -q "$1/venv" >/dev/null 2>&1
    }
    # mk_usercfg <dir> - a uv.toml of your own, <dir>/config/uv/uv.toml (with
    # XDG_CONFIG_HOME=<dir>/config), whose settings only that file can give
    # uv: no index, and find-links to <dir>/wheels, which holds userpkg 1.0.0
    # and the pip 99.0.0 that uv venv --seed installs (setuptools and wheel
    # 99.0.0 too, which it adds for a python before 3.12).
    mk_usercfg() {
        local w
        mkdir -p "$1/config/uv" "$1/wheels"
        printf 'no-index = true\nfind-links = ["%s/wheels"]\n' "$1" > "$1/config/uv/uv.toml"
        mk_wheel "$1/wheels" userpkg 1.0.0
        for w in pip setuptools wheel; do
            mk_wheel "$1/wheels" "$w" 99.0.0
        done
    }
    # pip_clone_installed <dir> - the clone's requests wheel, if uv installed it.
    pip_clone_installed() {
        find "$1/venv" -name 'requests-99.0.0.dist-info' 2>/dev/null
    }
    # Plain uv pip, as den's pip ran it, in a venv without pip: whether the uv
    # here runs the program and installs the wheel, or there is nothing to check.
    mk_pip_clones "$WORK/pipclones-uv"
    (cd "$WORK/pipclones-uv/pipcfg" && env -u UV_NO_CONFIG XDG_CONFIG_HOME="$WORK/pipclones-uv/config" VIRTUAL_ENV="$WORK/pipclones-uv/venv" "$REAL_UV" pip list) >/dev/null 2>&1 || true
    PIPCFG_THREAT=0
    [ -e "$WORK/pipclones-uv/marks/pip-python" ] && PIPCFG_THREAT=1
    (cd "$WORK/pipclones-uv/findlinks" && env -u UV_NO_CONFIG XDG_CONFIG_HOME="$WORK/pipclones-uv/config" VIRTUAL_ENV="$WORK/pipclones-uv/venv" "$REAL_UV" pip install requests) >/dev/null 2>&1 || true
    FINDLINKS_THREAT=0
    [ -n "$(pip_clone_installed "$WORK/pipclones-uv")" ] && FINDLINKS_THREAT=1
    # Run with the config files read (UV_NO_CONFIG unset, with no user uv.toml in
    # XDG_CONFIG_HOME), as in a shell of one's own: uv reads a .python-version only then.
    for sh in bash zsh; do
        if [ "$PIPCFG_THREAT" = 1 ] || [ "$FINDLINKS_THREAT" = 1 ]; then
            echo "[$sh] in a venv without pip, pip and pip3 run no python a clone's uv.toml names and install nothing from its files (the real uv)"
            P="$WORK/pipclones-$sh"
            mk_pip_clones "$P"
            actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$P/config" "$sh" -c "
                . '$PYTHON_SH_SOURCE'
                export VIRTUAL_ENV='$P/venv'
                cd '$P/pipcfg' || exit 1
                pip list >/dev/null 2>&1
                pip3 freeze >/dev/null 2>&1
                cd '$P/findlinks' || exit 1
                pip install requests >/dev/null 2>&1
                echo done
            " 2>/dev/null | tr -d '\r') || true
            assert_eq "$sh/pip and pip3 in clones end" "done" "$actual"
            if [ "$PIPCFG_THREAT" = 1 ]; then
                assert_not_exists "$sh/pip and pip3 ran no python a clone's uv.toml names" "$P/marks/pip-python"
            fi
            if [ "$FINDLINKS_THREAT" = 1 ]; then
                assert_eq "$sh/pip installed nothing from a clone's find-links" "" "$(pip_clone_installed "$P")"
            fi
        fi

        echo "[$sh] with a uv.toml of your own, pip and pip3 in a venv without pip read it, and still nothing of a clone's (the real uv)"
        P="$WORK/pipclones-$sh-mine"
        mk_pip_clones "$P"
        mk_usercfg "$P/mine"
        actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$P/mine/config" "$sh" -c "
            . '$PYTHON_SH_SOURCE'
            export VIRTUAL_ENV='$P/venv'
            cd '$P/pipcfg' || exit 1
            pip list >/dev/null 2>&1
            cd '$P/findlinks' || exit 1
            pip install requests >/dev/null 2>&1
            pip3 install userpkg >/dev/null 2>&1
            echo \"userpkg=\$?\"
        " 2>/dev/null | tr -d '\r') || true
        assert_eq "$sh/pip3 installed the package your uv.toml's find-links offers" "userpkg=0" "$actual"
        if [ "$PIPCFG_THREAT" = 1 ]; then
            assert_not_exists "$sh/pip with a uv.toml of yours ran no python a clone's uv.toml names" "$P/marks/pip-python"
        fi
        if [ "$FINDLINKS_THREAT" = 1 ]; then
            assert_eq "$sh/pip with a uv.toml of yours installed nothing from a clone's find-links" "" "$(pip_clone_installed "$P")"
        fi

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

        # uv run reads where UV_PROJECT, UV_WORKING_DIR or UV_WORKING_DIRECTORY
        # moves it: from a directory with no marker it built the clone there,
        # through a relative UV_PROJECT and in a venv va activated as well.
        echo "[$sh] from a directory with no marker, python, python3 and py with UV_PROJECT, UV_WORKING_DIR or UV_WORKING_DIRECTORY at a clone run none of its code (the real uv)"
        E="$WORK/envclones-$sh"
        mk_clones "$E"
        "$REAL_UV" venv -q "$E/myvenv" >/dev/null 2>&1
        actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$E/config" "$sh" -c "
            . '$PYTHON_SH_SOURCE'
            unset VIRTUAL_ENV _DEN_VENV_PYTHON
            cd '$NOPROJ' || exit 1
            export UV_PROJECT='$E/build'; python --version >/dev/null 2>&1; echo \"python=\$?\"; unset UV_PROJECT
            export UV_WORKING_DIR='$E/build'; python3 -c 'print(1)'; unset UV_WORKING_DIR
            export UV_WORKING_DIRECTORY='$E/build/src'; py -c 'print(2)'; unset UV_WORKING_DIRECTORY
            export UV_PROJECT='../envclones-$sh/build'; python -c 'print(3)'; unset UV_PROJECT
            va '$E/myvenv' >/dev/null 2>&1 || exit 1
            export UV_PROJECT='$E/build'; python -c 'print(4)'; unset UV_PROJECT
        " 2>/dev/null | tr -d '\r') || true
        assert_eq "$sh/python, python3 and py with UV_PROJECT, UV_WORKING_DIR or UV_WORKING_DIRECTORY at a clone" "python=0
1
2
3
4" "$actual"
        assert_eq "$sh/no code of the clone UV_PROJECT, UV_WORKING_DIR or UV_WORKING_DIRECTORY names ran" "" "$(ls "$E/marks")"
        assert_not_exists "$sh/no .venv appears in the clone UV_PROJECT names" "$E/build/.venv"
        assert_not_exists "$sh/no uv.lock appears in the clone UV_PROJECT names" "$E/build/uv.lock"

        if [ "$PYVER_THREAT" = 1 ]; then
            echo "[$sh] beside a clone's .python-version that names its program, python, python3 and py run none of its code (the real uv)"
            actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$C/config" "$sh" -c "
                . '$PYTHON_SH_SOURCE'
                unset VIRTUAL_ENV _DEN_VENV_PYTHON
                cd '$C/pyver' || exit 1
                python -c 'print(6)'
                python3 -c 'print(7)'
                py -c 'print(8)'
            " 2>/dev/null | tr -d '\r') || true
            assert_eq "$sh/python, python3 and py beside a .python-version that names a program" "6
7
8" "$actual"
            assert_not_exists "$sh/the program the clone's .python-version names did not run" "$C/marks/pyver-program"

            echo "[$sh] beside it, vv and vva run none of its code either (the real uv)"
            actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$C/config" "$sh" -c "
                . '$PYTHON_SH_SOURCE'
                unset VIRTUAL_ENV _DEN_VENV_PYTHON
                cd '$C/pyver' || exit 1
                vv v1 >/dev/null 2>&1
                echo \"vv=\$?\"
                vva v2 >/dev/null 2>&1
                echo \"vva=\$? VE=[\${VIRTUAL_ENV##*/}]\"
            " 2>/dev/null | tr -d '\r') || true
            assert_eq "$sh/vv and vva beside a .python-version that names a program" "vv=0
vva=0 VE=[v2]" "$actual"
            assert_not_exists "$sh/vv and vva ran no program the clone's .python-version names" "$C/marks/pyver-program"

            echo "[$sh] with a uv.toml of your own, vv reads it there, and still runs none of the clone's code (the real uv)"
            mk_usercfg "$C/mine"
            actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$C/mine/config" "$sh" -c "
                . '$PYTHON_SH_SOURCE'
                unset VIRTUAL_ENV _DEN_VENV_PYTHON
                cd '$C/pyver' || exit 1
                vv --seed v3 >/dev/null 2>&1
                echo \"vv=\$?\"
            " 2>/dev/null | tr -d '\r') || true
            assert_eq "$sh/vv --seed with a uv.toml of yours beside a .python-version that names a program" "vv=0" "$actual"
            assert_eq "$sh/vv --seed installed the pip your uv.toml's find-links offers" "pip-99.0.0.dist-info" \
                "$(find "$C/pyver/v3" -name 'pip-*.dist-info' -exec basename {} \; 2>/dev/null)"
            assert_not_exists "$sh/vv with a uv.toml of yours ran no program the clone's .python-version names" "$C/marks/pyver-program"
        fi

        if [ "$PYVERS_THREAT" = 1 ]; then
            echo "[$sh] beside a clone's .python-versions that names its program, python, python3 and py run none of its code (the real uv)"
            actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$C/config" "$sh" -c "
                . '$PYTHON_SH_SOURCE'
                unset VIRTUAL_ENV _DEN_VENV_PYTHON
                cd '$C/pyvers' || exit 1
                python -c 'print(12)'
                python3 -c 'print(13)'
                py -c 'print(14)'
            " 2>/dev/null | tr -d '\r') || true
            assert_eq "$sh/python, python3 and py beside a .python-versions that names a program" "12
13
14" "$actual"
            assert_not_exists "$sh/the program the clone's .python-versions names did not run" "$C/marks/pyvers-program"
        fi

        if [ "$UVTOML_THREAT" = 1 ]; then
            echo "[$sh] below a clone's uv.toml, python, python3 and py run none of its code (the real uv, offline)"
            actual=$(in_uvtoml_env "$C" "$sh" -c "
                . '$PYTHON_SH_SOURCE'
                unset VIRTUAL_ENV _DEN_VENV_PYTHON
                cd '$C/uvtoml/sub' || exit 1
                python -c 'print(9)'
                python3 -c 'print(10)'
                py -c 'print(11)'
            " 2>/dev/null | tr -d '\r') || true
            assert_eq "$sh/python, python3 and py below a uv.toml" "9
10
11" "$actual"
            assert_not_exists "$sh/the python the clone's uv.toml names did not run" "$C/marks/uvtoml-python"
            assert_eq "$sh/no python was installed from the clone" "" "$(ls "$C/pythons" 2>/dev/null)"

            echo "[$sh] below it, vv with --python installs and runs no python of the clone's either (the real uv, offline)"
            actual=$(in_uvtoml_env "$C" "$sh" -c "
                . '$PYTHON_SH_SOURCE'
                unset VIRTUAL_ENV _DEN_VENV_PYTHON
                cd '$C/uvtoml/sub' || exit 1
                vv --python 3.13 v1 >/dev/null 2>&1
                echo done
            " 2>/dev/null | tr -d '\r') || true
            assert_eq "$sh/vv --python below a uv.toml ends" "done" "$actual"
            assert_not_exists "$sh/vv --python ran no python the clone's uv.toml names" "$C/marks/uvtoml-python"
            assert_eq "$sh/vv --python installed no python from the clone" "" "$(ls "$C/pythons" 2>/dev/null)"
        fi

        if [ "$BARE_THREAT" = 1 ]; then
            echo "[$sh] beside a clone's .python-version that names its tools/ directory with no /, python, python3 and py run none of its code (the real uv)"
            actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$C/config" "$sh" -c "
                . '$PYTHON_SH_SOURCE'
                unset VIRTUAL_ENV _DEN_VENV_PYTHON
                cd '$C/bare' || exit 1
                python -c 'print(15)'
                python3 -c 'print(16)'
                py -c 'print(17)'
            " 2>/dev/null | tr -d '\r') || true
            assert_eq "$sh/python, python3 and py beside a .python-version that names a directory" "15
16
17" "$actual"
            assert_not_exists "$sh/the python of the directory the clone's .python-version names did not run" "$C/marks/bare-python"
        fi

        if [ "$DIR_THREAT" = 1 ] || [ "$PROJECT_THREAT" = 1 ]; then
            echo "[$sh] from a directory with no marker, vv and vva at a clone with --directory, --directory=, UV_WORKING_DIR or --project run none of its code (the real uv)"
            D="$WORK/dirclones-$sh"
            mk_dir_clones "$D"
            actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$D/config" "$sh" -c "
                . '$PYTHON_SH_SOURCE'
                unset VIRTUAL_ENV _DEN_VENV_PYTHON
                cd '$D' || exit 1
                vv --directory clone v1 >/dev/null 2>&1; echo \"vv=\$?\"
                vv --directory='$D/clone' v2 >/dev/null 2>&1; echo \"vv=\$?\"
                export UV_WORKING_DIR=clone; vv v3 >/dev/null 2>&1; echo \"vv=\$?\"; unset UV_WORKING_DIR
                vva v4 --directory clone >/dev/null 2>&1
                vv --project proj v5 >/dev/null 2>&1; echo \"vv=\$?\"
            " 2>/dev/null | tr -d '\r') || true
            assert_eq "$sh/vv at a clone with --directory, --directory=, UV_WORKING_DIR or --project" "vv=0
vv=0
vv=0
vv=0" "$actual"
            if [ "$DIR_THREAT" = 1 ]; then
                assert_not_exists "$sh/vv and vva with --directory ran no program the clone's .python-version names" "$D/marks/clone-program"
            fi
            if [ "$PROJECT_THREAT" = 1 ]; then
                assert_not_exists "$sh/vv with --project ran no program the clone's .python-version names" "$D/marks/proj-program"
            fi
        fi

        if [ "$LINK_THREAT" = 1 ]; then
            echo "[$sh] from a directory with no marker, vv at a link's .. that the system takes into a clone runs none of its code (the real uv)"
            D="$WORK/linkclones-$sh"
            mk_dir_clones "$D"
            actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$D/config" "$sh" -c "
                . '$PYTHON_SH_SOURCE'
                unset VIRTUAL_ENV _DEN_VENV_PYTHON
                cd '$D' || exit 1
                vv --directory via/.. v1 >/dev/null 2>&1; echo \"vv=\$?\"
                vv --directory '$D/via/..' v2 >/dev/null 2>&1; echo \"vv=\$?\"
            " 2>/dev/null | tr -d '\r') || true
            assert_eq "$sh/vv at a link's .. into a clone" "vv=0
vv=0" "$actual"
            assert_not_exists "$sh/vv at a link's .. into a clone ran no program the clone's .python-version names" "$D/marks/clone-program"
        fi

        if [ "$NL_RUN_THREAT" = 1 ]; then
            echo "[$sh] in a clone whose directory's name ends in a newline, python --version runs none of its code (the real uv)"
            N="$WORK/nlclone-$sh-run"
            mk_nl_clone "$N"
            actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$N/config" "$sh" -c "
                . '$PYTHON_SH_SOURCE'
                unset VIRTUAL_ENV _DEN_VENV_PYTHON
                cd '$N/clone$NL' || exit 1
                python --version >/dev/null 2>&1; echo \"python=\$?\"
            " 2>/dev/null | tr -d '\r') || true
            assert_eq "$sh/python --version in a clone whose name ends in a newline" "python=0" "$actual"
            assert_not_exists "$sh/python --version ran no program the clone's .python-version names" "$N/marks/nl-program"
        fi

        if [ "$NL_VENV_THREAT" = 1 ]; then
            echo "[$sh] from a directory with no marker, vv --directory at a clone whose name ends in a newline runs none of its code (the real uv)"
            N="$WORK/nlclone-$sh-venv"
            mk_nl_clone "$N"
            actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$N/config" "$sh" -c "
                . '$PYTHON_SH_SOURCE'
                unset VIRTUAL_ENV _DEN_VENV_PYTHON
                cd '$N' || exit 1
                vv --directory 'clone$NL' v1 >/dev/null 2>&1; echo \"vv=\$?\"
            " 2>/dev/null | tr -d '\r') || true
            assert_eq "$sh/vv --directory at a clone whose name ends in a newline" "vv=0" "$actual"
            assert_not_exists "$sh/vv --directory ran no program the clone's .python-version names" "$N/marks/nl-program"
        fi
    done

    if [ "$PIPCFG_THREAT" = 1 ] || [ "$FINDLINKS_THREAT" = 1 ]; then
        echo "[pwsh] in a venv without pip, pip and pip3 run no python a clone's uv.toml names and install nothing from its files (the real uv)"
        P="$WORK/pipclones-pwsh"
        mk_pip_clones "$P"
        actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$P/config" pwsh -NoProfile -NonInteractive -Command "
            . '$PYTHON_PS1_REAL_UV'
            \$env:VIRTUAL_ENV = '$P/venv'
            Set-Location -LiteralPath '$P/pipcfg'
            pip list *>\$null
            pip3 freeze *>\$null
            Set-Location -LiteralPath '$P/findlinks'
            pip install requests *>\$null
            'done'
        " 2>/dev/null | tr -d '\r') || true
        assert_eq "pwsh/pip and pip3 in clones end" "done" "$actual"
        if [ "$PIPCFG_THREAT" = 1 ]; then
            assert_not_exists "pwsh/pip and pip3 ran no python a clone's uv.toml names" "$P/marks/pip-python"
        fi
        if [ "$FINDLINKS_THREAT" = 1 ]; then
            assert_eq "pwsh/pip installed nothing from a clone's find-links" "" "$(pip_clone_installed "$P")"
        fi
    else
        echo "  SKIP: real-uv pip clone checks (uv pip here neither ran the python a clone's uv.toml names nor installed from its find-links)"
    fi

    echo "[pwsh] with a uv.toml of your own, pip and pip3 in a venv without pip read it, and still nothing of a clone's (the real uv)"
    P="$WORK/pipclones-pwsh-mine"
    mk_pip_clones "$P"
    mk_usercfg "$P/mine"
    actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$P/mine/config" pwsh -NoProfile -NonInteractive -Command "
        . '$PYTHON_PS1_REAL_UV'
        \$env:VIRTUAL_ENV = '$P/venv'
        Set-Location -LiteralPath '$P/pipcfg'
        pip list *>\$null
        Set-Location -LiteralPath '$P/findlinks'
        pip install requests *>\$null
        pip3 install userpkg *>\$null
        \"userpkg=\$LASTEXITCODE\"
    " 2>/dev/null | tr -d '\r') || true
    assert_eq "pwsh/pip3 installed the package your uv.toml's find-links offers" "userpkg=0" "$actual"
    if [ "$PIPCFG_THREAT" = 1 ]; then
        assert_not_exists "pwsh/pip with a uv.toml of yours ran no python a clone's uv.toml names" "$P/marks/pip-python"
    fi
    if [ "$FINDLINKS_THREAT" = 1 ]; then
        assert_eq "pwsh/pip with a uv.toml of yours installed nothing from a clone's find-links" "" "$(pip_clone_installed "$P")"
    fi

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

    echo "[pwsh] from a directory with no marker, python, python3 and py with UV_PROJECT, UV_WORKING_DIR or UV_WORKING_DIRECTORY at a clone run none of its code (the real uv)"
    E="$WORK/envclones-pwsh"
    mk_clones "$E"
    "$REAL_UV" venv -q "$E/myvenv" >/dev/null 2>&1
    actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$E/config" pwsh -NoProfile -NonInteractive -Command "
        . '$PYTHON_PS1_REAL_UV'
        Remove-Item Env:\\VIRTUAL_ENV, Env:\\_DEN_VENV_PYTHON -ErrorAction SilentlyContinue
        Set-Location -LiteralPath '$NOPROJ'
        \$env:UV_PROJECT = '$E/build'; python --version *>\$null; \"python=\$LASTEXITCODE\"; Remove-Item Env:\\UV_PROJECT
        \$env:UV_WORKING_DIR = '$E/build'; python3 -c 'print(1)' 3>\$null; Remove-Item Env:\\UV_WORKING_DIR
        \$env:UV_WORKING_DIRECTORY = '$E/build/src'; py -c 'print(2)' 3>\$null; Remove-Item Env:\\UV_WORKING_DIRECTORY
        \$env:UV_PROJECT = '../envclones-pwsh/build'; python -c 'print(3)' 3>\$null; Remove-Item Env:\\UV_PROJECT
        va '$E/myvenv' *>\$null
        \$env:UV_PROJECT = '$E/build'; python -c 'print(4)' 3>\$null; Remove-Item Env:\\UV_PROJECT
    " 2>/dev/null | tr -d '\r') || true
    assert_eq "pwsh/python, python3 and py with UV_PROJECT, UV_WORKING_DIR or UV_WORKING_DIRECTORY at a clone" "python=0
1
2
3
4" "$actual"
    assert_eq "pwsh/no code of the clone UV_PROJECT, UV_WORKING_DIR or UV_WORKING_DIRECTORY names ran" "" "$(ls "$E/marks")"
    assert_not_exists "pwsh/no .venv appears in the clone UV_PROJECT names" "$E/build/.venv"
    assert_not_exists "pwsh/no uv.lock appears in the clone UV_PROJECT names" "$E/build/uv.lock"

    if [ "$PYVER_THREAT" = 1 ]; then
        echo "[pwsh] beside a clone's .python-version that names its program, python, python3 and py run none of its code (the real uv)"
        actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$C/config" pwsh -NoProfile -NonInteractive -Command "
            . '$PYTHON_PS1_REAL_UV'
            Remove-Item Env:\\VIRTUAL_ENV, Env:\\_DEN_VENV_PYTHON -ErrorAction SilentlyContinue
            Set-Location -LiteralPath '$C/pyver'
            python -c 'print(6)' 3>\$null
            python3 -c 'print(7)' 3>\$null
            py -c 'print(8)' 3>\$null
        " 2>/dev/null | tr -d '\r') || true
        assert_eq "pwsh/python, python3 and py beside a .python-version that names a program" "6
7
8" "$actual"
        assert_not_exists "pwsh/the program the clone's .python-version names did not run" "$C/marks/pyver-program"

        echo "[pwsh] beside it, vv and vva run none of its code either (the real uv)"
        actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$C/config" pwsh -NoProfile -NonInteractive -Command "
            . '$PYTHON_PS1_REAL_UV'
            Remove-Item Env:\\VIRTUAL_ENV, Env:\\_DEN_VENV_PYTHON -ErrorAction SilentlyContinue
            Set-Location -LiteralPath '$C/pyver'
            vv v1 *>\$null
            \"vv=\$LASTEXITCODE\"
            vva v2 *>\$null
            \$leaf = if (\$env:VIRTUAL_ENV) { Split-Path -Leaf \$env:VIRTUAL_ENV } else { '' }
            \"VE=[\$leaf]\"
        " 2>/dev/null | tr -d '\r') || true
        assert_eq "pwsh/vv and vva beside a .python-version that names a program" "vv=0
VE=[v2]" "$actual"
        assert_not_exists "pwsh/vv and vva ran no program the clone's .python-version names" "$C/marks/pyver-program"

        echo "[pwsh] with a uv.toml of your own, vv reads it there, and still runs none of the clone's code (the real uv)"
        mk_usercfg "$C/mine"
        actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$C/mine/config" pwsh -NoProfile -NonInteractive -Command "
            . '$PYTHON_PS1_REAL_UV'
            Remove-Item Env:\\VIRTUAL_ENV, Env:\\_DEN_VENV_PYTHON -ErrorAction SilentlyContinue
            Set-Location -LiteralPath '$C/pyver'
            vv --seed v3 *>\$null
            \"vv=\$LASTEXITCODE\"
        " 2>/dev/null | tr -d '\r') || true
        assert_eq "pwsh/vv --seed with a uv.toml of yours beside a .python-version that names a program" "vv=0" "$actual"
        assert_eq "pwsh/vv --seed installed the pip your uv.toml's find-links offers" "pip-99.0.0.dist-info" \
            "$(find "$C/pyver/v3" -name 'pip-*.dist-info' -exec basename {} \; 2>/dev/null)"
        assert_not_exists "pwsh/vv with a uv.toml of yours ran no program the clone's .python-version names" "$C/marks/pyver-program"
    else
        echo "  SKIP: real-uv .python-version clone checks (uv run here did not run the program the clone's .python-version names)"
    fi

    if [ "$PYVERS_THREAT" = 1 ]; then
        echo "[pwsh] beside a clone's .python-versions that names its program, python, python3 and py run none of its code (the real uv)"
        actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$C/config" pwsh -NoProfile -NonInteractive -Command "
            . '$PYTHON_PS1_REAL_UV'
            Remove-Item Env:\\VIRTUAL_ENV, Env:\\_DEN_VENV_PYTHON -ErrorAction SilentlyContinue
            Set-Location -LiteralPath '$C/pyvers'
            python -c 'print(12)' 3>\$null
            python3 -c 'print(13)' 3>\$null
            py -c 'print(14)' 3>\$null
        " 2>/dev/null | tr -d '\r') || true
        assert_eq "pwsh/python, python3 and py beside a .python-versions that names a program" "12
13
14" "$actual"
        assert_not_exists "pwsh/the program the clone's .python-versions names did not run" "$C/marks/pyvers-program"
    else
        echo "  SKIP: real-uv .python-versions clone checks (uv run here did not run the program the clone's .python-versions names)"
    fi

    if [ "$UVTOML_THREAT" = 1 ]; then
        echo "[pwsh] below a clone's uv.toml, python, python3 and py run none of its code (the real uv, offline)"
        actual=$(in_uvtoml_env "$C" pwsh -NoProfile -NonInteractive -Command "
            . '$PYTHON_PS1_REAL_UV'
            Remove-Item Env:\\VIRTUAL_ENV, Env:\\_DEN_VENV_PYTHON -ErrorAction SilentlyContinue
            Set-Location -LiteralPath '$C/uvtoml/sub'
            python -c 'print(9)' 3>\$null
            python3 -c 'print(10)' 3>\$null
            py -c 'print(11)' 3>\$null
        " 2>/dev/null | tr -d '\r') || true
        assert_eq "pwsh/python, python3 and py below a uv.toml" "9
10
11" "$actual"
        assert_not_exists "pwsh/the python the clone's uv.toml names did not run" "$C/marks/uvtoml-python"
        assert_eq "pwsh/no python was installed from the clone" "" "$(ls "$C/pythons" 2>/dev/null)"

        echo "[pwsh] below it, vv with --python installs and runs no python of the clone's either (the real uv, offline)"
        actual=$(in_uvtoml_env "$C" pwsh -NoProfile -NonInteractive -Command "
            . '$PYTHON_PS1_REAL_UV'
            Remove-Item Env:\\VIRTUAL_ENV, Env:\\_DEN_VENV_PYTHON -ErrorAction SilentlyContinue
            Set-Location -LiteralPath '$C/uvtoml/sub'
            vv --python 3.13 v1 *>\$null
            'done'
        " 2>/dev/null | tr -d '\r') || true
        assert_eq "pwsh/vv --python below a uv.toml ends" "done" "$actual"
        assert_not_exists "pwsh/vv --python ran no python the clone's uv.toml names" "$C/marks/uvtoml-python"
        assert_eq "pwsh/vv --python installed no python from the clone" "" "$(ls "$C/pythons" 2>/dev/null)"
    else
        echo "  SKIP: real-uv uv.toml clone checks (uv run here did not install and run the python the clone's uv.toml names)"
    fi

    if [ "$BARE_THREAT" = 1 ]; then
        echo "[pwsh] beside a clone's .python-version that names its tools/ directory with no /, python, python3 and py run none of its code (the real uv)"
        actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$C/config" pwsh -NoProfile -NonInteractive -Command "
            . '$PYTHON_PS1_REAL_UV'
            Remove-Item Env:\\VIRTUAL_ENV, Env:\\_DEN_VENV_PYTHON -ErrorAction SilentlyContinue
            Set-Location -LiteralPath '$C/bare'
            python -c 'print(15)' 3>\$null
            python3 -c 'print(16)' 3>\$null
            py -c 'print(17)' 3>\$null
        " 2>/dev/null | tr -d '\r') || true
        assert_eq "pwsh/python, python3 and py beside a .python-version that names a directory" "15
16
17" "$actual"
        assert_not_exists "pwsh/the python of the directory the clone's .python-version names did not run" "$C/marks/bare-python"
    else
        echo "  SKIP: real-uv bare-name .python-version clone checks (uv run here did not run the python of the directory the clone's .python-version names)"
    fi

    if [ "$DIR_THREAT" = 1 ] || [ "$PROJECT_THREAT" = 1 ]; then
        echo "[pwsh] from a directory with no marker, vv and vva at a clone with --directory, --directory=, UV_WORKING_DIR or --project run none of its code (the real uv)"
        D="$WORK/dirclones-pwsh"
        mk_dir_clones "$D"
        actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$D/config" pwsh -NoProfile -NonInteractive -Command "
            . '$PYTHON_PS1_REAL_UV'
            Remove-Item Env:\\VIRTUAL_ENV, Env:\\_DEN_VENV_PYTHON -ErrorAction SilentlyContinue
            Set-Location -LiteralPath '$D'
            vv --directory clone v1 *>\$null; \"vv=\$LASTEXITCODE\"
            vv --directory='$D/clone' v2 *>\$null; \"vv=\$LASTEXITCODE\"
            \$env:UV_WORKING_DIR = 'clone'; vv v3 *>\$null; \"vv=\$LASTEXITCODE\"; Remove-Item Env:\\UV_WORKING_DIR
            vva v4 --directory clone *>\$null
            vv --project proj v5 *>\$null; \"vv=\$LASTEXITCODE\"
        " 2>/dev/null | tr -d '\r') || true
        assert_eq "pwsh/vv at a clone with --directory, --directory=, UV_WORKING_DIR or --project" "vv=0
vv=0
vv=0
vv=0" "$actual"
        if [ "$DIR_THREAT" = 1 ]; then
            assert_not_exists "pwsh/vv and vva with --directory ran no program the clone's .python-version names" "$D/marks/clone-program"
        fi
        if [ "$PROJECT_THREAT" = 1 ]; then
            assert_not_exists "pwsh/vv with --project ran no program the clone's .python-version names" "$D/marks/proj-program"
        fi
    else
        echo "  SKIP: real-uv vv --directory and --project checks (uv venv here did not run the program a clone's .python-version names)"
    fi

    # .NET's SetCurrentDirectory takes a path by name before it enters it, so
    # vv once read via/.. back as the directory with no marker.
    if [ "$LINK_THREAT" = 1 ]; then
        echo "[pwsh] from a directory with no marker, vv at a link's .. that the system takes into a clone runs none of its code (the real uv)"
        D="$WORK/linkclones-pwsh"
        mk_dir_clones "$D"
        actual=$(env -u UV_NO_CONFIG XDG_CONFIG_HOME="$D/config" pwsh -NoProfile -NonInteractive -Command "
            . '$PYTHON_PS1_REAL_UV'
            Remove-Item Env:\\VIRTUAL_ENV, Env:\\_DEN_VENV_PYTHON -ErrorAction SilentlyContinue
            Set-Location -LiteralPath '$D'
            vv --directory via/.. v1 *>\$null; \"vv=\$LASTEXITCODE\"
            vv --directory '$D/via/..' v2 *>\$null; \"vv=\$LASTEXITCODE\"
        " 2>/dev/null | tr -d '\r') || true
        assert_eq "pwsh/vv at a link's .. into a clone" "vv=0
vv=0" "$actual"
        assert_not_exists "pwsh/vv at a link's .. into a clone ran no program the clone's .python-version names" "$D/marks/clone-program"
    else
        echo "  SKIP: real-uv vv at a link's .. check (uv venv here did not run the program a clone's .python-version names)"
    fi
else
    echo "  SKIP: uv-created venv tests (uv not installed, or no Python it can use offline)"
fi

# =============================================================================
# Summary
# =============================================================================
print_summary "test_python"
[ "$FAIL" -eq 0 ]
