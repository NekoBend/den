#!/usr/bin/env bash
# test_functions.sh — Tests for functions.sh (bash/zsh) and functions.ps1 (pwsh).
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

HELPERS_SH="$DOTFILES/shell/posix/_helpers.sh"
FUNCTIONS_SH_GUARDED="$DOTFILES/shell/posix/functions.sh"
FUNCTIONS_SH="/tmp/functions_test_$$.sh"
HELPERS_PS1="$DOTFILES/shell/pwsh/_helpers.ps1"
FUNCTIONS_PS1="$DOTFILES/shell/pwsh/functions.ps1"

make_noninteractive_source_copy "$FUNCTIONS_SH_GUARDED" "$FUNCTIONS_SH"

# PowerShell functions.ps1 now depends on _helpers.ps1 (Initialize-Cache).
# Create a combined PS1 that loads helpers first.
FUNCTIONS_PS1_COMBINED="/tmp/functions_combined_$$.ps1"
{
    echo ". '$HELPERS_PS1'"
    cat "$FUNCTIONS_PS1"
} > "$FUNCTIONS_PS1_COMBINED"
_cleanup_functions() { rm -f "$FUNCTIONS_PS1_COMBINED" "$FUNCTIONS_SH"; }
trap '_cleanup_functions' EXIT

# =============================================================================
# Helper: create a known test file for hash tests
# =============================================================================
setup_hash_file() {
    echo -n "test content" > "$WORK/hashfile.txt"
}

# Expected hashes of "test content" (no trailing newline)
EXPECTED_MD5="9473fdd0d880a43c21b7778d34872157"
EXPECTED_SHA256="6ae8a75555209fd6c44157c0aed8016e763ff435a19cf186f76863140143ff72"
EXPECTED_SHA512="0cbf4caef38047bba9a24e621a961484e5d2a92176a859e7eb27df343dd34eb98d538a6c5f4da1ce302ec250b821cc001e46cc97a704988297185a4df7e99602"

# A source file whose NAME is a GNU tar option: --checkpoint-action=exec=CMD
# makes tar run CMD, so while archive() passed sources on without an
# end-of-options marker, `archive out.tgz *` in a directory holding such a
# file handed the archiver arbitrary command execution.
CRAFTED_SRC='--checkpoint-action=exec=touch pwned'
CRAFTED_TRIGGER='--checkpoint=1'

setup_crafted() {
    rm -rf "$WORK"/*
    mkdir -p "$WORK/crafted"
    # Both names are needed for the exec to fire: --checkpoint=1 turns
    # checkpointing on, --checkpoint-action says what to run at each one. They
    # sort before bait.txt, so nothing benign precedes them in the glob and
    # bait.txt is the operand that makes tar write (and checkpoint) at all.
    : > "$WORK/crafted/$CRAFTED_TRIGGER"
    : > "$WORK/crafted/$CRAFTED_SRC"
    echo bait > "$WORK/crafted/bait.txt"
}

# A file whose name contains PowerShell wildcard characters, next to the file
# that name would match if it were read as a wildcard instead of literally.
setup_wildcard() {
    rm -rf "$WORK"/*
    mkdir -p "$WORK/wild"
    printf 'real'  > "$WORK/wild/f[1].txt"
    printf 'decoy' > "$WORK/wild/f1.txt"
}

# What an archiver is actually handed cannot be read off the extracted result,
# so these cases run against stub archivers on PATH that record their argv.
# 7z is not in tests/shell/Dockerfile (the CI test image), which is the other
# reason its branches need a stub at all.
#
# The names being defended against: every one of these tools reads a leading
# '-' as a switch, and 7z additionally reads a leading '@' as a LISTFILE — it
# would act on the paths named INSIDE that file rather than on the file
# itself. The 7z branches have no '--' marker to fall back on, so both forms
# must reach them already neutralised with './'.
STUB_ARGV="$WORK/stub-argv.txt"

setup_archiver_stubs() {
    rm -rf "$WORK"/*
    mkdir -p "$WORK/stubbin" "$WORK/stubsrc"
    # sources for archive(), and archives for extract(), one per branch shape
    # a stub can observe (the .zip branch is a cmdlet on pwsh, so it is not
    # one of them)
    : > "$WORK/stubsrc/-x"
    : > "$WORK/stubsrc/@list"
    : > "$WORK/stubsrc/-x.7z"
    : > "$WORK/stubsrc/@a.7z"
    : > "$WORK/stubsrc/-x.tar.gz"
    : > "$WORK/stubsrc/-x.gz"
    : > "$WORK/stubsrc/-x.rar"
    for _stub in 7z tar gzip unrar; do
        cat > "$WORK/stubbin/$_stub" <<STUB
#!/bin/sh
printf '%s\n' "\$@" > '$STUB_ARGV'
STUB
        chmod +x "$WORK/stubbin/$_stub"
    done
    unset _stub
    rm -f "$STUB_ARGV"
}

# A single-file compression fixture: one payload in its own directory, plus an
# empty dir to use as a PATH with none of the compressors on it. The payload is
# random BYTES, not text, because the pwsh branch sends the compressor's stdout
# through a redirection: a text fixture would not catch it if those bytes were
# ever re-encoded on the way to the file. $PAYLOAD_SHA is recomputed here so a
# round trip is checked against the exact source that went in.
PAYLOAD_SHA=""
setup_single_file() {
    rm -rf "$WORK"/*
    mkdir -p "$WORK/one" "$WORK/nobin"
    head -c 65536 /dev/urandom > "$WORK/one/payload.bin"
    PAYLOAD_SHA=$(sha256sum "$WORK/one/payload.bin" | cut -d' ' -f1)
}

# The single-file formats, and the tool each direction shells out to, so the
# missing-tool cases can assert the binary that branch actually names.
SINGLE_FMTS="gz bz2 xz zst"
single_tools() {
    case "$1" in
        gz)  CTOOL=gzip;  DTOOL=gunzip  ;;
        bz2) CTOOL=bzip2; DTOOL=bunzip2 ;;
        xz)  CTOOL=xz;    DTOOL=unxz    ;;
        *)   CTOOL=zstd;  DTOOL=unzstd  ;;
    esac
}
SINGLE_USAGE="usage: archive <output.gz|.bz2|.xz|.zst> <one-file>"

# sha256 of the multi-file fixture's content ("one"), uppercase as
# Get-FileHash prints it: a refusal case still has to show the good file's
# hash.
SHA256_ONE="7692C3AD3540BB803C020B3AEE66CD8887123234EA0C6E7143C0ADD73FF431ED"

# sha256 of the literal file's content ("real") and of the decoy's ("decoy")
SHA256_REAL="aa33996d60e89311b4d1a920dae03c6d7fa3ae1956c52662e273aad4683e577f"
SHA256_DECOY="bdeb9ba22af8fa73e59fe7c4d3c48ae1165617dd76c720773cdf6cbc33a91dd7"

# =============================================================================
# Bash tests
# =============================================================================
echo "================================================"
echo "  Testing functions.sh with BASH"
echo "================================================"

echo "[bash] guard: non-interactive source skips functions"
actual=$(bash -c "
    source '$FUNCTIONS_SH_GUARDED'
    type digest >/dev/null 2>&1 && echo 'DEFINED' || echo 'UNDEFINED'
" | tr -d '\r')
assert_eq "bash/guard non-interactive" "UNDEFINED" "$actual"

# --- digest ---
echo "[bash] digest md5"
setup_hash_file
actual=$(run_bash "$FUNCTIONS_SH" "digest md5 '$WORK/hashfile.txt'")
assert_eq "bash/digest md5" "$EXPECTED_MD5" "$actual"

echo "[bash] digest sha256"
setup_hash_file
actual=$(run_bash "$FUNCTIONS_SH" "digest sha256 '$WORK/hashfile.txt'")
assert_eq "bash/digest sha256" "$EXPECTED_SHA256" "$actual"

echo "[bash] digest bad algo"
actual=$(run_bash "$FUNCTIONS_SH" "digest bad '$WORK/hashfile.txt' 2>&1; echo \$?")
assert_contains "bash/digest bad usage" "usage" "$actual"

echo "[bash] digest sha512"
setup_hash_file
actual=$(run_bash "$FUNCTIONS_SH" "digest sha512 '$WORK/hashfile.txt'")
assert_eq "bash/digest sha512" "$EXPECTED_SHA512" "$actual"

# --- mkfile ---
echo "[bash] mkfile"
run_bash "$FUNCTIONS_SH" "mkfile 1K '$WORK/dummy.bin'" >/dev/null
assert_success "bash/mkfile exit code" "$?"
assert_exists "bash/mkfile created" "$WORK/dummy.bin"
actual=$(stat -c%s "$WORK/dummy.bin")
assert_eq "bash/mkfile size" "1024" "$actual"
rm -f "$WORK/dummy.bin"

echo "[bash] mkfile neutralizes a leading-dash path"
# Pre-fix `mkfile 1K -x` ran `truncate -s 1K -x` and truncate parsed -x as an
# option, so no file was made. The ./ guard makes it create a file named -x.
run_bash "$FUNCTIONS_SH" "cd '$WORK' && mkfile 1K -dashfile" >/dev/null 2>&1
assert_exists "bash/mkfile leading-dash created" "$WORK/-dashfile"
rm -f "$WORK/-dashfile"

# --- archive + extract (tar.gz) ---
echo "[bash] archive + extract tar.gz"
setup_fixtures
run_bash "$FUNCTIONS_SH" "cd '$WORK' && archive '$WORK/test.tar.gz' src" 2>/dev/null
assert_success "bash/archive tar.gz exit code" "$?"
assert_exists "bash/archive tar.gz" "$WORK/test.tar.gz"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.gz" "$WORK/extracted/"
run_bash "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract '$WORK/extracted/test.tar.gz'"
assert_success "bash/extract tar.gz exit code" "$?"
assert_exists "bash/extract tar.gz" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.gz" "$WORK/extracted"

# --- archive + extract (zip) ---
echo "[bash] archive + extract zip"
setup_fixtures
run_bash "$FUNCTIONS_SH" "cd '$WORK' && archive '$WORK/test.zip' src" 2>/dev/null
assert_success "bash/archive zip exit code" "$?"
assert_exists "bash/archive zip" "$WORK/test.zip"
mkdir -p "$WORK/extracted"
run_bash "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract '$WORK/test.zip'"
assert_success "bash/extract zip exit code" "$?"
assert_exists "bash/extract zip" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.zip" "$WORK/extracted"

# --- archive: a source named like an option must never be parsed as one ---
echo "[bash] archive neutralizes an option-shaped source name (tar.gz)"
setup_crafted
run_bash "$FUNCTIONS_SH" "cd '$WORK/crafted' && archive '$WORK/out.tar.gz' *" 2>/dev/null
assert_success "bash/archive crafted glob tar.gz exit code" "$?"
assert_not_exists "bash/archive crafted glob tar.gz ran no command" "$WORK/crafted/pwned"
actual=$(tar tzf "$WORK/out.tar.gz" 2>/dev/null)
assert_contains "bash/archive crafted glob tar.gz stored the file" "$CRAFTED_SRC" "$actual"

echo "[bash] archive treats every argument after the output as a source"
setup_crafted
run_bash "$FUNCTIONS_SH" "cd '$WORK/crafted' && archive '$WORK/out2.tar.gz' -C bait.txt" 2>/dev/null
assert_failure "bash/archive does not honour -C as a tar option" "$?"
actual=$(tar tzf "$WORK/out2.tar.gz" 2>/dev/null)
assert_contains "bash/archive stored the source that followed it" "bait.txt" "$actual"
assert_not_contains "bash/archive did not chdir for -C" "crafted" "$actual"

echo "[bash] archive neutralizes an option-shaped source name (zip)"
setup_crafted
run_bash "$FUNCTIONS_SH" "cd '$WORK/crafted' && archive '$WORK/out.zip' *" >/dev/null 2>&1
assert_success "bash/archive crafted glob zip exit code" "$?"
assert_not_exists "bash/archive crafted glob zip ran no command" "$WORK/crafted/pwned"
assert_exists "bash/archive crafted glob zip created the archive" "$WORK/out.zip"
actual=$(unzip -l "$WORK/out.zip" 2>/dev/null)
assert_contains "bash/archive crafted glob zip stored the file" "$CRAFTED_SRC" "$actual"

echo "[bash] archive 7z gets neither a switch nor a listfile"
setup_archiver_stubs
run_bash "$FUNCTIONS_SH" "export PATH='$WORK/stubbin:$PATH'; cd '$WORK/stubsrc' && archive '$WORK/out.7z' -x '@list'" >/dev/null 2>&1
assert_exists "bash/archive 7z reached the stub" "$STUB_ARGV"
actual=$(tr '\n' ' ' < "$STUB_ARGV" 2>/dev/null)
assert_eq "bash/archive 7z argv" "a $WORK/out.7z ./-x ./@list " "$actual"
assert_not_contains "bash/archive 7z got no -- marker" "--" "$actual"

echo "[bash] extract 7z gets neither a switch nor a listfile"
setup_archiver_stubs
run_bash "$FUNCTIONS_SH" "export PATH='$WORK/stubbin:$PATH'; cd '$WORK/stubsrc' && extract '-x.7z'" >/dev/null 2>&1
actual=$(tr '\n' ' ' < "$STUB_ARGV" 2>/dev/null)
assert_eq "bash/extract 7z switch-shaped name" "x ./-x.7z " "$actual"
assert_not_contains "bash/extract 7z switch-shaped got no -- marker" "--" "$actual"
rm -f "$STUB_ARGV"
run_bash "$FUNCTIONS_SH" "export PATH='$WORK/stubbin:$PATH'; cd '$WORK/stubsrc' && extract '@a.7z'" >/dev/null 2>&1
actual=$(tr '\n' ' ' < "$STUB_ARGV" 2>/dev/null)
assert_eq "bash/extract 7z listfile-shaped name" "x ./@a.7z " "$actual"
assert_not_contains "bash/extract 7z listfile-shaped got no -- marker" "--" "$actual"

# --- extract: several archives in one call; one failure does not hide the rest ---
echo "[bash] extract multiple archives"
setup_fixtures
mkdir -p "$WORK/second" && echo second > "$WORK/second/file2.txt"
run_bash "$FUNCTIONS_SH" "cd '$WORK' && archive '$WORK/one.tar.gz' src && archive '$WORK/two.tar.gz' second" 2>/dev/null
mkdir -p "$WORK/multi"
run_bash "$FUNCTIONS_SH" "cd '$WORK/multi' && extract '$WORK/one.tar.gz' '$WORK/two.tar.gz'"
assert_success "bash/extract multi exit code" "$?"
assert_exists "bash/extract multi first archive" "$WORK/multi/src/file1.txt"
assert_exists "bash/extract multi second archive" "$WORK/multi/second/file2.txt"
rm -rf "$WORK/multi" && mkdir -p "$WORK/multi"
run_bash "$FUNCTIONS_SH" "cd '$WORK/multi' && extract '$WORK/one.tar.gz' '$WORK/missing.tar.gz'" 2>/dev/null
assert_eq "bash/extract multi with a missing archive exits 1" "1" "$?"
assert_exists "bash/extract multi still extracted the good archive" "$WORK/multi/src/file1.txt"
rm -rf "$WORK/one.tar.gz" "$WORK/two.tar.gz" "$WORK/second" "$WORK/multi"

echo "[bash] digest several files"
setup_fixtures
printf 'one' > "$WORK/d1.txt"; printf 'two' > "$WORK/d2.txt"
actual=$(run_bash "$FUNCTIONS_SH" "digest sha256 '$WORK/d1.txt' '$WORK/d2.txt'")
assert_success "bash/digest multi exit code" "$?"
assert_eq "bash/digest multi prints one line per file" "2" "$(printf '%s\n' "$actual" | wc -l | tr -d ' ')"
assert_contains "bash/digest multi names the file" "$WORK/d2.txt" "$actual"
run_bash "$FUNCTIONS_SH" "digest sha256 '$WORK/d1.txt' '$WORK/missing.txt'" 2>/dev/null
assert_eq "bash/digest multi with a missing file exits 1" "1" "$?"
rm -rf "$WORK/d1.txt" "$WORK/d2.txt"

# `[ -f ]` is true for a file that cannot be READ, and the hash used to be
# piped into awk, whose status is the one the pipeline reports: the *sum
# tool's "Permission denied" reached stderr while digest printed an empty
# line and returned 0. root ignores the mode bits, so there it is skipped.
echo "[bash] digest reports an unreadable file"
: > "$WORK/noread.txt"
if [ "$(id -u)" -ne 0 ] && chmod 000 "$WORK/noread.txt" 2>/dev/null && [ ! -r "$WORK/noread.txt" ]; then
    run_bash "$FUNCTIONS_SH" "digest sha256 '$WORK/noread.txt'" >/dev/null 2>&1
    assert_eq "bash/digest unreadable file exits 1" "1" "$?"
    chmod 600 "$WORK/noread.txt"
else
    echo "  SKIP: bash/digest unreadable file (running as root)"
fi
rm -f "$WORK/noread.txt"

echo "[bash] archive + extract tar.bz2"
setup_fixtures
run_bash "$FUNCTIONS_SH" "cd '$WORK' && archive '$WORK/test.tar.bz2' src" 2>/dev/null
assert_success "bash/archive tar.bz2 exit code" "$?"
assert_exists "bash/archive tar.bz2" "$WORK/test.tar.bz2"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.bz2" "$WORK/extracted/"
run_bash "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract 'test.tar.bz2'" 2>/dev/null
assert_success "bash/extract tar.bz2 exit code" "$?"
assert_exists "bash/extract tar.bz2" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.bz2" "$WORK/extracted"

echo "[bash] archive + extract tar.xz"
setup_fixtures
run_bash "$FUNCTIONS_SH" "cd '$WORK' && archive '$WORK/test.tar.xz' src" 2>/dev/null
assert_success "bash/archive tar.xz exit code" "$?"
assert_exists "bash/archive tar.xz" "$WORK/test.tar.xz"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.xz" "$WORK/extracted/"
run_bash "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract 'test.tar.xz'" 2>/dev/null
assert_success "bash/extract tar.xz exit code" "$?"
assert_exists "bash/extract tar.xz" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.xz" "$WORK/extracted"

# --- .tar.zst and its .tzst alias (the alias is what tgz/tbz2/txz are to
# --- their long forms: same branch, same tar --zstd call) ---
echo "[bash] archive + extract tar.zst / tzst"
for _ext in tar.zst tzst; do
    setup_fixtures
    run_bash "$FUNCTIONS_SH" "cd '$WORK' && archive '$WORK/test.$_ext' src" 2>/dev/null
    assert_success "bash/archive .$_ext exit code" "$?"
    assert_exists "bash/archive .$_ext" "$WORK/test.$_ext"
    mkdir -p "$WORK/extracted"
    cp "$WORK/test.$_ext" "$WORK/extracted/"
    run_bash "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract 'test.$_ext'" 2>/dev/null
    assert_success "bash/extract .$_ext exit code" "$?"
    assert_exists "bash/extract .$_ext" "$WORK/extracted/src/file1.txt"
done

# --- single-file compression: one source in, the named output out, source kept
echo "[bash] archive + extract single-file formats"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    run_bash "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'payload.bin.$_ext' payload.bin" 2>/dev/null
    assert_success "bash/archive single-file .$_ext exit code" "$?"
    assert_exists "bash/archive single-file .$_ext wrote the output" "$WORK/one/payload.bin.$_ext"
    assert_exists "bash/archive single-file .$_ext kept the source" "$WORK/one/payload.bin"
    mkdir -p "$WORK/back"
    cp "$WORK/one/payload.bin.$_ext" "$WORK/back/"
    run_bash "$FUNCTIONS_SH" "cd '$WORK/back' && extract 'payload.bin.$_ext'" 2>/dev/null
    assert_success "bash/extract single-file .$_ext exit code" "$?"
    actual=$(sha256sum "$WORK/back/payload.bin" 2>/dev/null | cut -d' ' -f1)
    assert_eq "bash/extract single-file .$_ext round-trips the bytes" "$PAYLOAD_SHA" "$actual"
done

# These four tools compress exactly one file: a second source or a directory
# has to be refused, not quietly turned into a tarball or applied to arg one.
echo "[bash] archive single-file refuses several sources and directories"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    cp "$WORK/one/payload.bin" "$WORK/one/second.bin"
    err=$(run_bash_stderr "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'multi.$_ext' payload.bin second.bin")
    assert_contains "bash/archive .$_ext several sources usage" "$SINGLE_USAGE" "$err"
    run_bash "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'multi.$_ext' payload.bin second.bin" 2>/dev/null
    assert_eq "bash/archive .$_ext several sources exits 1" "1" "$?"
    assert_not_exists "bash/archive .$_ext several sources wrote nothing" "$WORK/one/multi.$_ext"
    run_bash "$FUNCTIONS_SH" "cd '$WORK' && archive '$WORK/dir.$_ext' one" 2>/dev/null
    assert_eq "bash/archive .$_ext directory exits 1" "1" "$?"
    assert_not_exists "bash/archive .$_ext directory wrote nothing" "$WORK/dir.$_ext"
done

# A compressor missing from PATH is a named per-item failure, not a "command
# not found" and not a truncated output file: archive's guard runs BEFORE the
# redirection that would create it.
echo "[bash] archive and extract report a missing compressor"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    single_tools "$_ext"
    err=$(run_bash_stderr "$FUNCTIONS_SH" "export PATH='$WORK/nobin'; cd '$WORK/one' && archive 'gone.$_ext' payload.bin")
    assert_contains "bash/archive missing $CTOOL message" "archive: $CTOOL is not installed" "$err"
    run_bash "$FUNCTIONS_SH" "export PATH='$WORK/nobin'; cd '$WORK/one' && archive 'gone.$_ext' payload.bin" 2>/dev/null
    assert_eq "bash/archive missing $CTOOL exits 1" "1" "$?"
    assert_not_exists "bash/archive missing $CTOOL wrote nothing" "$WORK/one/gone.$_ext"
    mkdir -p "$WORK/noload"
    run_bash "$FUNCTIONS_SH" "cd '$WORK/one' && archive '$WORK/noload/payload.bin.$_ext' payload.bin" 2>/dev/null
    err=$(run_bash_stderr "$FUNCTIONS_SH" "export PATH='$WORK/nobin'; cd '$WORK/noload' && extract 'payload.bin.$_ext'")
    assert_contains "bash/extract missing $DTOOL message" "extract: $DTOOL is not installed" "$err"
    run_bash "$FUNCTIONS_SH" "export PATH='$WORK/nobin'; cd '$WORK/noload' && extract 'payload.bin.$_ext'" 2>/dev/null
    assert_eq "bash/extract missing $DTOOL exits 1" "1" "$?"
    assert_not_exists "bash/extract missing $DTOOL wrote nothing" "$WORK/noload/payload.bin"
done

# A source that does not exist used to reach the compressor, which meant the
# output had already been created or truncated by the time it failed: naming
# an existing archive as the output destroyed it. Nothing may be written.
echo "[bash] archive single-file refuses a missing source"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    printf 'PRECIOUS' > "$WORK/one/keep.$_ext"
    err=$(run_bash_stderr "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'keep.$_ext' missing.bin")
    assert_contains "bash/archive .$_ext missing source usage" "$SINGLE_USAGE" "$err"
    run_bash "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'keep.$_ext' missing.bin" 2>/dev/null
    assert_eq "bash/archive .$_ext missing source exits 1" "1" "$?"
    assert_eq "bash/archive .$_ext missing source left the output untouched" "PRECIOUS" "$(cat "$WORK/one/keep.$_ext" 2>/dev/null)"
    assert_not_exists "bash/archive .$_ext missing source made no new output" "$WORK/one/missing.bin.$_ext"
done

# `archive f.gz f.gz` opened f.gz for the compressor's output before reading
# it, so the source came back as a compressed EMPTY stream — and gzip/bzip2/xz
# exited 0 doing it. Spellings that resolve to the same path are refused
# outright, with the file left exactly as it was; names that reach the source
# through a link are the next block's business.
echo "[bash] archive single-file refuses an output that is the source"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    printf 'ORIGINAL' > "$WORK/one/self.$_ext"
    for _spell in "self.$_ext" "./self.$_ext"; do
        err=$(run_bash_stderr "$FUNCTIONS_SH" "cd '$WORK/one' && archive '$_spell' 'self.$_ext'")
        assert_contains "bash/archive .$_ext output '$_spell' is the source" "is the source file" "$err"
        assert_eq "bash/archive .$_ext output '$_spell' left the source intact" "ORIGINAL" "$(cat "$WORK/one/self.$_ext" 2>/dev/null)"
    done
    run_bash "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'self.$_ext' 'self.$_ext'" 2>/dev/null
    assert_eq "bash/archive .$_ext output is the source exits 1" "1" "$?"
done

# Comparing resolved paths does not establish identity: a hard link and a chain
# of symlinks name the same file by a different path, and a check that only
# compares strings lets them through. What actually keeps the source safe is
# that the compressor writes a temporary sibling of the output which is renamed
# into place afterwards — the source is never the file being written, whatever
# it is called — so what is asserted here is the source surviving, in the lane
# that refuses these and in the lane that goes ahead and compresses them.
echo "[bash] archive single-file cannot truncate the source through another name"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    ln -s payload.bin "$WORK/one/hop1.$_ext"
    ln -s "hop1.$_ext" "$WORK/one/hop2.$_ext"
    for _hop in "hop1.$_ext" "hop2.$_ext"; do
        run_bash "$FUNCTIONS_SH" "cd '$WORK/one' && archive '$_hop' payload.bin" >/dev/null 2>&1
        actual=$(sha256sum "$WORK/one/payload.bin" 2>/dev/null | cut -d' ' -f1)
        assert_eq "bash/archive .$_ext symlink '$_hop' left the source intact" "$PAYLOAD_SHA" "$actual"
    done
    if ln "$WORK/one/payload.bin" "$WORK/one/hard.$_ext" 2>/dev/null; then
        run_bash "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'hard.$_ext' payload.bin" >/dev/null 2>&1
        actual=$(sha256sum "$WORK/one/payload.bin" 2>/dev/null | cut -d' ' -f1)
        assert_eq "bash/archive .$_ext hard link left the source intact" "$PAYLOAD_SHA" "$actual"
    else
        echo "  SKIP: bash/archive .$_ext hard link (filesystem refused)"
    fi
done

# A directory sitting where the output should go is not an output. The
# single-file branch renamed its temporary INTO that directory and reported
# success with no archive written; the tar and zip branches only failed late,
# and pwsh's Compress-Archive -Force deleted the directory on the way.
echo "[bash] archive refuses a directory at the output path"
for _fmt in gz tar.gz zip; do
    setup_single_file
    mkdir -p "$WORK/one/out.$_fmt"
    err=$(run_bash_stderr "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'out.$_fmt' payload.bin")
    assert_contains "bash/archive .$_fmt directory output message" "is a directory" "$err"
    run_bash "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'out.$_fmt' payload.bin" >/dev/null 2>&1
    assert_eq "bash/archive .$_fmt directory output exits 1" "1" "$?"
    assert_exists "bash/archive .$_fmt directory output still there" "$WORK/one/out.$_fmt"
    assert_eq "bash/archive .$_fmt directory output stayed empty" "" "$(ls "$WORK/one/out.$_fmt")"
done

# A compressor that starts and then fails must not look like success: the
# partial temporary goes, an existing output keeps its contents, and the
# failure is reported. The stub exits 3 after writing to stdout, so there IS a
# partial temporary to clean up.
echo "[bash] archive reports a compressor that fails"
    setup_single_file
    mkdir -p "$WORK/stub3"
    printf '#!/bin/sh\nprintf PARTIAL\nexit 3\n' > "$WORK/stub3/gzip"
    chmod +x "$WORK/stub3/gzip"
    printf 'PRECIOUS' > "$WORK/one/keep.gz"
    run_bash "$FUNCTIONS_SH" "export PATH='$WORK/stub3:$PATH'; cd '$WORK/one' && archive 'keep.gz' payload.bin" >/dev/null 2>&1
    assert_eq "bash/archive compressor failure exits with the tool's code" "3" "$?"
    assert_eq "bash/archive compressor failure left the output untouched" "PRECIOUS" "$(cat "$WORK/one/keep.gz" 2>/dev/null)"
    assert_eq "bash/archive compressor failure left no temporary behind" "" "$(ls -A "$WORK/one" | grep -E '^\.archive\.|\.tmp\.' | tr -d '\n')"

# Staging happens inside a private 0700 directory nobody else can traverse,
# which is what keeps the name the compressor reopens from being swapped for a
# symlink. There is no fallback for a missing mktemp, deliberately: any
# predictable name would hand that window straight back. These two cases check
# the branch fails CLOSED instead -- with mktemp gone entirely, and with mktemp
# present but unable to produce a directory -- writing nothing either way.
echo "[bash] archive requires mktemp for the staging directory"
setup_single_file
# a PATH carrying the real compressor but no mktemp, so the branch gets past
# its own tool check and fails on this one
mkdir -p "$WORK/nomk"
ln -s "$(command -v gzip)" "$WORK/nomk/gzip"
err=$(run_bash_stderr "$FUNCTIONS_SH" "export PATH='$WORK/nomk'; cd '$WORK/one' && archive 'out.gz' payload.bin")
assert_contains "bash/archive missing mktemp message" "archive: mktemp is not installed" "$err"
run_bash "$FUNCTIONS_SH" "export PATH='$WORK/nomk'; cd '$WORK/one' && archive 'out.gz' payload.bin" >/dev/null 2>&1
assert_eq "bash/archive missing mktemp exits 1" "1" "$?"
assert_not_exists "bash/archive missing mktemp wrote nothing" "$WORK/one/out.gz"

# mktemp present but unable to produce a directory: refuse, rather than fall
# back to any name an attacker could have guessed. The old predictable name is
# planted as a symlink to prove nothing reaches for it any more.
echo "[bash] archive falls back to no predictable name when mktemp fails"
setup_single_file
mkdir -p "$WORK/failmk"
printf '#!/bin/sh\nexit 1\n' > "$WORK/failmk/mktemp"
chmod +x "$WORK/failmk/mktemp"
printf 'VICTIM' > "$WORK/one/victim"
run_bash "$FUNCTIONS_SH" "export PATH='$WORK/failmk:$PATH'; cd '$WORK/one' && ln -s victim \"out.gz.tmp.\$\$\" && archive 'out.gz' payload.bin" >/dev/null 2>&1
assert_eq "bash/archive unusable mktemp exits nonzero" "1" "$?"
assert_eq "bash/archive unusable mktemp touched no predictable name" "VICTIM" "$(cat "$WORK/one/victim" 2>/dev/null)"
assert_not_exists "bash/archive unusable mktemp produced no output" "$WORK/one/out.gz"
# '.archive.' only here: the fixture deliberately plants a file whose own name
# ends in .tmp.<pid>, and that plant is the point of the case, not a leftover.
assert_eq "bash/archive unusable mktemp left no staging directory" "" "$(ls -A "$WORK/one" | grep '^\.archive\.' | tr -d '\n')"

# Publishing the staged archive can fail on its own (a read-only directory, a
# full disk). The staged file must not be left lying around as a stray .tmp,
# and the failure must be reported. A stub mv makes it fail as any user.
echo "[bash] archive cleans up when the publish fails"
setup_single_file
mkdir -p "$WORK/stubmv"
printf '#!/bin/sh\nexit 7\n' > "$WORK/stubmv/mv"
chmod +x "$WORK/stubmv/mv"
run_bash "$FUNCTIONS_SH" "export PATH='$WORK/stubmv:$PATH'; cd '$WORK/one' && archive 'out.gz' payload.bin" >/dev/null 2>&1
assert_eq "bash/archive publish failure exits with mv's code" "7" "$?"
assert_not_exists "bash/archive publish failure wrote no output" "$WORK/one/out.gz"
assert_eq "bash/archive publish failure left no temporary behind" "" "$(ls -A "$WORK/one" | grep -E '^\.archive\.|\.tmp\.' | tr -d '\n')"

# What actually closes the symlink race is WHERE the archive is staged: mktemp
# creates a file exclusively, but the compressor reopens it by name, and in a
# directory others can write to that name can be unlinked and replaced in
# between. A 0700 directory nobody else can traverse removes the window. The
# stub records the path it was handed and that directory's mode, so both are
# checked directly rather than inferred.
echo "[bash] archive stages inside a private directory"
setup_single_file
mkdir -p "$WORK/stagebin"
cat > "$WORK/stagebin/zstd" <<'STUB'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
printf '%s %s\n' "$out" "$(ls -ld "${out%/*}" | cut -c1-10)" > "$STAGE_LOG"
printf 'STUB' > "$out"
STUB
chmod +x "$WORK/stagebin/zstd"
run_bash "$FUNCTIONS_SH" "export PATH='$WORK/stagebin:$PATH' STAGE_LOG='$WORK/stage.log'; cd '$WORK/one' && archive 'out.zst' payload.bin" >/dev/null 2>&1
assert_success "bash/archive staged run exit code" "$?"
assert_contains "bash/archive staged in a .archive directory" "/.archive." "$(cat "$WORK/stage.log" 2>/dev/null)"
assert_contains "bash/archive staging directory is private" "drwx------" "$(cat "$WORK/stage.log" 2>/dev/null)"
assert_exists "bash/archive published the staged file" "$WORK/one/out.zst"
assert_eq "bash/archive removed the staging directory" "" "$(ls -A "$WORK/one" | grep '^\.archive\.' | tr -d '\n')"

# 'command -v' answers with the bare name for a shell function, so a local
# `gzip` passed the availability check and then took the call itself. Two
# halves: with the real gzip on PATH the function must never run and the round
# trip must still work; with only the function and no binary the branch must
# say the tool is missing rather than run it.
echo "[bash] archive and extract run the program, not a shell function"
setup_single_file
SHADOW="gzip() { echo ran > '$WORK/one/shadow-marker'; }; zstd() { echo ran > '$WORK/one/shadow-marker'; }"
run_bash "$FUNCTIONS_SH" "true; $SHADOW; cd '$WORK/one' && archive 'payload.bin.gz' payload.bin && archive 'payload.bin.zst' payload.bin" >/dev/null 2>&1
assert_success "bash/archive shadowed run exit code" "$?"
assert_not_exists "bash/archive ran no shadowing function" "$WORK/one/shadow-marker"
assert_exists "bash/archive still wrote the real .gz" "$WORK/one/payload.bin.gz"
assert_exists "bash/archive still wrote the real .zst" "$WORK/one/payload.bin.zst"
mkdir -p "$WORK/back"
cp "$WORK/one/payload.bin.gz" "$WORK/back/"
run_bash "$FUNCTIONS_SH" "true; gunzip() { echo ran > '$WORK/back/shadow-marker'; }; cd '$WORK/back' && extract 'payload.bin.gz'" >/dev/null 2>&1
assert_not_exists "bash/extract ran no shadowing function" "$WORK/back/shadow-marker"
assert_eq "bash/extract round-trips past the shadowing function" "$PAYLOAD_SHA" "$(sha256sum "$WORK/back/payload.bin" 2>/dev/null | cut -d' ' -f1)"

# A function is not an installed program: with no gzip binary reachable, the
# branch must report it missing instead of calling the function.
echo "[bash] archive does not accept a shell function as the compressor"
setup_single_file
mkdir -p "$WORK/nogzip"
for _t in mktemp mv rm chmod ls; do
    _p=$(command -v "$_t") && ln -sf "$_p" "$WORK/nogzip/$_t"
done
err=$(run_bash_stderr "$FUNCTIONS_SH" "export PATH='$WORK/nogzip'; gzip() { echo ran > '$WORK/one/shadow-marker'; }; cd '$WORK/one' && archive 'out.gz' payload.bin")
assert_contains "bash/archive function-only gzip reported missing" "archive: gzip is not installed" "$err"
assert_not_exists "bash/archive function-only gzip never ran" "$WORK/one/shadow-marker"
assert_not_exists "bash/archive function-only gzip wrote nothing" "$WORK/one/out.gz"

echo "[bash] extract unsupported format"
touch "$WORK/test.foo"
actual=$(run_bash "$FUNCTIONS_SH" "extract '$WORK/test.foo' 2>&1")
assert_contains "bash/extract unsupported" "unsupported" "$actual"
rm -f "$WORK/test.foo"

# --- path ---
echo "[bash] path"
actual=$(run_bash "$FUNCTIONS_SH" "path")
assert_contains "bash/path contains /usr" "/usr" "$actual"

# --- up ---
echo "[bash] up"
actual=$(run_bash "$FUNCTIONS_SH" "mkdir -p '$WORK/a/b/c' && cd '$WORK/a/b/c' && up 2 && pwd")
assert_eq "bash/up 2" "$WORK/a" "$actual"

# --- mkcd ---
echo "[bash] mkcd"
actual=$(run_bash "$FUNCTIONS_SH" "mkcd '$WORK/newdir' && pwd")
assert_eq "bash/mkcd" "$WORK/newdir" "$actual"
assert_exists "bash/mkcd dir" "$WORK/newdir"
rm -rf "$WORK/newdir"

# --- again / sagain / back ---
echo "[bash] again 0"
err=$(run_bash_stderr "$FUNCTIONS_SH" "again 0")
assert_contains "bash/again 0 usage" "usage" "$err"

echo "[bash] again abc"
err=$(run_bash_stderr "$FUNCTIONS_SH" "again abc")
assert_contains "bash/again abc usage" "usage" "$err"

echo "[bash] again no history"
err=$(run_bash_stderr "$FUNCTIONS_SH" "again")
assert_contains "bash/again no history" "no command at position" "$err"

echo "[bash] sagain 0"
err=$(run_bash_stderr "$FUNCTIONS_SH" "sagain 0")
assert_contains "bash/sagain 0 usage" "usage" "$err"

echo "[bash] back 0"
err=$(run_bash_stderr "$FUNCTIONS_SH" "back 0")
assert_contains "bash/back 0 usage" "usage" "$err"

# back N>1 is supported now (browser-style history); with nothing recorded
# yet it reports the empty history instead of "only N=1".
echo "[bash] back 2 with no history"
err=$(run_bash_stderr "$FUNCTIONS_SH" "back 2")
assert_contains "bash/back 2 with no history" "history has 0 back entries" "$err"

echo "[bash] back with OLDPWD"
actual=$(run_bash "$FUNCTIONS_SH" "cd /tmp && cd / && back" 2>/dev/null)
assert_eq "bash/back OLDPWD" "/tmp" "$actual"

# --- directory history: back / fwd (browser-style) ---
# Every case starts a fresh shell in $DH/start (where the history begins) with
# HOME=$DH, so `back -l` shows ~ forms. The fzf stub prints the input line
# whose label is $FZF_PICK, the way a user's pick would come back from fzf.
DH="$WORK/dh"
setup_dirhist() {
    rm -rf "$DH"
    mkdir -p "$DH/start" "$DH/a" "$DH/b" "$DH/c" "$DH/fzfbin" "$DH/nobin"
    cat > "$DH/fzfbin/fzf" <<'STUB'
#!/bin/sh
while IFS= read -r line; do
    l=${line#"${line%%[! ]*}"}
    [ "${l%% *}" = "$FZF_PICK" ] && printf '%s\n' "$line"
done
exit 0
STUB
    chmod +x "$DH/fzfbin/fzf"
}

# dh_run <shell> <commands> - stdout and stderr, in order
dh_run() {
    (cd "$DH/start" && HOME="$DH" "$1" -c "source '$FUNCTIONS_SH' && $2" 2>&1)
}

dirhist_posix_cases() {
    local sh="$1" out bad
    setup_dirhist

    echo "[$sh] back N / fwd N"
    out=$(dh_run "$sh" "cd '$DH/a' && cd '$DH/b' && cd '$DH/c' && back 2 && fwd && fwd")
    assert_eq "$sh/back 2, fwd, fwd" "$DH/a
$DH/b
$DH/c" "$out"
    out=$(dh_run "$sh" "cd '$DH/a' && cd '$DH/b' && back 2 >/dev/null && fwd 2")
    assert_eq "$sh/back 2 then fwd 2 returns" "$DH/b" "$out"

    echo "[$sh] back -l"
    out=$(dh_run "$sh" "cd '$DH' && cd / && cd '$DH/b' && cd '$DH/c' && back 2 >/dev/null && back -l")
    assert_eq "$sh/back -l lists back, current and forward" "  2  ~/start
  1  ~
  *  /
 +1  ~/b
 +2  ~/c" "$out"

    echo "[$sh] a consecutive duplicate is recorded once"
    out=$(dh_run "$sh" "cd '$DH/a' && cd '$DH/a' && cd . && back -l")
    assert_eq "$sh/no consecutive duplicates" "  1  ~/start
  *  ~/a" "$out"

    echo "[$sh] a new move clears the forward list"
    out=$(dh_run "$sh" "cd '$DH/a' && cd '$DH/b' && back >/dev/null && cd '$DH/c' && fwd; echo rc=\$?; pwd")
    assert_eq "$sh/new move clears forward" "fwd: history has 0 forward entries, cannot go forward 1
rc=1
$DH/c" "$out"

    echo "[$sh] N larger than the history"
    out=$(dh_run "$sh" "cd '$DH/a' && cd '$DH/b' && back 5; echo rc=\$?; pwd")
    assert_eq "$sh/back 5 says how many and stays" "back: history has 2 back entries, cannot go back 5
rc=1
$DH/b" "$out"
    out=$(dh_run "$sh" "cd '$DH/a' && back 99999999999999999999; echo rc=\$?")
    assert_eq "$sh/back huge N" "back: history has 1 back entry, cannot go back 99999999999999999999
rc=1" "$out"

    echo "[$sh] N not a positive integer"
    for bad in abc 01 -x; do
        out=$(dh_run "$sh" "back $bad; echo rc=\$?")
        assert_eq "$sh/back $bad usage" "usage: back [N | -l | -i]  (N=positive integer, default 1)
rc=1" "$out"
    done
    out=$(dh_run "$sh" "fwd 0; echo rc=\$?")
    assert_eq "$sh/fwd 0 usage" "usage: fwd [N]  (N=positive integer, default 1)
rc=1" "$out"

    echo "[$sh] a target that no longer exists is dropped"
    out=$(dh_run "$sh" "cd '$DH/a' && cd '$DH/b' && rmdir '$DH/a' && back; echo rc=\$?; pwd; back -l")
    assert_eq "$sh/removed target dropped, stays put" "back: $DH/a no longer exists, dropped from history
rc=1
$DH/b
  1  ~/start
  *  ~/b" "$out"
    mkdir -p "$DH/a"
    out=$(dh_run "$sh" "cd '$DH/a' && cd '$DH/b' && cd '$DH/c' && back 2 >/dev/null && rmdir '$DH/b' && fwd; echo rc=\$?; pwd; back -l")
    assert_eq "$sh/removed forward target dropped, stays put" "fwd: $DH/b no longer exists, dropped from history
rc=1
$DH/a
  1  ~/start
  *  ~/a
 +1  ~/c" "$out"
    mkdir -p "$DH/b"

    echo "[$sh] cd - still toggles, as a normal move"
    out=$(dh_run "$sh" "cd '$DH/a' && cd '$DH/b' && cd - >/dev/null && pwd && cd - >/dev/null && pwd && back")
    assert_eq "$sh/cd - toggles and is recorded" "$DH/a
$DH/b
$DH/a" "$out"

    echo "[$sh] the back list keeps 50 entries"
    out=$(dh_run "$sh" "i=0; while [ \$i -lt 30 ]; do cd '$DH/a'; cd '$DH/b'; i=\$((i + 1)); done; back -l | wc -l")
    assert_eq "$sh/back list capped at 50" "51" "$(printf '%s' "$out" | tr -d ' ')"

    echo "[$sh] back -i picks an entry with fzf"
    out=$(dh_run "$sh" "PATH='$DH/fzfbin':\$PATH; export FZF_PICK=2; cd '$DH/a' && cd '$DH/b' && cd '$DH/c' && back -i && FZF_PICK=+2 && back -i && FZF_PICK='*' && back -i; echo rc=\$?; pwd")
    assert_eq "$sh/back -i back, forward, current" "$DH/a
$DH/c
rc=0
$DH/c" "$out"
    out=$(dh_run "$sh" "PATH='$DH/nobin'; back -i; echo rc=\$?")
    assert_eq "$sh/back -i without fzf" "back: fzf is not installed.
rc=1" "$out"
}

dirhist_posix_cases bash

# bash has no chpwd: the recorder runs from PROMPT_COMMAND, which is a string
# or (bash 5.1+) an array, and must be joined once without breaking either.
echo "[bash] PROMPT_COMMAND hook"
out=$(bash -c "source '$FUNCTIONS_SH' && printf '%s' \"\$PROMPT_COMMAND\"")
assert_eq "bash/PROMPT_COMMAND set when empty" "_den_dh_record" "$out"
out=$(bash -c "PROMPT_COMMAND='history -a; '; source '$FUNCTIONS_SH' && source '$FUNCTIONS_SH' && printf '%s' \"\$PROMPT_COMMAND\"")
assert_eq "bash/PROMPT_COMMAND string appended once" "history -a; _den_dh_record" "$out"
out=$(bash -c "PROMPT_COMMAND=(one two); source '$FUNCTIONS_SH' && source '$FUNCTIONS_SH' && declare -p PROMPT_COMMAND")
assert_eq "bash/PROMPT_COMMAND array appended once" 'declare -a PROMPT_COMMAND=([0]="one" [1]="two" [2]="_den_dh_record")' "$out"
out=$(bash -c "source '$FUNCTIONS_SH' && false; _den_dh_record; echo \$?")
assert_eq "bash/recorder keeps the exit status" "1" "$out"

echo "[bash] moves den's cd does not see are recorded at the prompt"
out=$(dh_run bash "builtin cd '$DH/a'; eval \"\$PROMPT_COMMAND\"; pushd '$DH/b' >/dev/null; eval \"\$PROMPT_COMMAND\"; mkcd '$DH/c'; eval \"\$PROMPT_COMMAND\"; back -l")
assert_eq "bash/builtin cd, pushd, mkcd recorded" "  3  ~/start
  2  ~/a
  1  ~/b
  *  ~/c" "$out"
out=$(dh_run bash "cd '$DH/a' && cd '$DH/b' && back >/dev/null && eval \"\$PROMPT_COMMAND\" && fwd")
assert_eq "bash/prompt does not record back as a new move" "$DH/b" "$out"

# =============================================================================
# Zsh tests
# =============================================================================
echo ""
echo "================================================"
echo "  Testing functions.sh with ZSH"
echo "================================================"

echo "[zsh] digest md5"
setup_hash_file
actual=$(run_zsh "$FUNCTIONS_SH" "digest md5 '$WORK/hashfile.txt'")
assert_eq "zsh/digest md5" "$EXPECTED_MD5" "$actual"

echo "[zsh] digest sha256"
setup_hash_file
actual=$(run_zsh "$FUNCTIONS_SH" "digest sha256 '$WORK/hashfile.txt'")
assert_eq "zsh/digest sha256" "$EXPECTED_SHA256" "$actual"

echo "[zsh] digest sha512"
setup_hash_file
actual=$(run_zsh "$FUNCTIONS_SH" "digest sha512 '$WORK/hashfile.txt'")
assert_eq "zsh/digest sha512" "$EXPECTED_SHA512" "$actual"

echo "[zsh] mkfile"
run_zsh "$FUNCTIONS_SH" "mkfile 1K '$WORK/dummy.bin'" >/dev/null
assert_success "zsh/mkfile exit code" "$?"
assert_exists "zsh/mkfile created" "$WORK/dummy.bin"
actual=$(stat -c%s "$WORK/dummy.bin")
assert_eq "zsh/mkfile size" "1024" "$actual"
rm -f "$WORK/dummy.bin"

echo "[zsh] archive + extract tar.gz"
setup_fixtures
run_zsh "$FUNCTIONS_SH" "cd '$WORK' && archive '$WORK/test.tar.gz' src" 2>/dev/null
assert_success "zsh/archive tar.gz exit code" "$?"
assert_exists "zsh/archive tar.gz" "$WORK/test.tar.gz"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.gz" "$WORK/extracted/"
run_zsh "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract '$WORK/extracted/test.tar.gz'"
assert_success "zsh/extract tar.gz exit code" "$?"
assert_exists "zsh/extract tar.gz" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.gz" "$WORK/extracted"

# --- extract: several archives in one call; one failure does not hide the rest ---
echo "[zsh] extract multiple archives"
setup_fixtures
mkdir -p "$WORK/second" && echo second > "$WORK/second/file2.txt"
run_zsh "$FUNCTIONS_SH" "cd '$WORK' && archive '$WORK/one.tar.gz' src && archive '$WORK/two.tar.gz' second" 2>/dev/null
mkdir -p "$WORK/multi"
run_zsh "$FUNCTIONS_SH" "cd '$WORK/multi' && extract '$WORK/one.tar.gz' '$WORK/two.tar.gz'"
assert_success "zsh/extract multi exit code" "$?"
assert_exists "zsh/extract multi first archive" "$WORK/multi/src/file1.txt"
assert_exists "zsh/extract multi second archive" "$WORK/multi/second/file2.txt"
rm -rf "$WORK/multi" && mkdir -p "$WORK/multi"
run_zsh "$FUNCTIONS_SH" "cd '$WORK/multi' && extract '$WORK/one.tar.gz' '$WORK/missing.tar.gz'" 2>/dev/null
assert_eq "zsh/extract multi with a missing archive exits 1" "1" "$?"
assert_exists "zsh/extract multi still extracted the good archive" "$WORK/multi/src/file1.txt"
rm -rf "$WORK/one.tar.gz" "$WORK/two.tar.gz" "$WORK/second" "$WORK/multi"

echo "[zsh] digest several files"
setup_fixtures
printf 'one' > "$WORK/d1.txt"; printf 'two' > "$WORK/d2.txt"
actual=$(run_zsh "$FUNCTIONS_SH" "digest sha256 '$WORK/d1.txt' '$WORK/d2.txt'")
assert_success "zsh/digest multi exit code" "$?"
assert_eq "zsh/digest multi prints one line per file" "2" "$(printf '%s\n' "$actual" | wc -l | tr -d ' ')"
assert_contains "zsh/digest multi names the file" "$WORK/d2.txt" "$actual"
run_zsh "$FUNCTIONS_SH" "digest sha256 '$WORK/d1.txt' '$WORK/missing.txt'" 2>/dev/null
assert_eq "zsh/digest multi with a missing file exits 1" "1" "$?"
rm -rf "$WORK/d1.txt" "$WORK/d2.txt"

# `[ -f ]` is true for a file that cannot be READ, and the hash used to be
# piped into awk, whose status is the one the pipeline reports: the *sum
# tool's "Permission denied" reached stderr while digest printed an empty
# line and returned 0. root ignores the mode bits, so there it is skipped.
echo "[zsh] digest reports an unreadable file"
: > "$WORK/noread.txt"
if [ "$(id -u)" -ne 0 ] && chmod 000 "$WORK/noread.txt" 2>/dev/null && [ ! -r "$WORK/noread.txt" ]; then
    run_zsh "$FUNCTIONS_SH" "digest sha256 '$WORK/noread.txt'" >/dev/null 2>&1
    assert_eq "zsh/digest unreadable file exits 1" "1" "$?"
    chmod 600 "$WORK/noread.txt"
else
    echo "  SKIP: zsh/digest unreadable file (running as root)"
fi
rm -f "$WORK/noread.txt"

echo "[zsh] archive + extract zip"
setup_fixtures
run_zsh "$FUNCTIONS_SH" "cd '$WORK' && archive '$WORK/test.zip' src" 2>/dev/null
assert_success "zsh/archive zip exit code" "$?"
assert_exists "zsh/archive zip" "$WORK/test.zip"
mkdir -p "$WORK/extracted"
run_zsh "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract '$WORK/test.zip'"
assert_success "zsh/extract zip exit code" "$?"
assert_exists "zsh/extract zip" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.zip" "$WORK/extracted"

# --- archive: a source named like an option must never be parsed as one ---
echo "[zsh] archive neutralizes an option-shaped source name (tar.gz)"
setup_crafted
run_zsh "$FUNCTIONS_SH" "cd '$WORK/crafted' && archive '$WORK/out.tar.gz' *" 2>/dev/null
assert_success "zsh/archive crafted glob tar.gz exit code" "$?"
assert_not_exists "zsh/archive crafted glob tar.gz ran no command" "$WORK/crafted/pwned"
actual=$(tar tzf "$WORK/out.tar.gz" 2>/dev/null)
assert_contains "zsh/archive crafted glob tar.gz stored the file" "$CRAFTED_SRC" "$actual"

echo "[zsh] archive treats every argument after the output as a source"
setup_crafted
run_zsh "$FUNCTIONS_SH" "cd '$WORK/crafted' && archive '$WORK/out2.tar.gz' -C bait.txt" 2>/dev/null
assert_failure "zsh/archive does not honour -C as a tar option" "$?"
actual=$(tar tzf "$WORK/out2.tar.gz" 2>/dev/null)
assert_contains "zsh/archive stored the source that followed it" "bait.txt" "$actual"
assert_not_contains "zsh/archive did not chdir for -C" "crafted" "$actual"

echo "[zsh] archive neutralizes an option-shaped source name (zip)"
setup_crafted
run_zsh "$FUNCTIONS_SH" "cd '$WORK/crafted' && archive '$WORK/out.zip' *" >/dev/null 2>&1
assert_success "zsh/archive crafted glob zip exit code" "$?"
assert_not_exists "zsh/archive crafted glob zip ran no command" "$WORK/crafted/pwned"
assert_exists "zsh/archive crafted glob zip created the archive" "$WORK/out.zip"
actual=$(unzip -l "$WORK/out.zip" 2>/dev/null)
assert_contains "zsh/archive crafted glob zip stored the file" "$CRAFTED_SRC" "$actual"

echo "[zsh] archive 7z gets neither a switch nor a listfile"
setup_archiver_stubs
run_zsh "$FUNCTIONS_SH" "export PATH='$WORK/stubbin:$PATH'; cd '$WORK/stubsrc' && archive '$WORK/out.7z' -x '@list'" >/dev/null 2>&1
assert_exists "zsh/archive 7z reached the stub" "$STUB_ARGV"
actual=$(tr '\n' ' ' < "$STUB_ARGV" 2>/dev/null)
assert_eq "zsh/archive 7z argv" "a $WORK/out.7z ./-x ./@list " "$actual"
assert_not_contains "zsh/archive 7z got no -- marker" "--" "$actual"

echo "[zsh] extract 7z gets neither a switch nor a listfile"
setup_archiver_stubs
run_zsh "$FUNCTIONS_SH" "export PATH='$WORK/stubbin:$PATH'; cd '$WORK/stubsrc' && extract '-x.7z'" >/dev/null 2>&1
actual=$(tr '\n' ' ' < "$STUB_ARGV" 2>/dev/null)
assert_eq "zsh/extract 7z switch-shaped name" "x ./-x.7z " "$actual"
assert_not_contains "zsh/extract 7z switch-shaped got no -- marker" "--" "$actual"
rm -f "$STUB_ARGV"
run_zsh "$FUNCTIONS_SH" "export PATH='$WORK/stubbin:$PATH'; cd '$WORK/stubsrc' && extract '@a.7z'" >/dev/null 2>&1
actual=$(tr '\n' ' ' < "$STUB_ARGV" 2>/dev/null)
assert_eq "zsh/extract 7z listfile-shaped name" "x ./@a.7z " "$actual"
assert_not_contains "zsh/extract 7z listfile-shaped got no -- marker" "--" "$actual"

echo "[zsh] archive + extract tar.bz2"
setup_fixtures
run_zsh "$FUNCTIONS_SH" "cd '$WORK' && archive '$WORK/test.tar.bz2' src" 2>/dev/null
assert_success "zsh/archive tar.bz2 exit code" "$?"
assert_exists "zsh/archive tar.bz2" "$WORK/test.tar.bz2"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.bz2" "$WORK/extracted/"
run_zsh "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract 'test.tar.bz2'" 2>/dev/null
assert_success "zsh/extract tar.bz2 exit code" "$?"
assert_exists "zsh/extract tar.bz2" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.bz2" "$WORK/extracted"

echo "[zsh] archive + extract tar.xz"
setup_fixtures
run_zsh "$FUNCTIONS_SH" "cd '$WORK' && archive '$WORK/test.tar.xz' src" 2>/dev/null
assert_success "zsh/archive tar.xz exit code" "$?"
assert_exists "zsh/archive tar.xz" "$WORK/test.tar.xz"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.xz" "$WORK/extracted/"
run_zsh "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract 'test.tar.xz'" 2>/dev/null
assert_success "zsh/extract tar.xz exit code" "$?"
assert_exists "zsh/extract tar.xz" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.xz" "$WORK/extracted"

echo "[zsh] archive + extract tar.zst / tzst"
for _ext in tar.zst tzst; do
    setup_fixtures
    run_zsh "$FUNCTIONS_SH" "cd '$WORK' && archive '$WORK/test.$_ext' src" 2>/dev/null
    assert_success "zsh/archive .$_ext exit code" "$?"
    assert_exists "zsh/archive .$_ext" "$WORK/test.$_ext"
    mkdir -p "$WORK/extracted"
    cp "$WORK/test.$_ext" "$WORK/extracted/"
    run_zsh "$FUNCTIONS_SH" "cd '$WORK/extracted' && extract 'test.$_ext'" 2>/dev/null
    assert_success "zsh/extract .$_ext exit code" "$?"
    assert_exists "zsh/extract .$_ext" "$WORK/extracted/src/file1.txt"
done

echo "[zsh] archive + extract single-file formats"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    run_zsh "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'payload.bin.$_ext' payload.bin" 2>/dev/null
    assert_success "zsh/archive single-file .$_ext exit code" "$?"
    assert_exists "zsh/archive single-file .$_ext wrote the output" "$WORK/one/payload.bin.$_ext"
    assert_exists "zsh/archive single-file .$_ext kept the source" "$WORK/one/payload.bin"
    mkdir -p "$WORK/back"
    cp "$WORK/one/payload.bin.$_ext" "$WORK/back/"
    run_zsh "$FUNCTIONS_SH" "cd '$WORK/back' && extract 'payload.bin.$_ext'" 2>/dev/null
    assert_success "zsh/extract single-file .$_ext exit code" "$?"
    actual=$(sha256sum "$WORK/back/payload.bin" 2>/dev/null | cut -d' ' -f1)
    assert_eq "zsh/extract single-file .$_ext round-trips the bytes" "$PAYLOAD_SHA" "$actual"
done

echo "[zsh] archive single-file refuses several sources and directories"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    cp "$WORK/one/payload.bin" "$WORK/one/second.bin"
    err=$(run_zsh_stderr "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'multi.$_ext' payload.bin second.bin")
    assert_contains "zsh/archive .$_ext several sources usage" "$SINGLE_USAGE" "$err"
    run_zsh "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'multi.$_ext' payload.bin second.bin" 2>/dev/null
    assert_eq "zsh/archive .$_ext several sources exits 1" "1" "$?"
    assert_not_exists "zsh/archive .$_ext several sources wrote nothing" "$WORK/one/multi.$_ext"
    run_zsh "$FUNCTIONS_SH" "cd '$WORK' && archive '$WORK/dir.$_ext' one" 2>/dev/null
    assert_eq "zsh/archive .$_ext directory exits 1" "1" "$?"
    assert_not_exists "zsh/archive .$_ext directory wrote nothing" "$WORK/dir.$_ext"
done

echo "[zsh] archive and extract report a missing compressor"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    single_tools "$_ext"
    err=$(run_zsh_stderr "$FUNCTIONS_SH" "export PATH='$WORK/nobin'; cd '$WORK/one' && archive 'gone.$_ext' payload.bin")
    assert_contains "zsh/archive missing $CTOOL message" "archive: $CTOOL is not installed" "$err"
    run_zsh "$FUNCTIONS_SH" "export PATH='$WORK/nobin'; cd '$WORK/one' && archive 'gone.$_ext' payload.bin" 2>/dev/null
    assert_eq "zsh/archive missing $CTOOL exits 1" "1" "$?"
    assert_not_exists "zsh/archive missing $CTOOL wrote nothing" "$WORK/one/gone.$_ext"
    mkdir -p "$WORK/noload"
    run_zsh "$FUNCTIONS_SH" "cd '$WORK/one' && archive '$WORK/noload/payload.bin.$_ext' payload.bin" 2>/dev/null
    err=$(run_zsh_stderr "$FUNCTIONS_SH" "export PATH='$WORK/nobin'; cd '$WORK/noload' && extract 'payload.bin.$_ext'")
    assert_contains "zsh/extract missing $DTOOL message" "extract: $DTOOL is not installed" "$err"
    run_zsh "$FUNCTIONS_SH" "export PATH='$WORK/nobin'; cd '$WORK/noload' && extract 'payload.bin.$_ext'" 2>/dev/null
    assert_eq "zsh/extract missing $DTOOL exits 1" "1" "$?"
    assert_not_exists "zsh/extract missing $DTOOL wrote nothing" "$WORK/noload/payload.bin"
done

# A source that does not exist used to reach the compressor, which meant the
# output had already been created or truncated by the time it failed: naming
# an existing archive as the output destroyed it. Nothing may be written.
echo "[zsh] archive single-file refuses a missing source"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    printf 'PRECIOUS' > "$WORK/one/keep.$_ext"
    err=$(run_zsh_stderr "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'keep.$_ext' missing.bin")
    assert_contains "zsh/archive .$_ext missing source usage" "$SINGLE_USAGE" "$err"
    run_zsh "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'keep.$_ext' missing.bin" 2>/dev/null
    assert_eq "zsh/archive .$_ext missing source exits 1" "1" "$?"
    assert_eq "zsh/archive .$_ext missing source left the output untouched" "PRECIOUS" "$(cat "$WORK/one/keep.$_ext" 2>/dev/null)"
    assert_not_exists "zsh/archive .$_ext missing source made no new output" "$WORK/one/missing.bin.$_ext"
done

# `archive f.gz f.gz` opened f.gz for the compressor's output before reading
# it, so the source came back as a compressed EMPTY stream — and gzip/bzip2/xz
# exited 0 doing it. Spellings that resolve to the same path are refused
# outright, with the file left exactly as it was; names that reach the source
# through a link are the next block's business.
echo "[zsh] archive single-file refuses an output that is the source"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    printf 'ORIGINAL' > "$WORK/one/self.$_ext"
    for _spell in "self.$_ext" "./self.$_ext"; do
        err=$(run_zsh_stderr "$FUNCTIONS_SH" "cd '$WORK/one' && archive '$_spell' 'self.$_ext'")
        assert_contains "zsh/archive .$_ext output '$_spell' is the source" "is the source file" "$err"
        assert_eq "zsh/archive .$_ext output '$_spell' left the source intact" "ORIGINAL" "$(cat "$WORK/one/self.$_ext" 2>/dev/null)"
    done
    run_zsh "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'self.$_ext' 'self.$_ext'" 2>/dev/null
    assert_eq "zsh/archive .$_ext output is the source exits 1" "1" "$?"
done

# Comparing resolved paths does not establish identity: a hard link and a chain
# of symlinks name the same file by a different path, and a check that only
# compares strings lets them through. What actually keeps the source safe is
# that the compressor writes a temporary sibling of the output which is renamed
# into place afterwards — the source is never the file being written, whatever
# it is called — so what is asserted here is the source surviving, in the lane
# that refuses these and in the lane that goes ahead and compresses them.
echo "[zsh] archive single-file cannot truncate the source through another name"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    ln -s payload.bin "$WORK/one/hop1.$_ext"
    ln -s "hop1.$_ext" "$WORK/one/hop2.$_ext"
    for _hop in "hop1.$_ext" "hop2.$_ext"; do
        run_zsh "$FUNCTIONS_SH" "cd '$WORK/one' && archive '$_hop' payload.bin" >/dev/null 2>&1
        actual=$(sha256sum "$WORK/one/payload.bin" 2>/dev/null | cut -d' ' -f1)
        assert_eq "zsh/archive .$_ext symlink '$_hop' left the source intact" "$PAYLOAD_SHA" "$actual"
    done
    if ln "$WORK/one/payload.bin" "$WORK/one/hard.$_ext" 2>/dev/null; then
        run_zsh "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'hard.$_ext' payload.bin" >/dev/null 2>&1
        actual=$(sha256sum "$WORK/one/payload.bin" 2>/dev/null | cut -d' ' -f1)
        assert_eq "zsh/archive .$_ext hard link left the source intact" "$PAYLOAD_SHA" "$actual"
    else
        echo "  SKIP: zsh/archive .$_ext hard link (filesystem refused)"
    fi
done

# A directory sitting where the output should go is not an output. The
# single-file branch renamed its temporary INTO that directory and reported
# success with no archive written; the tar and zip branches only failed late,
# and pwsh's Compress-Archive -Force deleted the directory on the way.
echo "[zsh] archive refuses a directory at the output path"
for _fmt in gz tar.gz zip; do
    setup_single_file
    mkdir -p "$WORK/one/out.$_fmt"
    err=$(run_zsh_stderr "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'out.$_fmt' payload.bin")
    assert_contains "zsh/archive .$_fmt directory output message" "is a directory" "$err"
    run_zsh "$FUNCTIONS_SH" "cd '$WORK/one' && archive 'out.$_fmt' payload.bin" >/dev/null 2>&1
    assert_eq "zsh/archive .$_fmt directory output exits 1" "1" "$?"
    assert_exists "zsh/archive .$_fmt directory output still there" "$WORK/one/out.$_fmt"
    assert_eq "zsh/archive .$_fmt directory output stayed empty" "" "$(ls "$WORK/one/out.$_fmt")"
done

# A compressor that starts and then fails must not look like success: the
# partial temporary goes, an existing output keeps its contents, and the
# failure is reported. The stub exits 3 after writing to stdout, so there IS a
# partial temporary to clean up.
echo "[zsh] archive reports a compressor that fails"
    setup_single_file
    mkdir -p "$WORK/stub3"
    printf '#!/bin/sh\nprintf PARTIAL\nexit 3\n' > "$WORK/stub3/gzip"
    chmod +x "$WORK/stub3/gzip"
    printf 'PRECIOUS' > "$WORK/one/keep.gz"
    run_zsh "$FUNCTIONS_SH" "export PATH='$WORK/stub3:$PATH'; cd '$WORK/one' && archive 'keep.gz' payload.bin" >/dev/null 2>&1
    assert_eq "zsh/archive compressor failure exits with the tool's code" "3" "$?"
    assert_eq "zsh/archive compressor failure left the output untouched" "PRECIOUS" "$(cat "$WORK/one/keep.gz" 2>/dev/null)"
    assert_eq "zsh/archive compressor failure left no temporary behind" "" "$(ls -A "$WORK/one" | grep -E '^\.archive\.|\.tmp\.' | tr -d '\n')"

# Staging happens inside a private 0700 directory nobody else can traverse,
# which is what keeps the name the compressor reopens from being swapped for a
# symlink. There is no fallback for a missing mktemp, deliberately: any
# predictable name would hand that window straight back. These two cases check
# the branch fails CLOSED instead -- with mktemp gone entirely, and with mktemp
# present but unable to produce a directory -- writing nothing either way.
echo "[zsh] archive requires mktemp for the staging directory"
setup_single_file
# a PATH carrying the real compressor but no mktemp, so the branch gets past
# its own tool check and fails on this one
mkdir -p "$WORK/nomk"
ln -s "$(command -v gzip)" "$WORK/nomk/gzip"
err=$(run_zsh_stderr "$FUNCTIONS_SH" "export PATH='$WORK/nomk'; cd '$WORK/one' && archive 'out.gz' payload.bin")
assert_contains "zsh/archive missing mktemp message" "archive: mktemp is not installed" "$err"
run_zsh "$FUNCTIONS_SH" "export PATH='$WORK/nomk'; cd '$WORK/one' && archive 'out.gz' payload.bin" >/dev/null 2>&1
assert_eq "zsh/archive missing mktemp exits 1" "1" "$?"
assert_not_exists "zsh/archive missing mktemp wrote nothing" "$WORK/one/out.gz"

# mktemp present but unable to produce a directory: refuse, rather than fall
# back to any name an attacker could have guessed. The old predictable name is
# planted as a symlink to prove nothing reaches for it any more.
echo "[zsh] archive falls back to no predictable name when mktemp fails"
setup_single_file
mkdir -p "$WORK/failmk"
printf '#!/bin/sh\nexit 1\n' > "$WORK/failmk/mktemp"
chmod +x "$WORK/failmk/mktemp"
printf 'VICTIM' > "$WORK/one/victim"
run_zsh "$FUNCTIONS_SH" "export PATH='$WORK/failmk:$PATH'; cd '$WORK/one' && ln -s victim \"out.gz.tmp.\$\$\" && archive 'out.gz' payload.bin" >/dev/null 2>&1
assert_eq "zsh/archive unusable mktemp exits nonzero" "1" "$?"
assert_eq "zsh/archive unusable mktemp touched no predictable name" "VICTIM" "$(cat "$WORK/one/victim" 2>/dev/null)"
assert_not_exists "zsh/archive unusable mktemp produced no output" "$WORK/one/out.gz"
# '.archive.' only here: the fixture deliberately plants a file whose own name
# ends in .tmp.<pid>, and that plant is the point of the case, not a leftover.
assert_eq "zsh/archive unusable mktemp left no staging directory" "" "$(ls -A "$WORK/one" | grep '^\.archive\.' | tr -d '\n')"

# Publishing the staged archive can fail on its own (a read-only directory, a
# full disk). The staged file must not be left lying around as a stray .tmp,
# and the failure must be reported. A stub mv makes it fail as any user.
echo "[zsh] archive cleans up when the publish fails"
setup_single_file
mkdir -p "$WORK/stubmv"
printf '#!/bin/sh\nexit 7\n' > "$WORK/stubmv/mv"
chmod +x "$WORK/stubmv/mv"
run_zsh "$FUNCTIONS_SH" "export PATH='$WORK/stubmv:$PATH'; cd '$WORK/one' && archive 'out.gz' payload.bin" >/dev/null 2>&1
assert_eq "zsh/archive publish failure exits with mv's code" "7" "$?"
assert_not_exists "zsh/archive publish failure wrote no output" "$WORK/one/out.gz"
assert_eq "zsh/archive publish failure left no temporary behind" "" "$(ls -A "$WORK/one" | grep -E '^\.archive\.|\.tmp\.' | tr -d '\n')"

# What actually closes the symlink race is WHERE the archive is staged: mktemp
# creates a file exclusively, but the compressor reopens it by name, and in a
# directory others can write to that name can be unlinked and replaced in
# between. A 0700 directory nobody else can traverse removes the window. The
# stub records the path it was handed and that directory's mode, so both are
# checked directly rather than inferred.
echo "[zsh] archive stages inside a private directory"
setup_single_file
mkdir -p "$WORK/stagebin"
cat > "$WORK/stagebin/zstd" <<'STUB'
#!/bin/sh
out=""
while [ $# -gt 0 ]; do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        *)  shift ;;
    esac
done
printf '%s %s\n' "$out" "$(ls -ld "${out%/*}" | cut -c1-10)" > "$STAGE_LOG"
printf 'STUB' > "$out"
STUB
chmod +x "$WORK/stagebin/zstd"
run_zsh "$FUNCTIONS_SH" "export PATH='$WORK/stagebin:$PATH' STAGE_LOG='$WORK/stage.log'; cd '$WORK/one' && archive 'out.zst' payload.bin" >/dev/null 2>&1
assert_success "zsh/archive staged run exit code" "$?"
assert_contains "zsh/archive staged in a .archive directory" "/.archive." "$(cat "$WORK/stage.log" 2>/dev/null)"
assert_contains "zsh/archive staging directory is private" "drwx------" "$(cat "$WORK/stage.log" 2>/dev/null)"
assert_exists "zsh/archive published the staged file" "$WORK/one/out.zst"
assert_eq "zsh/archive removed the staging directory" "" "$(ls -A "$WORK/one" | grep '^\.archive\.' | tr -d '\n')"

# 'command -v' answers with the bare name for a shell function, so a local
# `gzip` passed the availability check and then took the call itself. Two
# halves: with the real gzip on PATH the function must never run and the round
# trip must still work; with only the function and no binary the branch must
# say the tool is missing rather than run it.
echo "[zsh] archive and extract run the program, not a shell function"
setup_single_file
SHADOW="gzip() { echo ran > '$WORK/one/shadow-marker'; }; zstd() { echo ran > '$WORK/one/shadow-marker'; }"
run_zsh "$FUNCTIONS_SH" "true; $SHADOW; cd '$WORK/one' && archive 'payload.bin.gz' payload.bin && archive 'payload.bin.zst' payload.bin" >/dev/null 2>&1
assert_success "zsh/archive shadowed run exit code" "$?"
assert_not_exists "zsh/archive ran no shadowing function" "$WORK/one/shadow-marker"
assert_exists "zsh/archive still wrote the real .gz" "$WORK/one/payload.bin.gz"
assert_exists "zsh/archive still wrote the real .zst" "$WORK/one/payload.bin.zst"
mkdir -p "$WORK/back"
cp "$WORK/one/payload.bin.gz" "$WORK/back/"
run_zsh "$FUNCTIONS_SH" "true; gunzip() { echo ran > '$WORK/back/shadow-marker'; }; cd '$WORK/back' && extract 'payload.bin.gz'" >/dev/null 2>&1
assert_not_exists "zsh/extract ran no shadowing function" "$WORK/back/shadow-marker"
assert_eq "zsh/extract round-trips past the shadowing function" "$PAYLOAD_SHA" "$(sha256sum "$WORK/back/payload.bin" 2>/dev/null | cut -d' ' -f1)"

# A function is not an installed program: with no gzip binary reachable, the
# branch must report it missing instead of calling the function.
echo "[zsh] archive does not accept a shell function as the compressor"
setup_single_file
mkdir -p "$WORK/nogzip"
for _t in mktemp mv rm chmod ls; do
    _p=$(command -v "$_t") && ln -sf "$_p" "$WORK/nogzip/$_t"
done
err=$(run_zsh_stderr "$FUNCTIONS_SH" "export PATH='$WORK/nogzip'; gzip() { echo ran > '$WORK/one/shadow-marker'; }; cd '$WORK/one' && archive 'out.gz' payload.bin")
assert_contains "zsh/archive function-only gzip reported missing" "archive: gzip is not installed" "$err"
assert_not_exists "zsh/archive function-only gzip never ran" "$WORK/one/shadow-marker"
assert_not_exists "zsh/archive function-only gzip wrote nothing" "$WORK/one/out.gz"

echo "[zsh] path"
actual=$(run_zsh "$FUNCTIONS_SH" "path")
assert_contains "zsh/path contains /usr" "/usr" "$actual"

echo "[zsh] up"
actual=$(run_zsh "$FUNCTIONS_SH" "mkdir -p '$WORK/a/b/c' && cd '$WORK/a/b/c' && up 2 && pwd")
assert_eq "zsh/up 2" "$WORK/a" "$actual"

echo "[zsh] mkcd"
actual=$(run_zsh "$FUNCTIONS_SH" "mkcd '$WORK/newdir' && pwd")
assert_eq "zsh/mkcd" "$WORK/newdir" "$actual"
assert_exists "zsh/mkcd dir" "$WORK/newdir"
rm -rf "$WORK/newdir"

# --- again / back ---
echo "[zsh] again 0"
err=$(run_zsh_stderr "$FUNCTIONS_SH" "again 0")
assert_contains "zsh/again 0 usage" "usage" "$err"

echo "[zsh] again no history"
err=$(run_zsh_stderr "$FUNCTIONS_SH" "again")
assert_contains "zsh/again no history" "no command" "$err"

echo "[zsh] back 0"
err=$(run_zsh_stderr "$FUNCTIONS_SH" "back 0")
assert_contains "zsh/back 0 usage" "usage" "$err"

# back N>1 is supported now (browser-style history); with nothing recorded
# yet it reports the empty history instead of "only N=1".
echo "[zsh] back 2 with no history"
err=$(run_zsh_stderr "$FUNCTIONS_SH" "back 2")
assert_contains "zsh/back 2 with no history" "history has 0 back entries" "$err"

echo "[zsh] back with OLDPWD"
actual=$(run_zsh "$FUNCTIONS_SH" "cd /tmp && cd / && back" 2>/dev/null)
assert_eq "zsh/back OLDPWD" "/tmp" "$actual"

dirhist_posix_cases zsh

echo "[zsh] chpwd hook"
out=$(zsh -c "source '$FUNCTIONS_SH' && source '$FUNCTIONS_SH' && print -r -- \${(j:,:)chpwd_functions}")
assert_eq "zsh/chpwd hook added once" "_den_dh_record" "$out"

echo "[zsh] moves den's cd does not make are recorded"
out=$(dh_run zsh "builtin cd '$DH/a'; pushd '$DH/b' >/dev/null; mkcd '$DH/c'; back -l")
assert_eq "zsh/builtin cd, pushd, mkcd recorded" "  3  ~/start
  2  ~/a
  1  ~/b
  *  ~/c" "$out"

# =============================================================================
# PowerShell tests
# =============================================================================
echo ""
echo "================================================"
echo "  Testing functions.ps1 with PWSH"
echo "================================================"

echo "[pwsh] digest md5"
setup_hash_file
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "digest md5 '$WORK/hashfile.txt'" 2>/dev/null)
# PowerShell returns UPPERCASE hex
assert_eq "pwsh/digest md5" "${EXPECTED_MD5^^}" "$actual"

echo "[pwsh] digest sha256"
setup_hash_file
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "digest sha256 '$WORK/hashfile.txt'" 2>/dev/null)
assert_eq "pwsh/digest sha256" "${EXPECTED_SHA256^^}" "$actual"

echo "[pwsh] digest sha512"
setup_hash_file
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "digest sha512 '$WORK/hashfile.txt'" 2>/dev/null | tail -1)
assert_eq "pwsh/digest sha512" "${EXPECTED_SHA512^^}" "$actual"

echo "[pwsh] mkfile"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "mkfile 1024 '$WORK/dummy.bin'" >/dev/null
assert_success "pwsh/mkfile exit code" "$?"
assert_exists "pwsh/mkfile created" "$WORK/dummy.bin"
actual=$(stat -c%s "$WORK/dummy.bin")
assert_eq "pwsh/mkfile size" "1024" "$actual"
rm -f "$WORK/dummy.bin"

echo "[pwsh] archive + extract tar.gz"
setup_fixtures
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK'; archive 'test.tar.gz' 'src'"
assert_success "pwsh/archive tar.gz exit code" "$?"
assert_exists "pwsh/archive tar.gz" "$WORK/test.tar.gz"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.gz" "$WORK/extracted/"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/extracted'; extract 'test.tar.gz'"
assert_success "pwsh/extract tar.gz exit code" "$?"
assert_exists "pwsh/extract tar.gz" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.gz" "$WORK/extracted"

# --- extract: several archives in one call; one failure does not hide the rest ---
echo "[pwsh] extract multiple archives"
setup_fixtures
mkdir -p "$WORK/second" && echo second > "$WORK/second/file2.txt"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK'; archive 'one.tar.gz' src; archive 'two.tar.gz' second" 2>/dev/null
mkdir -p "$WORK/multi"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/multi'; extract '$WORK/one.tar.gz' '$WORK/two.tar.gz'"
assert_success "pwsh/extract multi exit code" "$?"
assert_exists "pwsh/extract multi first archive" "$WORK/multi/src/file1.txt"
assert_exists "pwsh/extract multi second archive" "$WORK/multi/second/file2.txt"
rm -rf "$WORK/multi" && mkdir -p "$WORK/multi"
err=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/multi'; extract '$WORK/one.tar.gz' '$WORK/missing.tar.gz'" 2>&1 >/dev/null)
assert_contains "pwsh/extract multi reports the failed archive" "1 of 2 archives failed" "$err"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/multi'; extract '$WORK/one.tar.gz' '$WORK/missing.tar.gz'" >/dev/null 2>&1
assert_eq "pwsh/extract multi with a missing archive exits 1" "1" "$?"
assert_exists "pwsh/extract multi still extracted the good archive" "$WORK/multi/src/file1.txt"
# A corrupt zip goes through the cmdlet path (Expand-Archive), which never sets
# $LASTEXITCODE; its failure must still be counted, and a healthy archive after
# a failed native command must not inherit that command's exit code.
printf 'not a zip' > "$WORK/broken.zip"
err=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/multi'; extract '$WORK/broken.zip' '$WORK/two.tar.gz'" 2>&1 >/dev/null)
assert_contains "pwsh/extract counts a corrupt zip as failed" "1 of 2 archives failed" "$err"
assert_exists "pwsh/extract corrupt zip does not stop the next archive" "$WORK/multi/second/file2.txt"

echo "[pwsh] mkfile resolves a relative path against the PowerShell location"
# [IO.File]::Create resolves against the process directory (where pwsh was
# launched), which Set-Location never updates: the file must land in $WORK/multi.
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/multi'; mkfile 512 rel.bin" >/dev/null
assert_exists "pwsh/mkfile relative path follows Set-Location" "$WORK/multi/rel.bin"

echo "[pwsh] archive zip takes several sources"
rm -rf "$WORK/zipped" && mkdir -p "$WORK/zipped"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK'; archive 'both.zip' src second" 2>/dev/null
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/zipped'; extract '$WORK/both.zip'" >/dev/null 2>&1
assert_exists "pwsh/archive zip first source" "$WORK/zipped/src/file1.txt"
assert_exists "pwsh/archive zip second source" "$WORK/zipped/second/file2.txt"
rm -rf "$WORK/broken.zip" "$WORK/one.tar.gz" "$WORK/two.tar.gz" "$WORK/second" "$WORK/multi"

# --- archive: a source named like an option must never be parsed as one ---
echo "[pwsh] archive neutralizes an option-shaped source name (tar.gz)"
setup_crafted
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/crafted'; archive '$WORK/out.tar.gz' '$CRAFTED_TRIGGER' '$CRAFTED_SRC' bait.txt" >/dev/null 2>&1
assert_success "pwsh/archive crafted tar.gz exit code" "$?"
assert_not_exists "pwsh/archive crafted tar.gz ran no command" "$WORK/crafted/pwned"
actual=$(tar tzf "$WORK/out.tar.gz" 2>/dev/null)
assert_contains "pwsh/archive crafted tar.gz stored the file" "$CRAFTED_SRC" "$actual"

# The output name is a path too. The POSIX twin has always normalised a
# dash-leading $out with './'; pwsh did it only for extract's $Path. Two
# branches actually broke without that: 7z reads '-x.7z' as its own exclude
# switch, and zstd's -o refuses a value starting with '-'. tar (where the name
# is -f's operand) and the redirected forms were already fine, but every shape
# is checked here so a later branch cannot regress quietly.
echo "[pwsh] archive neutralizes a dash-leading output name"
setup_fixtures
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK'; archive '-x.tar.gz' 'src'" 2>/dev/null
assert_success "pwsh/archive dash-leading tar.gz exit code" "$?"
assert_exists "pwsh/archive dash-leading tar.gz" "$WORK/-x.tar.gz"
actual=$(tar tzf "$WORK/-x.tar.gz" 2>/dev/null)
assert_contains "pwsh/archive dash-leading tar.gz stored the source" "src/file1.txt" "$actual"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/src'; archive '-y.zst' 'file1.txt'" 2>/dev/null
assert_success "pwsh/archive dash-leading single-file .zst exit code" "$?"
assert_exists "pwsh/archive dash-leading single-file .zst" "$WORK/src/-y.zst"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/src'; archive '-y.gz' 'file1.txt'" 2>/dev/null
assert_success "pwsh/archive dash-leading single-file .gz exit code" "$?"
assert_exists "pwsh/archive dash-leading single-file .gz" "$WORK/src/-y.gz"
# 7z is the branch that misreads the name outright ('-x' is its exclude
# switch), and it has no '--' to fall back on, so what it was handed is read
# off the stub's argv rather than off a result.
setup_archiver_stubs
: > "$WORK/stubsrc/plain.txt"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "\$env:PATH='$WORK/stubbin:' + \$env:PATH; Set-Location '$WORK/stubsrc'; archive '-x.7z' 'plain.txt'" >/dev/null 2>&1
actual=$(tr '\n' ' ' < "$STUB_ARGV" 2>/dev/null)
assert_eq "pwsh/archive dash-leading 7z output argv" "a ./-x.7z plain.txt " "$actual"

# Compress-Archive -Path reads [ ] * ? as wildcards, so the zip branch has to
# name the source literally or it archives the file the pattern happens to hit.
echo "[pwsh] archive zip takes the source name literally"
setup_wildcard
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/wild'; archive '$WORK/wild.zip' 'f[1].txt'" >/dev/null 2>&1
assert_success "pwsh/archive zip literal name exit code" "$?"
rm -rf "$WORK/wildout" && mkdir -p "$WORK/wildout"
(cd "$WORK/wildout" && unzip -q "$WORK/wild.zip") >/dev/null 2>&1
assert_exists "pwsh/archive zip stored the literal file" "$WORK/wildout/f[1].txt"
assert_not_exists "pwsh/archive zip did not store the decoy" "$WORK/wildout/f1.txt"

echo "[pwsh] digest hashes the literal file, not a wildcard match"
setup_wildcard
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "digest sha256 '$WORK/wild/f[1].txt'" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/digest literal name" "${SHA256_REAL^^}" "$actual"
assert_not_contains "pwsh/digest did not hash the decoy" "${SHA256_DECOY^^}" "$actual"

echo "[pwsh] archive 7z gets neither a switch nor a listfile"
setup_archiver_stubs
run_pwsh "$FUNCTIONS_PS1_COMBINED" "\$env:PATH='$WORK/stubbin:' + \$env:PATH; Set-Location '$WORK/stubsrc'; archive '$WORK/out.7z' '-x' '@list'" >/dev/null 2>&1
assert_exists "pwsh/archive 7z reached the stub" "$STUB_ARGV"
actual=$(tr '\n' ' ' < "$STUB_ARGV" 2>/dev/null)
assert_eq "pwsh/archive 7z argv" "a $WORK/out.7z ./-x ./@list " "$actual"
assert_not_contains "pwsh/archive 7z got no -- marker" "--" "$actual"

echo "[pwsh] extract 7z gets neither a switch nor a listfile"
setup_archiver_stubs
run_pwsh "$FUNCTIONS_PS1_COMBINED" "\$env:PATH='$WORK/stubbin:' + \$env:PATH; Set-Location '$WORK/stubsrc'; extract '-x.7z'" >/dev/null 2>&1
actual=$(tr '\n' ' ' < "$STUB_ARGV" 2>/dev/null)
assert_eq "pwsh/extract 7z switch-shaped name" "x ./-x.7z " "$actual"
assert_not_contains "pwsh/extract 7z switch-shaped got no -- marker" "--" "$actual"
rm -f "$STUB_ARGV"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "\$env:PATH='$WORK/stubbin:' + \$env:PATH; Set-Location '$WORK/stubsrc'; extract '@a.7z'" >/dev/null 2>&1
actual=$(tr '\n' ' ' < "$STUB_ARGV" 2>/dev/null)
assert_eq "pwsh/extract 7z listfile-shaped name" "x ./@a.7z " "$actual"
assert_not_contains "pwsh/extract 7z listfile-shaped got no -- marker" "--" "$actual"

# The POSIX twin neutralises a leading dash once, before dispatching, so every
# branch's tool gets a path. pwsh only did it inside the 7z branch, leaving
# tar/gzip/unrar to read the archive name as a switch.
echo "[pwsh] extract neutralizes a leading dash for every branch"
setup_archiver_stubs
run_pwsh "$FUNCTIONS_PS1_COMBINED" "\$env:PATH='$WORK/stubbin:' + \$env:PATH; Set-Location '$WORK/stubsrc'; extract '-x.tar.gz'" >/dev/null 2>&1
actual=$(tr '\n' ' ' < "$STUB_ARGV" 2>/dev/null)
assert_eq "pwsh/extract tar branch gets a path" "xzf ./-x.tar.gz " "$actual"
rm -f "$STUB_ARGV"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "\$env:PATH='$WORK/stubbin:' + \$env:PATH; Set-Location '$WORK/stubsrc'; extract '-x.gz'" >/dev/null 2>&1
actual=$(tr '\n' ' ' < "$STUB_ARGV" 2>/dev/null)
assert_eq "pwsh/extract gzip branch gets a path" "-d ./-x.gz " "$actual"
rm -f "$STUB_ARGV"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "\$env:PATH='$WORK/stubbin:' + \$env:PATH; Set-Location '$WORK/stubsrc'; extract '-x.rar'" >/dev/null 2>&1
actual=$(tr '\n' ' ' < "$STUB_ARGV" 2>/dev/null)
assert_eq "pwsh/extract unrar branch gets a path" "x ./-x.rar " "$actual"

echo "[pwsh] digest several files"
setup_fixtures
printf 'one' > "$WORK/d1.txt"; printf 'two' > "$WORK/d2.txt"
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "digest sha256 '$WORK/d1.txt' '$WORK/d2.txt'")
assert_success "pwsh/digest multi exit code" "$?"
assert_eq "pwsh/digest multi prints one line per file" "2" "$(printf '%s\n' "$actual" | wc -l | tr -d ' ')"
assert_contains "pwsh/digest multi names the file" "d2.txt" "$actual"
err=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "digest sha256 '$WORK/d1.txt' '$WORK/missing.txt'" 2>&1 >/dev/null)
assert_contains "pwsh/digest multi reports the missing file" "1 of 2 files failed" "$err"
rm -rf "$WORK/d1.txt" "$WORK/d2.txt"

# A refusal has to reach the PROCESS status: `pwsh -Command 'digest sha256
# missing.txt'` exited 0 while the per-file error and the summary were both
# plain (non-terminating) Write-Errors, and automation reads that as success.
# The same messages must carry exactly ONE "digest:" prefix -- PowerShell
# attributes an error to the function that raised it, so a hand-written prefix
# doubles it (the rule this file enforces for mkcd/again/back below).
echo "[pwsh] digest refusals exit 1 with a single prefix"
setup_fixtures
printf 'one' > "$WORK/d1.txt"
mkdir -p "$WORK/adir"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "digest sha256 '$WORK/missing.txt'" >/dev/null 2>&1
assert_eq "pwsh/digest missing file exits 1" "1" "$?"
err=$(run_pwsh_stderr_oneline "$FUNCTIONS_PS1_COMBINED" "digest sha256 '$WORK/missing.txt'")
assert_contains "pwsh/digest missing file is refused" "is not a file" "$err"
assert_not_contains "pwsh/digest missing file no double prefix" "digest: digest:" "$err"

run_pwsh "$FUNCTIONS_PS1_COMBINED" "digest sha256 '$WORK/adir'" >/dev/null 2>&1
assert_eq "pwsh/digest directory exits 1" "1" "$?"
err=$(run_pwsh_stderr_oneline "$FUNCTIONS_PS1_COMBINED" "digest sha256 '$WORK/adir'")
assert_contains "pwsh/digest directory is refused" "is not a file" "$err"
assert_not_contains "pwsh/digest directory no double prefix" "digest: digest:" "$err"

# Mixed list: only the SUMMARY terminates, so the good file is still hashed
# and printed before the run fails.
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "digest sha256 '$WORK/d1.txt' '$WORK/missing.txt'" 2>/dev/null | tr -d '\r')
assert_contains "pwsh/digest mixed list still prints the good hash" "$SHA256_ONE" "$actual"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "digest sha256 '$WORK/d1.txt' '$WORK/missing.txt'" >/dev/null 2>&1
assert_eq "pwsh/digest mixed list exits 1" "1" "$?"
err=$(run_pwsh_stderr_oneline "$FUNCTIONS_PS1_COMBINED" "digest sha256 '$WORK/d1.txt' '$WORK/missing.txt'")
assert_contains "pwsh/digest mixed list summarises the failure" "1 of 2 files failed" "$err"
assert_not_contains "pwsh/digest mixed list no double prefix" "digest: digest:" "$err"
rm -rf "$WORK/d1.txt" "$WORK/adir"

# A file that exists can still be unreadable, and Get-FileHash reports that
# non-terminatingly: digest used to print an empty line for it and exit 0.
# root ignores the mode bits, so there it is skipped.
echo "[pwsh] digest reports an unreadable file"
: > "$WORK/noread.txt"
if [ "$(id -u)" -ne 0 ] && chmod 000 "$WORK/noread.txt" 2>/dev/null && [ ! -r "$WORK/noread.txt" ]; then
    run_pwsh "$FUNCTIONS_PS1_COMBINED" "digest sha256 '$WORK/noread.txt'" >/dev/null 2>&1
    assert_eq "pwsh/digest unreadable file exits 1" "1" "$?"
    err=$(run_pwsh_stderr_oneline "$FUNCTIONS_PS1_COMBINED" "digest sha256 '$WORK/noread.txt'")
    assert_not_contains "pwsh/digest unreadable file no double prefix" "digest: digest:" "$err"
    chmod 600 "$WORK/noread.txt"
else
    echo "  SKIP: pwsh/digest unreadable file (running as root)"
fi
rm -f "$WORK/noread.txt"

echo "[pwsh] archive + extract zip"
setup_fixtures
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK'; archive 'test.zip' 'src'"
assert_success "pwsh/archive zip exit code" "$?"
assert_exists "pwsh/archive zip" "$WORK/test.zip"
mkdir -p "$WORK/extracted"
cp "$WORK/test.zip" "$WORK/extracted/"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/extracted'; extract '$WORK/extracted/test.zip'"
assert_success "pwsh/extract zip exit code" "$?"
assert_exists "pwsh/extract zip" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.zip" "$WORK/extracted"

echo "[pwsh] archive + extract tar.bz2"
setup_fixtures
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK'; archive 'test.tar.bz2' 'src'" 2>/dev/null
assert_success "pwsh/archive tar.bz2 exit code" "$?"
assert_exists "pwsh/archive tar.bz2" "$WORK/test.tar.bz2"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.bz2" "$WORK/extracted/"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/extracted'; extract 'test.tar.bz2'"
assert_success "pwsh/extract tar.bz2 exit code" "$?"
assert_exists "pwsh/extract tar.bz2" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.bz2" "$WORK/extracted"

echo "[pwsh] archive + extract tar.xz"
setup_fixtures
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK'; archive 'test.tar.xz' 'src'" 2>/dev/null
assert_success "pwsh/archive tar.xz exit code" "$?"
assert_exists "pwsh/archive tar.xz" "$WORK/test.tar.xz"
mkdir -p "$WORK/extracted"
cp "$WORK/test.tar.xz" "$WORK/extracted/"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/extracted'; extract 'test.tar.xz'"
assert_success "pwsh/extract tar.xz exit code" "$?"
assert_exists "pwsh/extract tar.xz" "$WORK/extracted/src/file1.txt"
rm -rf "$WORK/test.tar.xz" "$WORK/extracted"

echo "[pwsh] archive + extract tar.zst / tzst"
for _ext in tar.zst tzst; do
    setup_fixtures
    run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK'; archive 'test.$_ext' 'src'" 2>/dev/null
    assert_success "pwsh/archive .$_ext exit code" "$?"
    assert_exists "pwsh/archive .$_ext" "$WORK/test.$_ext"
    mkdir -p "$WORK/extracted"
    cp "$WORK/test.$_ext" "$WORK/extracted/"
    run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/extracted'; extract 'test.$_ext'" 2>/dev/null
    assert_success "pwsh/extract .$_ext exit code" "$?"
    assert_exists "pwsh/extract .$_ext" "$WORK/extracted/src/file1.txt"
done

# The gzip/bzip2/xz branches redirect a native command's stdout into the
# output: the payload is binary, so a round trip that still matches proves
# PowerShell wrote those bytes through unchanged.
echo "[pwsh] archive + extract single-file formats"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive 'payload.bin.$_ext' 'payload.bin'" 2>/dev/null
    assert_success "pwsh/archive single-file .$_ext exit code" "$?"
    assert_exists "pwsh/archive single-file .$_ext wrote the output" "$WORK/one/payload.bin.$_ext"
    assert_exists "pwsh/archive single-file .$_ext kept the source" "$WORK/one/payload.bin"
    mkdir -p "$WORK/back"
    cp "$WORK/one/payload.bin.$_ext" "$WORK/back/"
    run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/back'; extract 'payload.bin.$_ext'" 2>/dev/null
    assert_success "pwsh/extract single-file .$_ext exit code" "$?"
    actual=$(sha256sum "$WORK/back/payload.bin" 2>/dev/null | cut -d' ' -f1)
    assert_eq "pwsh/extract single-file .$_ext round-trips the bytes" "$PAYLOAD_SHA" "$actual"
done

# pwsh reports these through the error stream, as every other failure in
# archive/extract does, and terminates so the refusal reaches the process
# status: the message, exit 1 and the absence of an output are all asserted,
# the same three things the bash and zsh cases check.
echo "[pwsh] archive single-file refuses several sources and directories"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    cp "$WORK/one/payload.bin" "$WORK/one/second.bin"
    err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive 'multi.$_ext' 'payload.bin' 'second.bin'")
    assert_contains "pwsh/archive .$_ext several sources usage" "$SINGLE_USAGE" "$err"
    run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive 'multi.$_ext' 'payload.bin' 'second.bin'" >/dev/null 2>&1
    assert_eq "pwsh/archive .$_ext several sources exits 1" "1" "$?"
    assert_not_exists "pwsh/archive .$_ext several sources wrote nothing" "$WORK/one/multi.$_ext"
    err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK'; archive 'dir.$_ext' 'one'")
    assert_contains "pwsh/archive .$_ext directory usage" "$SINGLE_USAGE" "$err"
    run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK'; archive 'dir.$_ext' 'one'" >/dev/null 2>&1
    assert_eq "pwsh/archive .$_ext directory exits 1" "1" "$?"
    assert_not_exists "pwsh/archive .$_ext directory wrote nothing" "$WORK/dir.$_ext"
done

echo "[pwsh] archive and extract report a missing compressor"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    single_tools "$_ext"
    # run_pwsh_stderr_oneline, not run_pwsh_stderr: the double-prefix check is
    # only meaningful in ConciseView's compact "archive: <message>" form, which
    # PowerShell renders for a single-line command. The multi-line form puts
    # the prefix it adds and the message on separate lines, where a doubled
    # prefix is invisible to a substring match.
    err=$(run_pwsh_stderr_oneline "$FUNCTIONS_PS1_COMBINED" "\$env:PATH='$WORK/nobin'; Set-Location '$WORK/one'; archive 'gone.$_ext' 'payload.bin'")
    assert_contains "pwsh/archive missing $CTOOL message" "$CTOOL is not installed" "$err"
    assert_not_contains "pwsh/archive missing $CTOOL no double prefix" "archive: archive:" "$err"
    run_pwsh "$FUNCTIONS_PS1_COMBINED" "\$env:PATH='$WORK/nobin'; Set-Location '$WORK/one'; archive 'gone.$_ext' 'payload.bin'" >/dev/null 2>&1
    assert_eq "pwsh/archive missing $CTOOL exits 1" "1" "$?"
    assert_not_exists "pwsh/archive missing $CTOOL wrote nothing" "$WORK/one/gone.$_ext"
    mkdir -p "$WORK/noload"
    run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive '$WORK/noload/payload.bin.$_ext' 'payload.bin'" 2>/dev/null
    err=$(run_pwsh_stderr_oneline "$FUNCTIONS_PS1_COMBINED" "\$env:PATH='$WORK/nobin'; Set-Location '$WORK/noload'; extract 'payload.bin.$_ext'")
    assert_contains "pwsh/extract missing $CTOOL message" "$CTOOL is not installed" "$err"
    assert_not_contains "pwsh/extract missing $CTOOL no double prefix" "extract: extract:" "$err"
    run_pwsh "$FUNCTIONS_PS1_COMBINED" "\$env:PATH='$WORK/nobin'; Set-Location '$WORK/noload'; extract 'payload.bin.$_ext'" >/dev/null 2>&1
    assert_eq "pwsh/extract missing $CTOOL exits 1" "1" "$?"
    assert_not_exists "pwsh/extract missing $CTOOL wrote nothing" "$WORK/noload/payload.bin"
done

# A source that does not exist used to reach the compressor, which meant the
# output had already been created or truncated by the time it failed: naming
# an existing archive as the output destroyed it. Nothing may be written.
echo "[pwsh] archive single-file refuses a missing source"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    printf 'PRECIOUS' > "$WORK/one/keep.$_ext"
    err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive 'keep.$_ext' missing.bin")
    assert_contains "pwsh/archive .$_ext missing source usage" "$SINGLE_USAGE" "$err"
    run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive 'keep.$_ext' missing.bin" >/dev/null 2>&1
    assert_eq "pwsh/archive .$_ext missing source exits 1" "1" "$?"
    assert_eq "pwsh/archive .$_ext missing source left the output untouched" "PRECIOUS" "$(cat "$WORK/one/keep.$_ext" 2>/dev/null)"
    assert_not_exists "pwsh/archive .$_ext missing source made no new output" "$WORK/one/missing.bin.$_ext"
done

# `archive f.gz f.gz` opened f.gz for the compressor's output before reading
# it, so the source came back as a compressed EMPTY stream — and gzip/bzip2/xz
# exited 0 doing it. Spellings that resolve to the same path are refused
# outright, with the file left exactly as it was; names that reach the source
# through a link are the next block's business.
echo "[pwsh] archive single-file refuses an output that is the source"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    printf 'ORIGINAL' > "$WORK/one/self.$_ext"
    for _spell in "self.$_ext" "./self.$_ext"; do
        err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive '$_spell' 'self.$_ext'")
        assert_contains "pwsh/archive .$_ext output '$_spell' is the source" "is the source file" "$err"
        run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive '$_spell' 'self.$_ext'" >/dev/null 2>&1
        assert_eq "pwsh/archive .$_ext output '$_spell' exits 1" "1" "$?"
        assert_eq "pwsh/archive .$_ext output '$_spell' left the source intact" "ORIGINAL" "$(cat "$WORK/one/self.$_ext" 2>/dev/null)"
    done
done

# Comparing resolved paths does not establish identity: a hard link and a chain
# of symlinks name the same file by a different path, and a check that only
# compares strings lets them through. What actually keeps the source safe is
# that the compressor writes a temporary sibling of the output which is renamed
# into place afterwards — the source is never the file being written, whatever
# it is called — so what is asserted here is the source surviving, in the lane
# that refuses these and in the lane that goes ahead and compresses them.
echo "[pwsh] archive single-file cannot truncate the source through another name"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    ln -s payload.bin "$WORK/one/hop1.$_ext"
    ln -s "hop1.$_ext" "$WORK/one/hop2.$_ext"
    for _hop in "hop1.$_ext" "hop2.$_ext"; do
        run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive '$_hop' payload.bin" >/dev/null 2>&1
        actual=$(sha256sum "$WORK/one/payload.bin" 2>/dev/null | cut -d' ' -f1)
        assert_eq "pwsh/archive .$_ext symlink '$_hop' left the source intact" "$PAYLOAD_SHA" "$actual"
    done
    if ln "$WORK/one/payload.bin" "$WORK/one/hard.$_ext" 2>/dev/null; then
        run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive 'hard.$_ext' payload.bin" >/dev/null 2>&1
        actual=$(sha256sum "$WORK/one/payload.bin" 2>/dev/null | cut -d' ' -f1)
        assert_eq "pwsh/archive .$_ext hard link left the source intact" "$PAYLOAD_SHA" "$actual"
    else
        echo "  SKIP: pwsh/archive .$_ext hard link (filesystem refused)"
    fi
done

# Get-Command matches functions and aliases too, but _ArCompressTo starts the
# compressor through ProcessStartInfo, which can only launch a program. With a
# gzip FUNCTION defined and no gzip on PATH, the check used to report success
# and Process.Start then threw; the branch has to say the tool is missing.
echo "[pwsh] archive does not mistake a function for the compressor"
setup_single_file
err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "\$env:PATH='$WORK/nobin'; function gzip { 'not the real gzip' }; Set-Location '$WORK/one'; archive 'shadow.gz' 'payload.bin'")
assert_contains "pwsh/archive function-shadowed gzip reports it missing" "gzip is not installed" "$err"

# The other half of the same problem: with the real gzip ON PATH, a branch that
# invoked the bare name would run a same-named PowerShell function instead of
# the program that was checked for. Every invocation goes through the resolved
# program path, so the marker the shadow would leave never appears and the
# round trip still produces a real archive.
echo "[pwsh] archive and extract run the program, not a same-named function"
setup_single_file
SHADOW="function gzip { 'ran' > 'shadow-marker' }; function zstd { 'ran' > 'shadow-marker' }"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "$SHADOW; Set-Location '$WORK/one'; archive 'payload.bin.gz' 'payload.bin'; archive 'payload.bin.zst' 'payload.bin'" >/dev/null 2>&1
assert_not_exists "pwsh/archive ran no shadowing function" "$WORK/one/shadow-marker"
assert_exists "pwsh/archive still wrote the real .gz" "$WORK/one/payload.bin.gz"
assert_exists "pwsh/archive still wrote the real .zst" "$WORK/one/payload.bin.zst"
mkdir -p "$WORK/back"
cp "$WORK/one/payload.bin.gz" "$WORK/back/"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "$SHADOW; Set-Location '$WORK/back'; extract 'payload.bin.gz'" >/dev/null 2>&1
assert_not_exists "pwsh/extract ran no shadowing function" "$WORK/back/shadow-marker"
actual=$(sha256sum "$WORK/back/payload.bin" 2>/dev/null | cut -d' ' -f1)
assert_eq "pwsh/extract round-trips past the shadowing function" "$PAYLOAD_SHA" "$actual"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "\$env:PATH='$WORK/nobin'; function gzip { 'x' }; Set-Location '$WORK/one'; archive 'shadow.gz' 'payload.bin'" >/dev/null 2>&1
assert_eq "pwsh/archive function-shadowed gzip exits 1" "1" "$?"
assert_not_contains "pwsh/archive function-shadowed gzip did not start a process" "ProcessStartInfo" "$err"
assert_not_contains "pwsh/archive function-shadowed gzip threw no win32 error" "No such file or directory" "$err"
assert_not_exists "pwsh/archive function-shadowed gzip wrote nothing" "$WORK/one/shadow.gz"

# A directory sitting where the output should go is not an output. The
# single-file branch renamed its temporary INTO that directory and reported
# success with no archive written; the tar and zip branches only failed late,
# and pwsh's Compress-Archive -Force deleted the directory on the way.
echo "[pwsh] archive refuses a directory at the output path"
for _fmt in gz tar.gz zip; do
    setup_single_file
    mkdir -p "$WORK/one/out.$_fmt"
    err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive 'out.$_fmt' payload.bin")
    assert_contains "pwsh/archive .$_fmt directory output message" "is a directory" "$err"
    run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive 'out.$_fmt' payload.bin" >/dev/null 2>&1
    assert_eq "pwsh/archive .$_fmt directory output exits 1" "1" "$?"
    assert_exists "pwsh/archive .$_fmt directory output still there" "$WORK/one/out.$_fmt"
    assert_eq "pwsh/archive .$_fmt directory output stayed empty" "" "$(ls "$WORK/one/out.$_fmt")"
done

# Same as the bash case: a compressor that starts and then fails must not look
# like success. pwsh raises a terminating error naming the tool and its code,
# because a terminating error is the only thing that reaches the process status.
echo "[pwsh] archive reports a compressor that fails"
    setup_single_file
    mkdir -p "$WORK/stub3"
    printf '#!/bin/sh\nprintf PARTIAL\nexit 3\n' > "$WORK/stub3/gzip"
    chmod +x "$WORK/stub3/gzip"
    printf 'PRECIOUS' > "$WORK/one/keep.gz"
    err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "\$env:PATH='$WORK/stub3:' + \$env:PATH; Set-Location '$WORK/one'; archive 'keep.gz' 'payload.bin'")
    assert_contains "pwsh/archive compressor failure names the tool and code" "gzip exited 3" "$err"
    run_pwsh "$FUNCTIONS_PS1_COMBINED" "\$env:PATH='$WORK/stub3:' + \$env:PATH; Set-Location '$WORK/one'; archive 'keep.gz' 'payload.bin'" >/dev/null 2>&1
    assert_eq "pwsh/archive compressor failure exits 1" "1" "$?"
    assert_eq "pwsh/archive compressor failure left the output untouched" "PRECIOUS" "$(cat "$WORK/one/keep.gz" 2>/dev/null)"
    # pwsh stages as "<output>.tmp.<random>", not in a directory as POSIX does.
    assert_eq "pwsh/archive compressor failure left no temporary behind" "" "$(ls -A "$WORK/one" | grep -E '^\.archive\.|\.tmp\.' | tr -d '\n')"

# A destination that cannot be written has to fail too, rather than report an
# archive nobody can find. root ignores the mode bits, so there it is skipped.
echo "[pwsh] archive reports an unwritable destination"
setup_single_file
mkdir -p "$WORK/ro"
if [ "$(id -u)" -ne 0 ] && chmod 500 "$WORK/ro" 2>/dev/null; then
    run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive '$WORK/ro/out.gz' 'payload.bin'" >/dev/null 2>&1
    assert_eq "pwsh/archive unwritable destination exits 1" "1" "$?"
    assert_not_exists "pwsh/archive unwritable destination wrote nothing" "$WORK/ro/out.gz"
    chmod 700 "$WORK/ro"
else
    echo "  SKIP: pwsh/archive unwritable destination (running as root)"
fi

# _ArCompressTo used to start the compressor and only then open the
# destination, with just the file stream in a finally: when File.Create threw
# -- an unwritable directory, a path that does not exist -- a started child was
# left with nobody draining its pipe and was never waited on. The destination
# is opened first now, so a destination that cannot be opened means the
# compressor is never started at all. The stub records that it ran; the marker
# must not appear.
echo "[pwsh] archive opens the destination before starting the compressor"
setup_single_file
mkdir -p "$WORK/markbin"
printf '#!/bin/sh\ntouch "%s/one/compressor-ran"\ncat\n' "$WORK" > "$WORK/markbin/gzip"
chmod +x "$WORK/markbin/gzip"
err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "\$env:PATH='$WORK/markbin:' + \$env:PATH; Set-Location '$WORK/one'; archive '$WORK/no-such-dir/out.gz' 'payload.bin'")
assert_not_exists "pwsh/archive unopenable destination started no compressor" "$WORK/one/compressor-ran"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "\$env:PATH='$WORK/markbin:' + \$env:PATH; Set-Location '$WORK/one'; archive '$WORK/no-such-dir/out.gz' 'payload.bin'" >/dev/null 2>&1
assert_eq "pwsh/archive unopenable destination exits 1" "1" "$?"
assert_not_exists "pwsh/archive unopenable destination wrote nothing" "$WORK/no-such-dir/out.gz"
# procps is not in tests/shell/Dockerfile, so the process sweep only runs where
# pgrep happens to exist; the marker above is the check that always runs.
if command -v pgrep >/dev/null 2>&1; then
    assert_eq "pwsh/archive left no compressor process behind" "" "$(pgrep -x gzip | tr -d '\n')"
else
    echo "  SKIP: pwsh/archive process sweep (pgrep not installed)"
fi

# Test-Path -PathType Leaf only means "not a container", so a FIFO, /dev/null
# and /dev/zero all passed it and `archive out.zst /dev/zero` would run until
# the disk filled. The POSIX twin refuses these with [ -f ]; pwsh has to ask
# the same question. The FIFO case runs under `timeout` on purpose: if this
# check ever regresses, the compressor blocks on the pipe forever rather than
# failing, and an unguarded run would hang the suite.
echo "[pwsh] archive single-file refuses a source that is not a regular file"
setup_single_file
if command -v mkfifo >/dev/null 2>&1 && mkfifo "$WORK/one/fifo.src" 2>/dev/null; then
    err=$(timeout 30 pwsh -NoProfile -NonInteractive -Command "
        . '$FUNCTIONS_PS1_COMBINED'
        Set-Location '$WORK/one'
        archive 'fifo.gz' 'fifo.src'
    " 2>&1 >/dev/null | sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
    assert_contains "pwsh/archive fifo source usage" "$SINGLE_USAGE" "$err"
    assert_not_exists "pwsh/archive fifo source wrote nothing" "$WORK/one/fifo.gz"
    assert_eq "pwsh/archive fifo source left no temporary" "" "$(ls "$WORK/one" | grep '^fifo\.gz\.tmp' | tr -d '\n')"
else
    echo "  SKIP: pwsh/archive fifo source (mkfifo unavailable)"
fi
if [ -c /dev/null ]; then
    err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive 'dev.gz' '/dev/null'")
    assert_contains "pwsh/archive character-device source usage" "$SINGLE_USAGE" "$err"
    assert_not_exists "pwsh/archive character-device source wrote nothing" "$WORK/one/dev.gz"
    run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive 'dev.gz' '/dev/null'" >/dev/null 2>&1
    assert_eq "pwsh/archive character-device source exits 1" "1" "$?"
else
    echo "  SKIP: pwsh/archive character-device source (/dev/null not a device here)"
fi
# a plain regular file, and a symlink pointing at one, must still be accepted
ln -sf payload.bin "$WORK/one/via-link.bin"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive 'viaLink.gz' 'via-link.bin'" >/dev/null 2>&1
assert_eq "pwsh/archive still accepts a symlink to a regular file" "0" "$?"
assert_exists "pwsh/archive symlink source produced the archive" "$WORK/one/viaLink.gz"

# The refusal is load-bearing, not just a nicer message: staging keeps the
# source readable while the archive is built, but the final rename lands ON the
# output, so wherever the output and the source are one directory entry the
# source is replaced by its own compressed form. A case-sensitive path compare
# missed every alias -- hard link, symlink chain, and on a case-insensitive
# volume a different spelling. The check asks the filesystem now (device and
# inode), so these are refused outright rather than merely survived.
echo "[pwsh] archive refuses an output aliasing the source, by file identity"
for _ext in $SINGLE_FMTS; do
    setup_single_file
    ln -s payload.bin "$WORK/one/hop1.$_ext"
    ln -s "hop1.$_ext" "$WORK/one/hop2.$_ext"
    for _alias in "hop1.$_ext" "hop2.$_ext"; do
        err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive '$_alias' 'payload.bin'")
        assert_contains "pwsh/archive .$_ext '$_alias' refused as the source" "is the source file" "$err"
        actual=$(sha256sum "$WORK/one/payload.bin" 2>/dev/null | cut -d' ' -f1)
        assert_eq "pwsh/archive .$_ext '$_alias' left the source intact" "$PAYLOAD_SHA" "$actual"
    done
    if ln "$WORK/one/payload.bin" "$WORK/one/hard.$_ext" 2>/dev/null; then
        err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive 'hard.$_ext' 'payload.bin'")
        assert_contains "pwsh/archive .$_ext hard link refused as the source" "is the source file" "$err"
        actual=$(sha256sum "$WORK/one/payload.bin" 2>/dev/null | cut -d' ' -f1)
        assert_eq "pwsh/archive .$_ext hard link left the source intact" "$PAYLOAD_SHA" "$actual"
    else
        echo "  SKIP: pwsh/archive .$_ext hard link alias (filesystem refused)"
    fi
done

# The case-insensitive spelling that motivated all of this can only be
# exercised where the filesystem actually folds case. Linux CI cannot make such
# a volume, so this runs on Windows only.
echo "[pwsh] archive refuses a different-case spelling of the source"
if [ "$(run_pwsh "$FUNCTIONS_PS1_COMBINED" 'if ($IsWindows) { "yes" } else { "no" }' 2>/dev/null | tr -d '\r')" = "yes" ]; then
    setup_single_file
    cp "$WORK/one/payload.bin" "$WORK/one/self.gz"
    err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive 'SELF.GZ' 'self.gz'")
    assert_contains "pwsh/archive different-case output refused" "is the source file" "$err"
    assert_eq "pwsh/archive different-case output left the source intact" "$PAYLOAD_SHA" "$(sha256sum "$WORK/one/self.gz" | cut -d' ' -f1)"
else
    echo "  SKIP: pwsh/archive different-case output (needs a case-insensitive volume; Windows only)"
fi

# On Windows there is no 'test -ef', so identity is established from the item's
# own link information: a symlink is resolved to its target, and a hard link
# reports its OTHER names in .Target. Neither can be exercised on Linux -- the
# Windows branch is not even reached -- so the refusals are Windows-only. The
# helpers themselves are smoke-checked everywhere, since a shape they cannot
# handle would throw on the platform that does use them.
echo "[pwsh] archive same-file helpers behave on link input"
setup_single_file
ln -s payload.bin "$WORK/one/smoke-link.bin"
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "
    Set-Location '$WORK/one'
    \$i = Get-Item -LiteralPath 'smoke-link.bin' -Force
    (_ArLinkTarget \$i) + '|' + (_ArVolumeRelative 'C:\Some\Where.gz') + '|' + (_ArVolumeRelative '/tmp/x')
" 2>/dev/null | tr -d '\r')
assert_contains "pwsh/_ArLinkTarget resolves a symlink to its target" "payload.bin" "$actual"
# The volume root is only recognised on the platform that has volumes, so all
# that holds everywhere is: the answer is backslash-rooted and keeps the tail.
assert_contains "pwsh/_ArVolumeRelative keeps the path tail" 'Some\Where.gz' "$actual"
assert_contains "pwsh/_ArVolumeRelative returns a rooted path" '|\' "$actual"

echo "[pwsh] archive refuses a Windows hard link or symlink aliasing the source"
if [ "$(run_pwsh "$FUNCTIONS_PS1_COMBINED" 'if ($IsWindows) { "yes" } else { "no" }' 2>/dev/null | tr -d '\r')" = "yes" ]; then
    actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "_ArVolumeRelative 'C:\Some\Where.gz'" 2>/dev/null | tr -d '\r')
    assert_eq "pwsh/_ArVolumeRelative drops the volume root on windows" '\Some\Where.gz' "$actual"
    setup_single_file
    run_pwsh "$FUNCTIONS_PS1_COMBINED" "New-Item -ItemType HardLink -Path '$WORK/one/hardlink.gz' -Target '$WORK/one/payload.bin' | Out-Null" >/dev/null 2>&1
    err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive 'hardlink.gz' 'payload.bin'")
    assert_contains "pwsh/archive windows hard link refused as the source" "is the source file" "$err"
    assert_eq "pwsh/archive windows hard link left the source intact" "$PAYLOAD_SHA" "$(sha256sum "$WORK/one/payload.bin" | cut -d' ' -f1)"
    run_pwsh "$FUNCTIONS_PS1_COMBINED" "New-Item -ItemType SymbolicLink -Path '$WORK/one/symlink.gz' -Target '$WORK/one/payload.bin' | Out-Null" >/dev/null 2>&1
    err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "Set-Location '$WORK/one'; archive 'symlink.gz' 'payload.bin'")
    assert_contains "pwsh/archive windows symlink refused as the source" "is the source file" "$err"
    assert_eq "pwsh/archive windows symlink left the source intact" "$PAYLOAD_SHA" "$(sha256sum "$WORK/one/payload.bin" | cut -d' ' -f1)"
else
    echo "  SKIP: pwsh/archive windows link aliases (Windows only; the -ef path covers Unix)"
fi

echo "[pwsh] extract unsupported format"
touch "$WORK/test.foo"
err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "extract '$WORK/test.foo'")
assert_contains "pwsh/extract unsupported" "unsupported" "$err"
rm -f "$WORK/test.foo"

echo "[pwsh] path"
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "path | Out-String")
assert_contains "pwsh/path contains /usr" "/usr" "$actual"

echo "[pwsh] up"
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "
    New-Item -ItemType Directory -Force -Path '$WORK/a/b/c' | Out-Null
    Set-Location '$WORK/a/b/c'
    up 2
    (Get-Location).Path
")
assert_eq "pwsh/up 2" "$WORK/a" "$actual"

echo "[pwsh] mkcd"
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "mkcd '$WORK/newdir'; (Get-Location).Path")
assert_eq "pwsh/mkcd" "$WORK/newdir" "$actual"
assert_exists "pwsh/mkcd dir" "$WORK/newdir"
rm -rf "$WORK/newdir"

# --- again / sagain / back ---
echo "[pwsh] again no history"
err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "again")
assert_contains "pwsh/again no history" "no command at position" "$err"

echo "[pwsh] sagain 0"
err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "sagain -N 0")
assert_contains "pwsh/sagain 0 usage" "usage" "$err"

# back N>1 is supported now (browser-style history); with nothing recorded
# yet it reports the empty history instead of "only N=1".
echo "[pwsh] back 2 with no history"
err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "back -N 2")
assert_contains "pwsh/back 2 with no history" "history has 0 back entries" "$err"

echo "[pwsh] back returns to the previous directory"
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "cd '$WORK'; cd /; back *>\$null; (Get-Location).Path" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/back previous dir" "$WORK" "$actual"

# --- directory history: back / fwd (browser-style) ---
# Same fixture as the bash/zsh cases: a fresh pwsh in $DH/start with HOME=$DH.
# pwsh records moves at the prompt (init.ps1 installs _DenDirHookPrompt), and
# den's navigation commands record at once when typed there. A command at the
# top level of -Command counts as typed (CommandOrigin Runspace, as at an
# interactive prompt); a case that needs the prompt installs the hook and calls
# `prompt` where one would come.
setup_dirhist

# dh_pwsh <commands> - stdout; dh_pwsh_err <commands> - stderr (one line, so
# errors show as "<function>: <message>"). back/fwd errors are terminating, so
# `try { ... } catch { 'failed' }` lets a case go on to check where it stayed.
dh_pwsh() {
    (cd "$DH/start" && HOME="$DH" pwsh -NoProfile -NonInteractive -Command ". '$FUNCTIONS_PS1_COMBINED'; $1" 2>/dev/null | tr -d '\r')
}
dh_pwsh_err() {
    (cd "$DH/start" && HOME="$DH" pwsh -NoProfile -NonInteractive -Command ". '$FUNCTIONS_PS1_COMBINED'; $1" 2>&1 >/dev/null |
        sed 's/\x1b\[[0-9;]*m//g' | tr -d '\r')
}

echo "[pwsh] back N / fwd N"
out=$(dh_pwsh "cd '$DH/a'; cd '$DH/b'; Set-Location '$DH/c'; back 2; (Get-Location).Path; fwd; (Get-Location).Path; fwd; (Get-Location).Path")
assert_eq "pwsh/back 2, fwd, fwd" "$DH/a
$DH/b
$DH/c" "$out"
out=$(dh_pwsh "cd '$DH/a'; cd '$DH/b'; back 2; fwd 2; (Get-Location).Path")
assert_eq "pwsh/back 2 then fwd 2 returns" "$DH/b" "$out"

echo "[pwsh] back -l"
out=$(dh_pwsh "cd '$DH'; cd /; cd '$DH/b'; cd '$DH/c'; back 2; back -l")
assert_eq "pwsh/back -l lists back, current and forward" "  2  ~/start
  1  ~
  *  /
 +1  ~/b
 +2  ~/c" "$out"

echo "[pwsh] a consecutive duplicate is recorded once"
out=$(dh_pwsh "cd '$DH/a'; cd '$DH/a'; Set-Location .; back -l")
assert_eq "pwsh/no consecutive duplicates" "  1  ~/start
  *  ~/a" "$out"

echo "[pwsh] a new move clears the forward list"
out=$(dh_pwsh "cd '$DH/a'; cd '$DH/b'; back; cd '$DH/c'; try { fwd } catch { 'failed' }; (Get-Location).Path")
assert_eq "pwsh/new move clears forward (stays)" "failed
$DH/c" "$out"
err=$(dh_pwsh_err "cd '$DH/a'; cd '$DH/b'; back; cd '$DH/c'; fwd")
assert_eq "pwsh/new move clears forward (message)" "fwd: history has 0 forward entries, cannot go forward 1" "$err"

echo "[pwsh] N larger than the history"
out=$(dh_pwsh "cd '$DH/a'; cd '$DH/b'; try { back 5 } catch { 'failed' }; (Get-Location).Path")
assert_eq "pwsh/back 5 stays" "failed
$DH/b" "$out"
dh_pwsh "cd '$DH/a'; back 5" >/dev/null
assert_eq "pwsh/back 5 exits 1" "1" "$?"
err=$(dh_pwsh_err "cd '$DH/a'; cd '$DH/b'; back 5")
assert_eq "pwsh/back 5 says how many" "back: history has 2 back entries, cannot go back 5" "$err"
err=$(dh_pwsh_err "cd '$DH/a'; back 99999999999999999999")
assert_eq "pwsh/back huge N" "back: history has 1 back entry, cannot go back 99999999999999999999" "$err"

echo "[pwsh] N not a positive integer"
for bad in abc 01; do
    err=$(dh_pwsh_err "back $bad")
    assert_eq "pwsh/back $bad usage" "back: usage: [N | -l | -i]  (N=positive integer, default 1)" "$err"
done
err=$(dh_pwsh_err "fwd 0")
assert_eq "pwsh/fwd 0 usage" "fwd: usage: [N]  (N=positive integer, default 1)" "$err"
dh_pwsh "fwd 0" >/dev/null
assert_eq "pwsh/fwd 0 exits 1" "1" "$?"

echo "[pwsh] a target that no longer exists is dropped"
out=$(dh_pwsh "cd '$DH/a'; cd '$DH/b'; Remove-Item '$DH/a'; try { back } catch { 'failed' }; (Get-Location).Path; back -l")
assert_eq "pwsh/removed target dropped, stays put" "failed
$DH/b
  1  ~/start
  *  ~/b" "$out"
mkdir -p "$DH/a"
err=$(dh_pwsh_err "cd '$DH/a'; cd '$DH/b'; Remove-Item '$DH/a'; back")
assert_eq "pwsh/removed target message" "back: $DH/a no longer exists, dropped from history" "$err"
mkdir -p "$DH/a"
out=$(dh_pwsh "cd '$DH/a'; cd '$DH/b'; cd '$DH/c'; back 2; Remove-Item '$DH/b'; try { fwd } catch { 'failed' }; (Get-Location).Path; back -l")
assert_eq "pwsh/removed forward target dropped, stays put" "failed
$DH/a
  1  ~/start
  *  ~/a
 +1  ~/c" "$out"
mkdir -p "$DH/b"
err=$(dh_pwsh_err "cd '$DH/a'; cd '$DH/b'; cd '$DH/c'; back 2; Remove-Item '$DH/b'; fwd")
assert_eq "pwsh/removed forward target message" "fwd: $DH/b no longer exists, dropped from history" "$err"
mkdir -p "$DH/b"

echo "[pwsh] Push-Location / Pop-Location are recorded at the prompt"
out=$(dh_pwsh "_DenDirHookPrompt; Push-Location '$DH/a'; \$null = prompt; Push-Location '$DH/b'; \$null = prompt; Pop-Location; \$null = prompt; back -l")
assert_eq "pwsh/Push-Location and Pop-Location recorded" "  3  ~/start
  2  ~/a
  1  ~/b
  *  ~/a" "$out"

echo "[pwsh] the back list keeps 50 entries"
out=$(dh_pwsh "_DenDirHookPrompt; 1..30 | ForEach-Object { Set-Location '$DH/a'; \$null = prompt; Set-Location '$DH/b'; \$null = prompt }; @(back -l).Count")
assert_eq "pwsh/back list capped at 50" "51" "$out"

echo "[pwsh] back -i picks an entry with fzf"
out=$(dh_pwsh "\$env:PATH = '$DH/fzfbin:' + \$env:PATH; \$env:FZF_PICK = '2'; cd '$DH/a'; cd '$DH/b'; cd '$DH/c'; back -i; (Get-Location).Path; \$env:FZF_PICK = '+2'; back -i; (Get-Location).Path; \$env:FZF_PICK = '*'; back -i; (Get-Location).Path")
assert_eq "pwsh/back -i back, forward, current" "$DH/a
$DH/c
$DH/c" "$out"
err=$(dh_pwsh_err "\$env:PATH = '$DH/nobin'; back -i")
assert_contains "pwsh/back -i without fzf" "back: fzf is not installed." "$err"
dh_pwsh "\$env:PATH = '$DH/nobin'; back -i" >/dev/null
assert_eq "pwsh/back -i without fzf exits 1" "1" "$?"

# LocationChangedAction also fires for every move a script makes, so den does
# not hook it; a handler set before den loads stays as it was and keeps running.
echo "[pwsh] LocationChangedAction is left alone"
out=$(cd "$DH/start" && HOME="$DH" pwsh -NoProfile -NonInteractive -Command "\$global:hits = 0; \$ExecutionContext.InvokeCommand.LocationChangedAction = { \$global:hits++ }; \$before = \$ExecutionContext.InvokeCommand.LocationChangedAction; . '$FUNCTIONS_PS1_COMBINED'; \"kept=\$([object]::ReferenceEquals(\$before, \$ExecutionContext.InvokeCommand.LocationChangedAction))\"; cd '$DH/a'; cd '$DH/b'; back; \"hits=\$global:hits\"; (Get-Location).Path" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/LocationChangedAction not replaced, still runs" "kept=True
hits=3
$DH/a" "$out"

# The prompt is the recorder on every PowerShell (Windows PowerShell 5.1 has no
# LocationChangedAction at all); init.ps1 wraps starship's prompt with it.
echo "[pwsh] prompt hook"
out=$(dh_pwsh "function global:prompt { 'st=' + \$global:? }; _DenDirHookPrompt; _DenDirHookPrompt; Set-Location '$DH/a'; \$null = prompt; Set-Location '$DH/b'; \$null = prompt; Get-Item '$DH/missing' -ErrorAction SilentlyContinue; prompt; \$null = 1; prompt; back -l")
assert_eq "pwsh/prompt hook records, keeps \$?, wraps once" "st=False
st=True
  2  ~/start
  1  ~/a
  *  ~/b" "$out"
out=$(dh_pwsh "_DenDirHookPrompt; cd '$DH/a'; cd '$DH/b'; back; \$null = prompt; fwd; (Get-Location).Path")
assert_eq "pwsh/prompt does not record back as a new move" "$DH/b" "$out"

# Only where the session is at each prompt counts, as with bash's
# PROMPT_COMMAND: moves on the way there (several Set-Location on one line, the
# moves a script or a function makes, den's cd among them) are not history.
echo "[pwsh] moves between two prompts count once"
out=$(dh_pwsh "_DenDirHookPrompt; cd '$DH/a'; cd '$DH/b'; Set-Location '$DH/c'; Set-Location '$DH/start'; \$null = prompt; back -l")
assert_eq "pwsh/Set-Location twice on one line is one move" "  3  ~/start
  2  ~/a
  1  ~/b
  *  ~/start" "$out"
mkdir -p "$DH/scr"
printf '%s\n' 'Push-Location $PSScriptRoot' 'try {} finally { Pop-Location }' > "$DH/scr/pushpop.ps1"
out=$(dh_pwsh "_DenDirHookPrompt; cd '$DH/a'; cd ../b; back; \$null = prompt; & '$DH/scr/pushpop.ps1'; \$null = prompt; back -l; fwd; (Get-Location).Path")
assert_eq "pwsh/script Push-Location, Pop-Location leave the history" "  1  ~/start
  *  ~/a
 +1  ~/b
$DH/b" "$out"
printf '%s\n' 'Set-Location $PSScriptRoot' 'cd ../a' 'Push-Location ../b' 'mkcd ../c' > "$DH/scr/net.ps1"
out=$(dh_pwsh "_DenDirHookPrompt; cd '$DH/b'; & '$DH/scr/net.ps1'; \$null = prompt; back -l")
assert_eq "pwsh/script ending elsewhere is one move" "  2  ~/start
  1  ~/b
  *  ~/c" "$out"
out=$(dh_pwsh "function global:proj { cd '$DH/a'; mkcd '$DH/b'; up }; proj; back -l")
assert_eq "pwsh/function's den cd, mkcd, up are one move" "  1  ~/start
  *  ~" "$out"

# Typed at the prompt, each den navigation command records its move at once;
# the Set-Location after them only shows up through back -l. `.1` is called as
# `& '.1'`: a bare .1 is the number 0.1 to PowerShell.
echo "[pwsh] den's navigation commands typed at the prompt record at once"
out=$(dh_pwsh "mkcd '$DH/a/n/m'; up; & '.1'; ..; Set-Location '$DH/c'; back -l")
assert_eq "pwsh/mkcd, up, .1, .. each recorded" "  5  ~/start
  4  ~/a/n/m
  3  ~/a/n
  2  ~/a
  1  ~
  *  ~/c" "$out"
rm -rf "$DH/a/n"
# The same for zd, zdi, cdi, cdf and y, each through a stub: __zoxide_z /
# __zoxide_zi just Set-Location, fzf is the fixture's stub (fd is left off PATH
# so cdf lists full paths), and yazi writes $YAZI_CWD to its --cwd-file.
mkdir -p "$DH/c/d" "$DH/ybin"
cat > "$DH/ybin/yazi" <<'STUB'
#!/bin/sh
for a; do
    case $a in --cwd-file=*) printf '%s\n' "$YAZI_CWD" > "${a#--cwd-file=}" ;; esac
done
STUB
chmod +x "$DH/ybin/yazi"
out=$(dh_pwsh "\$env:PATH = '$DH/fzfbin:$DH/ybin'; function global:__zoxide_z { Set-Location @args }; function global:__zoxide_zi { Set-Location @args }; zd '$DH/a'; zdi '$DH/b'; cdi '$DH/c'; \$env:FZF_PICK = '$DH/c/d'; cdf; \$env:YAZI_CWD = '$DH/a'; y; Set-Location '$DH/start'; back -l")
assert_eq "pwsh/zd, zdi, cdi, cdf, y each recorded" "  6  ~/start
  5  ~/a
  4  ~/b
  3  ~/c
  2  ~/c/d
  1  ~/a
  *  ~/start" "$out"
rm -rf "$DH/c/d"

# init.ps1 installs the recorder: it wraps the prompt after starship's init has
# replaced it. A stub starship stands in for the real one, and HOME /
# XDG_DATA_HOME point into the fixture, so the init cache is written there and
# never over the user's own.
echo "[pwsh] init.ps1 wraps starship's prompt with the recorder"
mkdir -p "$DH/stbin" "$DH/.local/share"
cat > "$DH/stbin/starship" <<'STUB'
#!/bin/sh
printf '%s\n' 'function global:prompt { "stub:$($global:?)>" }'
STUB
chmod +x "$DH/stbin/starship"
dh_pwsh_init() {
    (cd "$DH/start" && HOME="$DH" XDG_DATA_HOME="$DH/.local/share" PATH="$DH/stbin:$PATH" \
        pwsh -NoProfile -NonInteractive -Command ". '$DOTFILES/shell/pwsh/init.ps1'; $1" 2>/dev/null | tr -d '\r')
}
out=$(dh_pwsh_init "\$function:prompt -eq \$global:_DenDirPrompt; \"\$global:_DenDirPromptOld\".Trim(); Get-Item '$DH/missing' -ErrorAction SilentlyContinue; prompt")
assert_eq "pwsh/init.ps1 prompt is den's wrapper around starship's, which still gets \$?" 'True
"stub:$($global:?)>"
stub:False>' "$out"
out=$(dh_pwsh_init "Set-Location '$DH/a'; \$null = prompt; Set-Location '$DH/b'; \$null = prompt; back; \$null = prompt; & '$DH/scr/pushpop.ps1'; \$null = prompt; back -l; fwd; (Get-Location).Path")
assert_eq "pwsh/init.ps1 prompt records moves, not a script's Push-/Pop-Location" "  1  ~/start
  *  ~/a
 +1  ~/b
$DH/b" "$out"

# =============================================================================
# Stderr format tests — Write-Error double-prefix prevention
# =============================================================================
echo ""
echo "================================================"
echo "  Testing stderr format (no double-prefix)"
echo "================================================"
# These cases go through run_pwsh_stderr_oneline on purpose: see the runner's
# comment in helpers.sh. With the multi-line run_pwsh_stderr the forbidden
# "<fn>: <fn>:" shape is split across two lines and every assertion below
# passes whether or not the bug is present.

echo "[pwsh] digest usage stderr"
err=$(run_pwsh_stderr_oneline "$FUNCTIONS_PS1_COMBINED" "digest sha256")
assert_contains "pwsh/digest stderr has usage" "usage:" "$err"
assert_not_contains "pwsh/digest no double prefix" "digest: digest:" "$err"
run_pwsh "$FUNCTIONS_PS1_COMBINED" "digest sha256" >/dev/null 2>&1
assert_eq "pwsh/digest usage exits 1" "1" "$?"

echo "[pwsh] mkcd usage stderr"
err=$(run_pwsh_stderr_oneline "$FUNCTIONS_PS1_COMBINED" "mkcd")
assert_contains "pwsh/mkcd stderr has usage" "usage:" "$err"
assert_not_contains "pwsh/mkcd no double prefix" "mkcd: mkcd:" "$err"

echo "[pwsh] again usage stderr"
err=$(run_pwsh_stderr_oneline "$FUNCTIONS_PS1_COMBINED" "again -N 0")
assert_contains "pwsh/again stderr has usage" "usage:" "$err"
assert_not_contains "pwsh/again no double prefix" "again: again:" "$err"

echo "[pwsh] back usage stderr"
err=$(run_pwsh_stderr_oneline "$FUNCTIONS_PS1_COMBINED" "back -N 0")
assert_contains "pwsh/back stderr has usage" "usage:" "$err"
assert_not_contains "pwsh/back no double prefix" "back: back:" "$err"

# =============================================================================
# cmd: the directory-history promptfilter in starship.lua (Lua, stubbed Clink)
# =============================================================================
# cmd and Clink cannot run here, but the filter is plain Lua: load starship.lua
# against a stub of the Clink calls it makes and drive it prompt by prompt. The
# shim() below does what back.cmd does to the lists: back N takes the Nth entry
# from the END of _DEN_DIRBACK (stored farthest first), fwd N the Nth of
# _DEN_DIRFWD, then it changes directory and leaves its note in _DEN_DIRNAV.
echo ""
echo "================================================"
echo "  Testing starship.lua (cmd) directory history with Lua"
echo "================================================"

LUA_BIN=$(command -v lua5.4 || command -v lua5.3 || command -v lua || true)
if [ -z "$LUA_BIN" ]; then
    echo "  SKIP: cmd/directory history filter (no lua interpreter)"
else
    cat > "$WORK/dirhist_harness.lua" <<'LUA'
local env = { LOCALAPPDATA = "C:\\L", PATH = "", STARSHIP_CPU_INTEL = "stub",
              _DEN_DIRBACK = "C:\\old", _DEN_DIRFWD = "C:\\old", _DEN_DIRNAV = "back:1" }
local cwd = "C:\\start"
local gone = {}
settings = { set = function() end }
os.getenv = function(n) return env[n] end
os.setenv = function(n, v) env[n] = v; return true end
os.getcwd = function() return cwd end
os.isdir = function(p) return not gone[p:lower()] end
os.execute = function() return true end
local filters = {}
clink = { promptfilter = function() local f = {}; filters[#filters + 1] = f; return f end }
dofile(arg[1])

local function prompt() for _, f in ipairs(filters) do f:filter("") end end
local function state(label)
    print(label .. ": back=" .. (env._DEN_DIRBACK or "") .. " fwd=" .. (env._DEN_DIRFWD or "")
        .. " nav=" .. (env._DEN_DIRNAV or "") .. " oldpwd=" .. (env._OLDPWD or ""))
end
local function cd(d) cwd = d; prompt() end
local function shim(cmd, n)
    local t = {}
    for x in ((cmd == "back" and env._DEN_DIRBACK or env._DEN_DIRFWD) or ""):gmatch("[^|]+") do
        t[#t + 1] = x
    end
    local target = t[cmd == "back" and (#t - n + 1) or n]
    if gone[target:lower()] then
        env._DEN_DIRNAV = "drop" .. cmd .. ":" .. n
    else
        env._DEN_DIRNAV = cmd .. ":" .. n
        cwd = target
    end
    prompt()
end

state("load")
cd("C:\\a"); cd("C:\\b"); cd("C:\\c"); state("moves")
cd("c:\\C"); state("same dir, other case")
shim("back", 2); state("back 2")
shim("fwd", 1); state("fwd 1")
shim("back", 1); cd("C:\\d"); state("back 1, then a move")
gone["c:\\a"] = true; shim("back", 1); state("back 1 to a removed dir")
env._DEN_DIRNAV = "back:1"; prompt(); state("note without a move")
cd("C:\\e"); cd("C:\\f"); shim("back", 3); state("back 3")
gone["c:\\e"] = true; shim("fwd", 2); state("fwd 2 to a removed dir")
shim("fwd", 2); state("fwd 2 after the drop")
for i = 1, 30 do cd("C:\\a"); cd("C:\\b") end
local n = 0
for _ in env._DEN_DIRBACK:gmatch("[^|]+") do n = n + 1 end
print("entries after 60 moves: " .. n)
LUA
    out=$("$LUA_BIN" "$WORK/dirhist_harness.lua" "$DOTFILES/shell/cmd/starship.lua" 2>&1)
    assert_eq "cmd/filter lists: start empty, record, rotate, drop, cap" 'load: back= fwd= nav= oldpwd=
moves: back=C:\start|C:\a|C:\b fwd= nav= oldpwd=C:\b
same dir, other case: back=C:\start|C:\a|C:\b fwd= nav= oldpwd=C:\c
back 2: back=C:\start fwd=C:\b|c:\C nav= oldpwd=c:\C
fwd 1: back=C:\start|C:\a fwd=c:\C nav= oldpwd=C:\a
back 1, then a move: back=C:\start|C:\a fwd= nav= oldpwd=C:\a
back 1 to a removed dir: back=C:\start fwd= nav= oldpwd=C:\a
note without a move: back=C:\start fwd= nav= oldpwd=C:\a
back 3: back= fwd=C:\d|C:\e|C:\f nav= oldpwd=C:\f
fwd 2 to a removed dir: back= fwd=C:\d|C:\f nav= oldpwd=C:\f
fwd 2 after the drop: back=C:\start|C:\d fwd= nav= oldpwd=C:\start
entries after 60 moves: 25' "$out"
fi

# =============================================================================
# Summary
# =============================================================================
print_summary "test_functions"
[ "$FAIL" -eq 0 ]
