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
# 7z is installed neither here nor in tests/shell/Dockerfile, which is the
# other reason its branches need a stub at all.
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

echo "[bash] back 2"
err=$(run_bash_stderr "$FUNCTIONS_SH" "back 2")
assert_contains "bash/back 2 unsupported" "only N=1" "$err"

echo "[bash] back with OLDPWD"
actual=$(run_bash "$FUNCTIONS_SH" "cd /tmp && cd /root && back" 2>/dev/null)
assert_eq "bash/back OLDPWD" "/tmp" "$actual"

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

echo "[zsh] back 2"
err=$(run_zsh_stderr "$FUNCTIONS_SH" "back 2")
assert_contains "zsh/back 2 unsupported" "only N=1" "$err"

echo "[zsh] back with OLDPWD"
actual=$(run_zsh "$FUNCTIONS_SH" "cd /tmp && cd /root && back" 2>/dev/null)
assert_eq "zsh/back OLDPWD" "/tmp" "$actual"

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

echo "[pwsh] back 2"
err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "back -N 2")
assert_contains "pwsh/back 2 unsupported" "only N=1" "$err"

echo "[pwsh] back returns to the previous directory (Set-Location -)"
actual=$(run_pwsh "$FUNCTIONS_PS1_COMBINED" "cd '$WORK'; cd /; back *>\$null; (Get-Location).Path" 2>/dev/null | tr -d '\r')
assert_eq "pwsh/back previous dir" "$WORK" "$actual"

# NB: the "no previous directory" catch branch is intentionally not unit-tested.
# `Set-Location -` on a fresh runspace depends on pwsh's internal location-history
# state (empty vs. a single startup entry), which varies by host and pwsh version,
# so any fresh-session assertion is flaky. The happy-path round-trip above covers
# the fix; the try/catch is a defensive guard for genuine failures.

# =============================================================================
# Stderr format tests — Write-Error double-prefix prevention
# =============================================================================
echo ""
echo "================================================"
echo "  Testing stderr format (no double-prefix)"
echo "================================================"

echo "[pwsh] mkcd usage stderr"
err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "mkcd")
assert_contains "pwsh/mkcd stderr has usage" "usage:" "$err"
assert_not_contains "pwsh/mkcd no double prefix" "mkcd: mkcd:" "$err"

echo "[pwsh] again usage stderr"
err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "again -N 0")
assert_contains "pwsh/again stderr has usage" "usage:" "$err"
assert_not_contains "pwsh/again no double prefix" "again: again:" "$err"

echo "[pwsh] back usage stderr"
err=$(run_pwsh_stderr "$FUNCTIONS_PS1_COMBINED" "back -N 0")
assert_contains "pwsh/back stderr has usage" "usage:" "$err"
assert_not_contains "pwsh/back no double prefix" "back: back:" "$err"

# =============================================================================
# Summary
# =============================================================================
print_summary "test_functions"
[ "$FAIL" -eq 0 ]
