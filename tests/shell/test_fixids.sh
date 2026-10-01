#!/usr/bin/env bash
# test_fixids.sh — Tests for shell/posix/bin/fixids (the standalone parallel chown).
# Most cases are dry runs (-n), which change nothing and need no root; stub
# `id` commands make fixids see root or another invoker. The case that really
# chowns runs only as root (the CI image runs the suites as root).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

FIXIDS="$DOTFILES/shell/posix/bin/fixids"
BASH_BIN=$(command -v bash) || abort_suite "no bash on PATH"
REAL_ID=$(command -v id) || abort_suite "no id on PATH"

# fx <dir to put first on PATH, or ''> <fixids args...>: stdout and stderr,
# then rc=<status>. Its temporary lists go under WORK.
fx() {
    local pre="$1"
    shift
    mkdir -p "$WORK/tmp"
    (PATH="$pre${pre:+:}$PATH" TMPDIR="$WORK/tmp" "$BASH_BIN" "$FIXIDS" "$@" 2>&1; echo "rc=$?")
}

# A tree of 6 entries (the root t, a, b, b/c, node_modules, node_modules/x),
# all owned by whoever runs the suite: U.
setup_tree() {
    rm -rf "${WORK:?}/t"
    mkdir -p "$WORK/t/b" "$WORK/t/node_modules"
    : > "$WORK/t/a"
    : > "$WORK/t/b/c"
    : > "$WORK/t/node_modules/x"
}
setup_tree
U=$(stat -c %u "$WORK/t")

# id as root sees it, and as uid/gid 1234 sees it; any other use of id (a name
# to resolve) goes to the real one.
mkdir -p "$TESTTMP/asroot" "$TESTTMP/asuser"
printf '#!/bin/sh\ncase "$*" in -u|-g) echo 0 ;; *) exec "%s" "$@" ;; esac\n' "$REAL_ID" > "$TESTTMP/asroot/id"
printf '#!/bin/sh\ncase "$*" in -u|-g) echo 1234 ;; *) exec "%s" "$@" ;; esac\n' "$REAL_ID" > "$TESTTMP/asuser/id"
chmod +x "$TESTTMP/asroot/id" "$TESTTMP/asuser/id"

# =============================================================================
# The target owner when run as root
# =============================================================================
# With no --to, the target was the invoker's ids: as root, 0:0. The header's
# own entrypoint recipe ran `fixids --from 1000:1000 ... "$HOME"` as root, so
# it handed every 1000:1000 file to root just before the command dropped to
# uid 1000, which could then no longer write its own home.
echo "[fixids] run as root without --to, it stops"
actual=$(fx "$TESTTMP/asroot" -n "$WORK/t")
assert_eq "fixids/root without --to refused" "fixids: running as root: name the target owner with --to UID[:GID] (--to 0:0 for root)
rc=2" "$actual"

echo "[fixids] run as root with --to 0:0, it runs as before"
actual=$(fx "$TESTTMP/asroot" -n --from "$U" --to 0:0 "$WORK/t")
assert_eq "fixids/root with --to 0:0" "fixids: 6 file(s) would be chowned to 0:0
rc=0" "$actual"

echo "[fixids] run by another user without --to, the target is still that user"
actual=$(fx "$TESTTMP/asuser" -n --from "$U" "$WORK/t")
assert_eq "fixids/non-root default target" "fixids: 6 file(s) would be chowned to 1234:1234
rc=0" "$actual"

echo "[fixids] the header's entrypoint example names the target and drops to it"
actual=$(grep -c -F -e 'fixids --from 1000:1000 --to "$HOST_UID:$HOST_GID"' -e 'setpriv --reuid "$HOST_UID" --regid "$HOST_GID"' "$FIXIDS")
assert_eq "fixids/header example uses --to and the same ids" "2" "$actual"

# =============================================================================
# Summary
# =============================================================================
print_summary "test_fixids"
[ "$FAIL" -eq 0 ]
