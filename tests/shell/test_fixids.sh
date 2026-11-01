#!/usr/bin/env bash
# test_fixids.sh: tests for shell/posix/bin/fixids (the standalone parallel chown).
# Most cases are dry runs (-n), which change nothing and need no root; stub
# `id` commands make fixids see root or another invoker. The case that really
# chowns runs only as root (the CI image runs the suites as root).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

FIXIDS="$DOTFILES/shell/posix/bin/fixids"
BASH_BIN=$(command -v bash) || abort_suite "no bash on PATH"
REAL_ID=$(command -v id) || abort_suite "no id on PATH"
REAL_FIND=$(command -v find) || abort_suite "no find on PATH"

# fx <dir to put first on PATH, or ''> <fixids args...>: stdout and stderr,
# then rc=<status>. Its temporary lists go under WORK.
fx() {
    local pre="$1"
    shift
    mkdir -p "$WORK/tmp"
    (PATH="$pre${pre:+:}$PATH" TMPDIR="$WORK/tmp" "$BASH_BIN" "$FIXIDS" "$@" 2>&1; echo "rc=$?")
}

# A tree of 6 entries (the root t, a, b, b/c, node_modules, node_modules/x),
# all owned by whoever runs the suite: U:G.
setup_tree() {
    rm -rf "${WORK:?}/t"
    mkdir -p "$WORK/t/b" "$WORK/t/node_modules"
    : > "$WORK/t/a"
    : > "$WORK/t/b/c"
    : > "$WORK/t/node_modules/x"
}
setup_tree
U=$(stat -c %u "$WORK/t")
G=$(stat -c %g "$WORK/t")
NEWG=$((G + 1))

# id as root sees it, and as uid/gid 1234 sees it; any other use of id (a name
# to resolve) goes to the real one.
mkdir -p "$TESTTMP/asroot" "$TESTTMP/asuser" "$TESTTMP/findlog"
printf '#!/bin/sh\ncase "$*" in -u|-g) echo 0 ;; *) exec "%s" "$@" ;; esac\n' "$REAL_ID" > "$TESTTMP/asroot/id"
printf '#!/bin/sh\ncase "$*" in -u|-g) echo 1234 ;; *) exec "%s" "$@" ;; esac\n' "$REAL_ID" > "$TESTTMP/asuser/id"
# find that logs each call
printf '#!/bin/sh\necho find >> "%s"\nexec "%s" "$@"\n' "$WORK/find.calls" "$REAL_FIND" > "$TESTTMP/findlog/find"
chmod +x "$TESTTMP/asroot/id" "$TESTTMP/asuser/id" "$TESTTMP/findlog/find"

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
# --from UID:GID: one walk
# =============================================================================
# With --from UID:GID and a target GID, fixids walked the whole tree once per
# class (both ids, uid only, gid only): three lstat()s per inode, and a later
# walk saw the files an earlier pass had already chowned. One walk now
# classifies every file before anything changes.
echo "[fixids] --from UID:GID walks the tree once"
rm -f "$WORK/find.calls"
actual=$(fx "$TESTTMP/findlog" -n --from "$U:$G" --to 2000:2000 "$WORK/t")
assert_eq "fixids/three classes counted" "fixids: 6 file(s) would be chowned to 2000:2000
fixids: 0 file(s) would be chowned to 2000
fixids: 0 file(s) would be chgrp'd to 2000
rc=0" "$actual"
assert_eq "fixids/one find call" "1" "$(wc -l < "$WORK/find.calls" | tr -d ' ')"

# A uid-only file needs a change only when the uid changes; with the same uid
# that pass is skipped (it used to re-chown the files the first pass had just
# re-grouped, which now matched it).
echo "[fixids] --to with the --from uid leaves out the uid-only pass"
actual=$(fx "" -n --from "$U:$G" --to "$U:$NEWG" "$WORK/t")
assert_eq "fixids/same uid: no uid-only pass" "fixids: 6 file(s) would be chowned to $U:$NEWG
fixids: 0 file(s) would be chgrp'd to $NEWG
rc=0" "$actual"

echo "[fixids] the one walk still prunes -x directories, the directory itself too"
actual=$(fx "" -n --from "$U:$G" --to "$U:$NEWG" -x node_modules "$WORK/t")
assert_eq "fixids/prune with the one walk" "fixids: 4 file(s) would be chowned to $U:$NEWG
fixids: 0 file(s) would be chgrp'd to $NEWG
rc=0" "$actual"

echo "[fixids] the class lists are removed afterwards"
actual=$(find "$WORK/tmp" -mindepth 1)
assert_eq "fixids/no lists left in TMPDIR" "" "$actual"

# A list find could not write in full ended in part of a path, and the passes
# still ran: xargs -0 handed that fragment (a prefix of a real path, which can
# name an ancestor directory) to chown. A file-size limit of one block stands
# in for a full TMPDIR. With SIGXFSZ at its default find is killed. With it
# ignored find gets EFBIG, but GNU find 4.10 reports a list it could not write
# only when closing the list fails, and closing has nothing left to write
# when the NUL after the last path met a full stdio buffer (st_blksize, 4096
# bytes on the usual file systems): the write of that buffer failed, emptied
# it and dropped the NUL, and find exits 0 without a message. Whether a tree
# of many files ended that way hung on the length of TMPDIR. The tree here
# has a root path longer than a block, so the one-block list always ends
# inside that first name, and one file in it whose path ends the list's
# paths at 4096 bytes (2 * root + 2 + name), so that find exits 0 (up to a
# TMPDIR of about 2000 characters, past which the name has no room left).
# Either way fixids now stops before any pass. A probe first checks that the
# limit holds here.
_long=$(readlink -f -- "$WORK")/cut
while [ "${#_long}" -lt 1920 ]; do _long=$_long/$(printf '%100s' '' | tr ' ' d); done
mkdir -p "$_long"
_name=$((4094 - 2 * ${#_long}))
[ "$_name" -lt 1 ] || : > "$_long/$(printf "%${_name}s" '' | tr ' ' f)"
_fsz=$("$BASH_BIN" -c 'trap "" XFSZ; ulimit -f 1; head -c 4096 /dev/zero > "$1" 2>/dev/null; stat -c %s "$1"' _ "$WORK/fsz.probe")
rm -f "$WORK/fsz.probe"
for _xfsz in ignored default; do
    echo "[fixids] a class list cut short (SIGXFSZ $_xfsz) stops the run before any pass"
    if ! [ "${_fsz:-4096}" -lt 4096 ] 2>/dev/null; then
        echo "  SKIP: fixids/cut list (ulimit -f does not limit writes here)"
        continue
    fi
    if [ "$_xfsz" = ignored ]; then _trap='trap "" XFSZ;'; else _trap='trap - XFSZ;'; fi
    actual=$(mkdir -p "$WORK/tmp"; PATH="$PATH" TMPDIR="$WORK/tmp" "$BASH_BIN" -c "$_trap ulimit -f 1; exec \"\$0\" \"\$@\"" "$BASH_BIN" "$FIXIDS" -n --from "$U:$G" --to 2000:2000 "$_long" 2>&1; echo "rc=$?")
    assert_contains "fixids/cut list ($_xfsz): stops" "nothing was changed" "$actual"
    assert_contains "fixids/cut list ($_xfsz): names the lists" "fixids: the file lists under $WORK/tmp are incomplete (find exit " "$actual"
    assert_not_contains "fixids/cut list ($_xfsz): no pass ran" "would be" "$actual"
    assert_eq "fixids/cut list ($_xfsz): exit 1" "rc=1" "$(printf '%s\n' "$actual" | tail -n 1)"
    assert_eq "fixids/cut list ($_xfsz): lists removed" "" "$(find "$WORK/tmp" -mindepth 1)"
done
rm -rf "${WORK:?}/cut"

# The same stop for a list cut by hand, in each of the three lists, which does
# not hang on how find writes: a find stand-in runs the real one, then leaves
# in the list named by CUT the "both" list's paths less the last NUL and the
# character before it (a list that ends inside a path) and exits 0 without a
# message. fixids used to run its passes over such a list.
mkdir -p "$TESTTMP/cutfind"
{
    printf '#!/bin/sh\n"%s" "$@" || exit\n' "$REAL_FIND"
    cat <<'EOF'
for a do
    case $a in */both) b=$a ;; esac
    case $a in */"$CUT") c=$a ;; esac
done
head -c -2 -- "$b" > "$c.cut" && mv -- "$c.cut" "$c"
EOF
} > "$TESTTMP/cutfind/find"
chmod +x "$TESTTMP/cutfind/find"
for _list in both uid gid; do
    echo "[fixids] a $_list list that ends inside a path stops the run, though find exits 0"
    actual=$(CUT=$_list fx "$TESTTMP/cutfind" -n --from "$U:$G" --to 2000:2000 "$WORK/t")
    assert_contains "fixids/hand-cut $_list list: stops" "fixids: the file lists under $WORK/tmp are incomplete (find exit 0); nothing was changed" "$actual"
    assert_not_contains "fixids/hand-cut $_list list: no pass ran" "would be" "$actual"
    assert_eq "fixids/hand-cut $_list list: exit 1" "rc=1" "$(printf '%s\n' "$actual" | tail -n 1)"
    assert_eq "fixids/hand-cut $_list list: lists removed" "" "$(find "$WORK/tmp" -mindepth 1)"
done

# The two older stops, which no cut above reaches: the stand-ins below run the
# real find, which writes every list in full (each ends in a NUL), and then
# report a failure. One names a list in a message and exits 1, as find does
# when it cannot write or close a list; the other exits 2 without a message
# (find's own errors give exit 1, so another status means find was stopped or
# never ran). A list may then lack paths, so fixids stops before any pass.
mkdir -p "$TESTTMP/msgfind" "$TESTTMP/rc2find"
{
    printf '#!/bin/sh\n"%s" "$@" || exit\n' "$REAL_FIND"
    cat <<'EOF'
p=
for a do
    [ "$p" != -fprint0 ] || l=$a
    p=$a
done
echo "find: '$l': No space left on device" >&2
exit 1
EOF
} > "$TESTTMP/msgfind/find"
printf '#!/bin/sh\n"%s" "$@" || exit\nexit 2\n' "$REAL_FIND" > "$TESTTMP/rc2find/find"
chmod +x "$TESTTMP/msgfind/find" "$TESTTMP/rc2find/find"

echo "[fixids] find naming a list in a message stops the run, though every list ends in a NUL"
actual=$(fx "$TESTTMP/msgfind" -n --from "$U:$G" --to 2000:2000 "$WORK/t")
assert_contains "fixids/list named in a message: stops" "fixids: the file lists under $WORK/tmp are incomplete (find exit 1); nothing was changed" "$actual"
assert_not_contains "fixids/list named in a message: no pass ran" "would be" "$actual"
assert_eq "fixids/list named in a message: exit 1" "rc=1" "$(printf '%s\n' "$actual" | tail -n 1)"

echo "[fixids] find exiting 2 stops the run, though every list ends in a NUL"
actual=$(fx "$TESTTMP/rc2find" -n --from "$U:$G" --to 2000:2000 "$WORK/t")
assert_contains "fixids/find exit 2: stops" "fixids: the file lists under $WORK/tmp are incomplete (find exit 2); nothing was changed" "$actual"
assert_not_contains "fixids/find exit 2: no pass ran" "would be" "$actual"
assert_eq "fixids/find exit 2: exit 1" "rc=1" "$(printf '%s\n' "$actual" | tail -n 1)"

# An unreadable directory is a walk error, not a list error: the passes still
# run over what find could read, and the run fails. Root reads any directory.
echo "[fixids] an unreadable directory still lets the passes run"
if [ "$(id -u)" -ne 0 ]; then
    setup_tree
    chmod 000 "$WORK/t/b"
    actual=$(fx "" -n --from "$U:$G" --to "$U:$NEWG" "$WORK/t")
    chmod 755 "$WORK/t/b"
    assert_contains "fixids/unreadable dir: walk error reported" "fixids: find reported errors; the walk was incomplete" "$actual"
    assert_contains "fixids/unreadable dir: passes ran" "fixids: 5 file(s) would be chowned to $U:$NEWG" "$actual"
    assert_eq "fixids/unreadable dir: exit 1" "rc=1" "$(printf '%s\n' "$actual" | tail -n 1)"
else
    echo "  SKIP: fixids/unreadable dir (root reads every directory)"
fi

# =============================================================================
# One class: a checked list too
# =============================================================================
# Without --from UID:GID and a --to GID there is one class (no --from, a
# --from without a GID, or a --to without one), and its pass read find's
# output through a pipe as find walked. A find killed mid-walk left that
# stream ending inside a path, and xargs handed the fragment, a prefix of a
# real path (an ancestor directory, or one -x excluded), to chown. That pass
# now reads a list the walk checked first, as the three classes do. A find
# stand-in runs the real one, then leaves what it wrote (its output, and each
# -fprint0 list) less the last NUL and the character before it, and dies of
# SIGKILL (CUTEND=sigkill) or exits 0 without a message (CUTEND=0). chown and
# chgrp stand-ins only log their arguments, so these real runs change nothing.
mkdir -p "$TESTTMP/cutall"
{
    printf '#!/bin/sh\nout="%s"\n"%s" "$@" > "$out" || exit\n' "$WORK/cutall.out" "$REAL_FIND"
    cat <<'EOF'
p=
for a do
    if [ "$p" = -fprint0 ]; then head -c -2 -- "$a" > "$a.cut" && mv -- "$a.cut" "$a"; fi
    p=$a
done
head -c -2 -- "$out"
[ "$CUTEND" != sigkill ] || kill -KILL $$
EOF
} > "$TESTTMP/cutall/find"
for t in chown chgrp; do
    printf '#!/bin/sh\necho "%s $*" >> "%s"\n' "$t" "$WORK/cutall.calls" > "$TESTTMP/cutall/$t"
done
chmod +x "$TESTTMP/cutall/find" "$TESTTMP/cutall/chown" "$TESTTMP/cutall/chgrp"
for _mode in "--from UID" "--to UID:GID" "--to UID"; do
    case $_mode in
        "--from UID") _args=(--from "$U" --to 2000) ;;
        "--to UID:GID") _args=(--to 2000:2000) ;;
        *) _args=(--to 2000) ;;
    esac
    echo "[fixids] $_mode: find killed mid-walk, its list ends inside a path: no chown runs"
    rm -f "$WORK/cutall.calls"
    actual=$(CUTEND=sigkill fx "$TESTTMP/cutall" "${_args[@]}" "$WORK/t")
    assert_contains "fixids/$_mode, find killed: stops" "fixids: the file lists under $WORK/tmp are incomplete (find exit 137); nothing was changed" "$actual"
    assert_eq "fixids/$_mode, find killed: no chown ran" "" "$(cat "$WORK/cutall.calls" 2>/dev/null)"
    assert_eq "fixids/$_mode, find killed: exit 1" "rc=1" "$(printf '%s\n' "$actual" | tail -n 1)"
    echo "[fixids] $_mode: a list that ends inside a path stops the run, though find exits 0"
    rm -f "$WORK/cutall.calls"
    actual=$(CUTEND=0 fx "$TESTTMP/cutall" "${_args[@]}" "$WORK/t")
    assert_contains "fixids/$_mode, cut list: stops" "fixids: the file lists under $WORK/tmp are incomplete (find exit 0); nothing was changed" "$actual"
    assert_eq "fixids/$_mode, cut list: no chown ran" "" "$(cat "$WORK/cutall.calls" 2>/dev/null)"
    assert_eq "fixids/$_mode, cut list: exit 1" "rc=1" "$(printf '%s\n' "$actual" | tail -n 1)"
done

# =============================================================================
# TMPDIR inside a walked root
# =============================================================================
# Every mode makes its list directory under TMPDIR before the walk, and find
# opens the -fprint0 lists as it reads its arguments. With TMPDIR inside a
# root (`fixids --force --to U:G /` with the default /tmp, or a TMPDIR under
# the home being fixed), the walk selected that directory and its lists: -n
# counted them, and a real run handed chown the list xargs was still reading.
# The tree is t plus t/tmp as TMPDIR, 7 entries: t/tmp is the user's and is
# selected, what fixids makes in it is not. chown and chgrp stand-ins print
# and log each path they are handed.
mkdir -p "$TESTTMP/chpaths"
for t in chown chgrp; do
    printf '#!/bin/sh\nshift 3\nfor p do printf "%%s\\n" "$p"; printf "%%s\\n" "$p" >> "%s"; done\n' "$WORK/chpaths.log" > "$TESTTMP/chpaths/$t"
done
chmod +x "$TESTTMP/chpaths/chown" "$TESTTMP/chpaths/chgrp"
for _mode in "--from UID" "--to UID:GID" "--to UID" "--from UID:GID"; do
    case $_mode in
        "--from UID") _args=(--from "$U" --to 2000) _tgt=2000 _more="" ;;
        "--to UID:GID") _args=(--to 2000:2000) _tgt=2000:2000 _more="" ;;
        "--to UID") _args=(--to 2000) _tgt=2000 _more="" ;;
        *) _args=(--from "$U:$G" --to 2000:2000) _tgt=2000:2000 _more="
fixids: 0 file(s) would be chowned to 2000
fixids: 0 file(s) would be chgrp'd to 2000" ;;
    esac
    echo "[fixids] $_mode with TMPDIR inside the root: the walk leaves out fixids' own lists"
    setup_tree
    mkdir "$WORK/t/tmp"
    actual=$(TMPDIR="$WORK/t/tmp" "$BASH_BIN" "$FIXIDS" -n "${_args[@]}" "$WORK/t" 2>&1; echo "rc=$?")
    assert_eq "fixids/$_mode, TMPDIR in the root: count" "fixids: 7 file(s) would be chowned to $_tgt$_more
rc=0" "$actual"
    rm -f "$WORK/chpaths.log"
    actual=$(PATH="$TESTTMP/chpaths:$PATH" TMPDIR="$WORK/t/tmp" "$BASH_BIN" "$FIXIDS" "${_args[@]}" "$WORK/t" 2>&1; echo "rc=$?")
    assert_eq "fixids/$_mode, TMPDIR in the root: real run" "fixids: chowned 7 file(s) to $_tgt
rc=0" "$actual"
    assert_not_contains "fixids/$_mode, TMPDIR in the root: no list chowned" "$WORK/t/tmp/" "$(cat "$WORK/chpaths.log" 2>/dev/null)"
done
# The roots are canonicalized and TMPDIR is not, so the prune goes by inode.
echo "[fixids] TMPDIR inside the root through a symlink: the walk still leaves out the lists"
setup_tree
mkdir "$WORK/t/tmp"
ln -s t/tmp "$WORK/tmplink"
actual=$(TMPDIR="$WORK/tmplink" "$BASH_BIN" "$FIXIDS" -n --to 2000 "$WORK/t" 2>&1; echo "rc=$?")
assert_eq "fixids/TMPDIR in the root through a symlink: count" "fixids: 7 file(s) would be chowned to 2000
rc=0" "$actual"
rm -f "$WORK/tmplink"
setup_tree

# =============================================================================
# A real run (root only)
# =============================================================================
# Each class gets exactly its change, once: logging chown / chgrp stand-ins
# call the real tools. 1000:1000 -> 1000:2000 (both ids), 1000:3000 stays
# (uid only, and the uid does not change), 3000:1000 -> 3000:2000 (gid only),
# 3000:3000 stays.
echo "[fixids] a real --from 1000:1000 --to 1000:2000 run changes each class once"
if [ "$(id -u)" -eq 0 ]; then
    rm -rf "${WORK:?}/r" "$TESTTMP/chlog"
    mkdir -p "$WORK/r" "$TESTTMP/chlog"
    for f in a b c d; do : > "$WORK/r/$f"; done
    chown 1000:1000 "$WORK/r" "$WORK/r/a"
    chown 1000:3000 "$WORK/r/b"
    chown 3000:1000 "$WORK/r/c"
    chown 3000:3000 "$WORK/r/d"
    for t in chown chgrp; do
        printf '#!/bin/sh\necho "%s $3" >> "%s"\nexec "%s" "$@"\n' "$t" "$WORK/ch.calls" "$(command -v "$t")" > "$TESTTMP/chlog/$t"
        chmod +x "$TESTTMP/chlog/$t"
    done
    rm -f "$WORK/ch.calls"
    actual=$(fx "$TESTTMP/chlog" --from 1000:1000 --to 1000:2000 "$WORK/r")
    assert_eq "fixids/real run summary" "fixids: chowned 2 file(s) to 1000:2000
fixids: chgrp'd 1 file(s) to 2000
rc=0" "$actual"
    actual=$(cd "$WORK/r" && stat -c '%n %u:%g' . a b c d)
    assert_eq "fixids/real run owners" ". 1000:2000
a 1000:2000
b 1000:3000
c 3000:2000
d 3000:3000" "$actual"
    assert_eq "fixids/real run: one chown and one chgrp call, no uid-only chown" "chgrp 2000
chown 1000:2000" "$(sort "$WORK/ch.calls")"
else
    echo "  SKIP: fixids/real run (needs root)"
fi

# =============================================================================
# Summary
# =============================================================================
print_summary "test_fixids"
[ "$FAIL" -eq 0 ]
