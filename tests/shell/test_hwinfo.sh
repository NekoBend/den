#!/usr/bin/env bash
# test_hwinfo.sh — Tests for hwinfo.sh / hwinfo.ps1 (toggle-hwinfo).
# Also scans every shell/pwsh/*.ps1 for the PowerShell 6/7-only syntax its scan
# lists, which Windows PowerShell 5.1 rejects or reads differently, and for reads
# of the platform variables ($IsWindows, ...) that 5.1 does not have.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

# helpers.sh already honours a DOTFILES override so the suite can run against a
# checkout; hardcoding it here silently discarded that and tested the INSTALLED
# copy instead, whatever DOTFILES said.
DOTFILES="${DOTFILES:-/root/.dotfiles}"
HWINFO_SH_GUARDED="$DOTFILES/shell/posix/hwinfo.sh"
HWINFO_PS1="$DOTFILES/shell/pwsh/hwinfo.ps1"

HWINFO_SH="$TESTTMP/hwinfo_test.sh"
make_noninteractive_source_copy "$HWINFO_SH_GUARDED" "$HWINFO_SH"

# Extract only the toggle-hwinfo function from pwsh (detection uses Windows-only APIs)
HWINFO_PS1_TOGGLE="$TESTTMP/hwinfo_toggle.ps1"
awk '/^function toggle-hwinfo/,0' "$HWINFO_PS1" > "$HWINFO_PS1_TOGGLE"

# =============================================================================
# Bash tests
# =============================================================================

echo "[bash] toggle-hwinfo OFF message"
actual=$(run_bash "$HWINFO_SH" '
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    export STARSHIP_CPU_INTEL="i9-13900K"
    export STARSHIP_GPU_NVIDIA="RTX 4090"
    toggle-hwinfo
')
assert_contains "bash/toggle-hwinfo OFF message" "hwinfo: OFF" "$actual"

echo "[bash] toggle-hwinfo OFF clears vars"
actual=$(run_bash "$HWINFO_SH" '
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    export STARSHIP_CPU_INTEL="i9-13900K"
    export STARSHIP_GPU_NVIDIA="RTX 4090"
    toggle-hwinfo >/dev/null
    echo "CPU=${STARSHIP_CPU_INTEL:-UNSET}"
    echo "GPU=${STARSHIP_GPU_NVIDIA:-UNSET}"
')
assert_contains "bash/toggle OFF cpu cleared" "CPU=UNSET" "$actual"
assert_contains "bash/toggle OFF gpu cleared" "GPU=UNSET" "$actual"

echo "[bash] toggle-hwinfo OFF saves vars"
actual=$(run_bash "$HWINFO_SH" '
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    export STARSHIP_CPU_INTEL="i9-13900K"
    export STARSHIP_GPU_NVIDIA="RTX 4090"
    toggle-hwinfo >/dev/null
    echo "SAVED_CPU=$_DEN_SAVED_CPU_INTEL"
    echo "SAVED_GPU=$_DEN_SAVED_GPU_NVIDIA"
    echo "HIDDEN=$_DEN_HWINFO_HIDDEN"
')
assert_contains "bash/toggle OFF saved cpu" "SAVED_CPU=i9-13900K" "$actual"
assert_contains "bash/toggle OFF saved gpu" "SAVED_GPU=RTX 4090" "$actual"
assert_contains "bash/toggle OFF hidden flag" "HIDDEN=1" "$actual"

echo "[bash] toggle-hwinfo ON message"
actual=$(run_bash "$HWINFO_SH" '
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    export STARSHIP_CPU_INTEL="i9-13900K"
    export STARSHIP_GPU_NVIDIA="RTX 4090"
    toggle-hwinfo >/dev/null
    toggle-hwinfo
')
assert_contains "bash/toggle-hwinfo ON message" "hwinfo: ON" "$actual"

echo "[bash] toggle-hwinfo roundtrip restores vars"
actual=$(run_bash "$HWINFO_SH" '
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    export STARSHIP_CPU_INTEL="i9-13900K"
    export STARSHIP_GPU_NVIDIA="RTX 4090"
    toggle-hwinfo >/dev/null
    toggle-hwinfo >/dev/null
    echo "CPU=$STARSHIP_CPU_INTEL"
    echo "GPU=$STARSHIP_GPU_NVIDIA"
    echo "HIDDEN=$_DEN_HWINFO_HIDDEN"
')
assert_contains "bash/roundtrip cpu" "CPU=i9-13900K" "$actual"
assert_contains "bash/roundtrip gpu" "GPU=RTX 4090" "$actual"
assert_contains "bash/roundtrip hidden" "HIDDEN=0" "$actual"

# tgl-hw is the short name: a function (not an interactive-only alias) that
# does exactly what toggle-hwinfo does. The trailing echo keeps the status 0,
# so a missing tgl-hw fails the assertion instead of stopping the suite.
echo "[bash] tgl-hw flips like toggle-hwinfo"
actual=$(run_bash "$HWINFO_SH" '
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    export STARSHIP_CPU_INTEL="i9-13900K"
    echo "TYPE=$(type -t tgl-hw)"
    tgl-hw
    echo "OFF:CPU=${STARSHIP_CPU_INTEL:-UNSET} HIDDEN=$_DEN_HWINFO_HIDDEN"
    tgl-hw
    echo "ON:CPU=$STARSHIP_CPU_INTEL HIDDEN=$_DEN_HWINFO_HIDDEN"
' 2>/dev/null)
assert_eq "bash/tgl-hw OFF then ON" "TYPE=function
hwinfo: OFF (hidden from prompt)
OFF:CPU=UNSET HIDDEN=1
hwinfo: ON (visible in prompt)
ON:CPU=i9-13900K HIDDEN=0" "$actual"

echo "[bash] guard: non-interactive source skips hwinfo"
actual=$(bash -c "
    source '$HWINFO_SH_GUARDED'
    type toggle-hwinfo >/dev/null 2>&1 && echo 'DEFINED' || echo 'UNDEFINED'
" | tr -d '\r')
assert_eq "bash/guard non-interactive" "UNDEFINED" "$actual"

echo "[bash] toggle-hwinfo defined with cached env"
actual=$(bash -c "
    export STARSHIP_CPU_INTEL='Cached'
    source '$HWINFO_SH'
    type toggle-hwinfo >/dev/null 2>&1 && echo 'DEFINED' || echo 'UNDEFINED'
" | tr -d '\r')
assert_eq "bash/toggle-hwinfo cached env" "DEFINED" "$actual"

echo "[bash] Intel GPU detection via lspci"
# Mock lspci and point the cache at an empty dir so live detection runs; pre-fix
# no block ever set STARSHIP_GPU_INTEL on POSIX (parity gap with hwinfo.ps1).
HWINFO_MOCKBIN="$WORK/hwinfo-mockbin"
mkdir -p "$HWINFO_MOCKBIN"
cat > "$HWINFO_MOCKBIN/lspci" << 'MOCK'
#!/bin/sh
echo "00:02.0 VGA compatible controller: Intel Corporation UHD Graphics 620 (rev 07)"
MOCK
chmod +x "$HWINFO_MOCKBIN/lspci"
actual=$(bash -c "
    export PATH=\"$HWINFO_MOCKBIN:\$PATH\"
    export XDG_RUNTIME_DIR='$WORK/hwinfo-emptycache'
    mkdir -p \"\$XDG_RUNTIME_DIR\"
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    source '$HWINFO_SH'
    echo \"GPU_INTEL=\$STARSHIP_GPU_INTEL\"
" | tr -d '\r')
assert_contains "bash/Intel GPU via lspci" "GPU_INTEL=UHD Graphics 620" "$actual"

# hwinfo_file <runtime dir> - the cache file hwinfo.sh keeps in that directory:
# den-hwinfo.<machine id>.sh, the host name standing in for a missing or empty
# /etc/machine-id (_den_hwinfo_file)
hwinfo_file() {
    local mid=
    { IFS= read -r mid < /etc/machine-id; } 2>/dev/null
    [ -n "$mid" ] || mid=${HOSTNAME:-$(hostname 2>/dev/null)}
    printf '%s/den-hwinfo.%s.sh\n' "$1" "${mid:-unknown}"
}

echo "[bash] cache write ignores a planted temp symlink"
# The old write path opened the predictable "$cache.tmp.$$" with a truncating
# redirect, so another user sharing /tmp (XDG_RUNTIME_DIR unset) could pre-plant
# that name as a symlink and have the shell rewrite the file it points at.
mkdir -p "$WORK/hwinfo-symcache"
echo "VICTIM" > "$WORK/hwinfo-victim.txt"
hw_sym_f=$(hwinfo_file "$WORK/hwinfo-symcache")
actual=$(bash -c "
    export XDG_RUNTIME_DIR='$WORK/hwinfo-symcache'
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    ln -sf '$WORK/hwinfo-victim.txt' \"$hw_sym_f.tmp.\$\$\"
    source '$HWINFO_SH'
    command cat '$WORK/hwinfo-victim.txt'
" | tr -d '\r')
assert_eq "bash/hwinfo does not write through planted symlink" "VICTIM" "$actual"
assert_exists "bash/hwinfo cache still written" "$hw_sym_f"

# toggle-hwinfo exports _DEN_HWINFO_HIDDEN, so a reload or a child shell starts
# with it while the cache still holds the values: loading them anyway showed them
# under an OFF, and the next toggle took the ON branch and changed nothing.
HW_HIDDEN_RT="$WORK/hwinfo-hidden-rt"
mkdir -p "$HW_HIDDEN_RT"
hw_hidden_f=$(hwinfo_file "$HW_HIDDEN_RT")
printf "export STARSHIP_CPU_INTEL='i9-13900K'\n" > "$hw_hidden_f"
chmod 600 "$hw_hidden_f"
for sh in bash zsh; do
    echo "[$sh] _DEN_HWINFO_HIDDEN=1 at load keeps the cached info hidden; one toggle shows it"
    actual=$(env -u STARSHIP_CPU_INTEL -u STARSHIP_CPU_AMD -u STARSHIP_GPU_NVIDIA -u STARSHIP_GPU_AMD \
        -u STARSHIP_GPU_INTEL -u _DEN_SAVED_CPU_INTEL XDG_RUNTIME_DIR="$HW_HIDDEN_RT" _DEN_HWINFO_HIDDEN=1 \
        "$sh" -c "
            source '$HWINFO_SH'
            echo \"LOAD:CPU=\${STARSHIP_CPU_INTEL:-UNSET} SAVED=\$_DEN_SAVED_CPU_INTEL\"
            toggle-hwinfo
            echo \"ON:CPU=\$STARSHIP_CPU_INTEL HIDDEN=\$_DEN_HWINFO_HIDDEN\"
        " 2>&1 | tr -d '\r')
    assert_eq "$sh/_DEN_HWINFO_HIDDEN=1 at load" "LOAD:CPU=UNSET SAVED=i9-13900K
hwinfo: ON (visible in prompt)
ON:CPU=i9-13900K HIDDEN=0" "$actual"
done

# A machine whose CPU and GPU den does not recognize (no Intel or AMD model
# name, no nvidia-smi, rocm-smi or lspci): the cache den wrote then held no
# value, so every start ran the detection again. Now the cache ends with
# _DEN_HWINFO_CACHED=1 and counts as a hit. awk is a function here that logs
# each call and recognizes nothing; PATH holds only the programs the cache
# write needs, and cat, which logs each run: the machine id is read with the
# read builtin, and not at all when STARSHIP_* came from the parent.
HWN="$WORK/hwinfo-none"
mkdir -p "$HWN/bin"
for t in mktemp mv rm sed hostname; do
    p=$(command -v "$t") && ln -s "$p" "$HWN/bin/$t"
done
printf '#!/bin/sh\necho cat >> "%s/cat.log"\nexec %s "$@"\n' "$HWN" "$(command -v cat)" > "$HWN/bin/cat"
chmod +x "$HWN/bin/cat"
for sh in bash zsh; do
    sh_bin=$(command -v "$sh")
    mkdir -p "$HWN/rt-$sh"
    # hw_none_start [VAR=value...] - one start of hwinfo.sh on that machine
    hw_none_start() {
        env -u STARSHIP_CPU_INTEL -u STARSHIP_CPU_AMD -u STARSHIP_GPU_NVIDIA -u STARSHIP_GPU_AMD \
            -u STARSHIP_GPU_INTEL XDG_RUNTIME_DIR="$HWN/rt-$sh" PATH="$HWN/bin" HWN_LOG="$HWN/awk-$sh.log" "$@" \
            "$sh_bin" -c "
                awk() { echo awk >> \"\$HWN_LOG\"; }
                . '$HWINFO_SH'
                echo \"CPU=\${STARSHIP_CPU_INTEL-} GPU=\${STARSHIP_GPU_NVIDIA-}\"
            " 2>&1
    }
    echo "[$sh] a cache with no CPU or GPU den recognizes counts: one detection in two starts"
    actual=$(hw_none_start; hw_none_start)
    assert_eq "$sh/no recognized hardware: nothing set" "CPU= GPU=
CPU= GPU=" "$actual"
    assert_eq "$sh/no recognized hardware: detected once" "awk" "$(cat "$HWN/awk-$sh.log" 2>/dev/null)"
    assert_eq "$sh/no recognized hardware: the cache says so" "_DEN_HWINFO_CACHED=1" \
        "$(cat "$(hwinfo_file "$HWN/rt-$sh")" 2>/dev/null)"
    echo "[$sh] no cat process: not with values from the parent, not with a cache"
    rm -f "$HWN/cat.log"
    actual=$(hw_none_start STARSHIP_CPU_INTEL=i9; hw_none_start)
    assert_eq "$sh/hwinfo runs no cat" "" "$(cat "$HWN/cat.log" 2>/dev/null)"
done

# set -C alone opens an existing FIFO or device, or a link to one, so without
# mktemp a FIFO at the cache's temporary name, or a link to one, made the shell
# start wait for a reader, and a link to /dev/null was taken, then moved in as
# the cache. Any existing name is refused now, and no cache is written that
# time. This PATH has no mktemp at all, and timeout ends a start that waits.
mkdir -p "$HWN/bin-nomktemp"
for t in mv rm sed hostname; do
    p=$(command -v "$t") && ln -sf "$p" "$HWN/bin-nomktemp/$t"
done
[ -p "$HWN/fifo" ] || mkfifo "$HWN/fifo"
for sh in bash zsh; do
    sh_bin=$(command -v "$sh")
    for kind in fifo-link null-link fifo; do
        case $kind in
            fifo-link) what='symlink to a FIFO' mk="'$(command -v ln)' -s '$HWN/fifo'" ;;
            null-link) what='symlink to /dev/null' mk="'$(command -v ln)' -s /dev/null" ;;
            *) what='FIFO' mk="'$(command -v mkfifo)'" ;;
        esac
        echo "[$sh] with no mktemp, a $what at the cache's temporary name is refused"
        rt="$HWN/rt-nomktemp-$sh-$kind"
        mkdir -p "$rt"
        hw_f=$(hwinfo_file "$rt")
        rc=0
        actual=$(timeout 10 env -u STARSHIP_CPU_INTEL -u STARSHIP_CPU_AMD -u STARSHIP_GPU_NVIDIA \
            -u STARSHIP_GPU_AMD -u STARSHIP_GPU_INTEL XDG_RUNTIME_DIR="$rt" PATH="$HWN/bin-nomktemp" "$sh_bin" -c "
                awk() { :; }
                $mk \"$hw_f.tmp.\$\$\"
                . '$HWINFO_SH'
                echo \"CPU=\${STARSHIP_CPU_INTEL-} GPU=\${STARSHIP_GPU_NVIDIA-}\"
            " 2>&1) || rc=$?
        assert_eq "$sh/no mktemp, a $what at the temporary name: the start goes on" \
            "rc=0 CPU= GPU=" "rc=$rc $actual"
        assert_eq "$sh/no mktemp, a $what at the temporary name: no cache" "" \
            "$(find "$rt" -name "${hw_f##*/}" 2>/dev/null)"
    done
done

# =============================================================================
# Zsh tests
# =============================================================================

echo "[zsh] toggle-hwinfo OFF/ON messages"
actual=$(run_zsh "$HWINFO_SH" '
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    export STARSHIP_CPU_INTEL="i9-13900K"
    toggle-hwinfo
    toggle-hwinfo
')
assert_contains "zsh/toggle OFF message" "hwinfo: OFF" "$actual"
assert_contains "zsh/toggle ON message" "hwinfo: ON" "$actual"

echo "[zsh] toggle-hwinfo var roundtrip"
actual=$(run_zsh "$HWINFO_SH" '
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    export STARSHIP_CPU_INTEL="Ryzen 9 7950X"
    toggle-hwinfo >/dev/null
    echo "OFF:CPU=${STARSHIP_CPU_INTEL:-UNSET}"
    toggle-hwinfo >/dev/null
    echo "ON:CPU=$STARSHIP_CPU_INTEL"
')
assert_contains "zsh/roundtrip OFF cleared" "OFF:CPU=UNSET" "$actual"
assert_contains "zsh/roundtrip ON restored" "ON:CPU=Ryzen 9 7950X" "$actual"

echo "[zsh] tgl-hw flips like toggle-hwinfo"
actual=$(run_zsh "$HWINFO_SH" '
    unset STARSHIP_CPU_INTEL STARSHIP_CPU_AMD STARSHIP_GPU_NVIDIA STARSHIP_GPU_AMD STARSHIP_GPU_INTEL
    export STARSHIP_CPU_INTEL="Ryzen 9 7950X"
    whence -w tgl-hw
    tgl-hw
    echo "OFF:CPU=${STARSHIP_CPU_INTEL:-UNSET} HIDDEN=$_DEN_HWINFO_HIDDEN"
    tgl-hw
    echo "ON:CPU=$STARSHIP_CPU_INTEL HIDDEN=$_DEN_HWINFO_HIDDEN"
' 2>/dev/null)
assert_eq "zsh/tgl-hw OFF then ON" "tgl-hw: function
hwinfo: OFF (hidden from prompt)
OFF:CPU=UNSET HIDDEN=1
hwinfo: ON (visible in prompt)
ON:CPU=Ryzen 9 7950X HIDDEN=0" "$actual"

# =============================================================================
# PowerShell tests
# =============================================================================

echo "[pwsh] toggle-hwinfo OFF message"
actual=$(run_pwsh "$HWINFO_PS1_TOGGLE" '
    $env:STARSHIP_CPU_INTEL = "i9-13900K"
    $env:STARSHIP_GPU_NVIDIA = "RTX 4090"
    toggle-hwinfo 6>&1
' | tr -d '\r')
assert_contains "pwsh/toggle OFF message" "OFF" "$actual"

echo "[pwsh] toggle-hwinfo OFF clears vars"
actual=$(run_pwsh "$HWINFO_PS1_TOGGLE" '
    $env:STARSHIP_CPU_INTEL = "i9-13900K"
    $env:STARSHIP_GPU_NVIDIA = "RTX 4090"
    toggle-hwinfo *>$null
    Write-Output "CPU=$env:STARSHIP_CPU_INTEL"
    Write-Output "GPU=$env:STARSHIP_GPU_NVIDIA"
    Write-Output "SAVED=$env:_DEN_SAVED_CPU_INTEL"
    Write-Output "HIDDEN=$env:_DEN_HWINFO_HIDDEN"
' | tr -d '\r')
assert_eq "pwsh/toggle OFF cpu cleared" "CPU=" "$(echo "$actual" | grep '^CPU=')"
assert_eq "pwsh/toggle OFF gpu cleared" "GPU=" "$(echo "$actual" | grep '^GPU=')"
assert_eq "pwsh/toggle OFF saved cpu" "SAVED=i9-13900K" "$(echo "$actual" | grep '^SAVED=')"
assert_eq "pwsh/toggle OFF hidden flag" "HIDDEN=1" "$(echo "$actual" | grep '^HIDDEN=')"

echo "[pwsh] toggle-hwinfo roundtrip"
actual=$(run_pwsh "$HWINFO_PS1_TOGGLE" '
    $env:STARSHIP_CPU_INTEL = "i9-13900K"
    $env:STARSHIP_GPU_NVIDIA = "RTX 4090"
    toggle-hwinfo *>$null
    toggle-hwinfo 6>&1
    Write-Output "CPU=$env:STARSHIP_CPU_INTEL"
' | tr -d '\r')
assert_contains "pwsh/roundtrip ON message" "ON" "$actual"
assert_contains "pwsh/roundtrip cpu restored" "CPU=i9-13900K" "$actual"

echo "[pwsh] tgl-hw flips like toggle-hwinfo"
actual=$(run_pwsh "$HWINFO_PS1_TOGGLE" '
    $env:STARSHIP_CPU_INTEL = "i9-13900K"
    Write-Output "TYPE=$((Get-Command tgl-hw -ErrorAction SilentlyContinue).CommandType)"
    $msg = @(tgl-hw 6>&1) -join ""
    Write-Output "$msg|CPU=$env:STARSHIP_CPU_INTEL|HIDDEN=$env:_DEN_HWINFO_HIDDEN"
    $msg = @(tgl-hw 6>&1) -join ""
    Write-Output "$msg|CPU=$env:STARSHIP_CPU_INTEL|HIDDEN=$env:_DEN_HWINFO_HIDDEN"
' 2>/dev/null | tr -d '\r') || true
assert_eq "pwsh/tgl-hw OFF then ON" "TYPE=Function
hwinfo: OFF (hidden from prompt)|CPU=|HIDDEN=1
hwinfo: ON (visible in prompt)|CPU=i9-13900K|HIDDEN=0" "$actual"

echo "[pwsh] _DEN_HWINFO_HIDDEN=1 at load keeps the cached info hidden; one toggle shows it"
# The whole hwinfo.ps1 this time, with its cache under a data dir of our own
# (LocalApplicationData is XDG_DATA_HOME on Linux/macOS). .NET returns an empty
# LocalApplicationData for a directory that does not exist, which would put the
# cache in the current directory: create it first, and run from WORK anyway.
mkdir -p "$WORK/hwinfo-ps-data"
actual=$(cd "$WORK" && env -u STARSHIP_CPU_INTEL -u STARSHIP_CPU_AMD -u STARSHIP_GPU_NVIDIA -u STARSHIP_GPU_AMD \
    -u STARSHIP_GPU_INTEL -u _DEN_SAVED_CPU_INTEL XDG_DATA_HOME="$WORK/hwinfo-ps-data" _DEN_HWINFO_HIDDEN=1 \
    pwsh -NoProfile -NonInteractive -Command "
        . '$DOTFILES/shell/pwsh/_helpers.ps1'
        \$cache = [IO.Path]::Combine([Environment]::GetFolderPath('LocalApplicationData'), 'shell-cache', \"hwinfo-cache.\$env:COMPUTERNAME.ps1\")
        if (-not \$cache.StartsWith('$WORK/hwinfo-ps-data/')) { throw \"cache outside the test data dir: \$cache\" }
        \$null = New-Item -ItemType Directory -Force -Path (Split-Path -Parent \$cache)
        \"\`\$env:STARSHIP_CPU_INTEL = 'i9-13900K'\" | Set-Content -LiteralPath \$cache
        . '$HWINFO_PS1'
        Write-Output \"LOAD:CPU=[\$env:STARSHIP_CPU_INTEL] SAVED=[\$env:_DEN_SAVED_CPU_INTEL]\"
        \$msg = @(toggle-hwinfo 6>&1) -join ''
        Write-Output \"\$msg|CPU=\$env:STARSHIP_CPU_INTEL|HIDDEN=\$env:_DEN_HWINFO_HIDDEN\"
    " 2>&1 | tr -d '\r')
assert_eq "pwsh/_DEN_HWINFO_HIDDEN=1 at load" "LOAD:CPU=[] SAVED=[i9-13900K]
hwinfo: ON (visible in prompt)|CPU=i9-13900K|HIDDEN=0" "$actual"

# The same machine on Windows: hwinfo.ps1 detects through the registry and CIM
# (Get-ItemProperty, Get-CimInstance), and wrote no cache when it recognized
# nothing, so the detection ran at every start. Now it writes the comment line
# cmd's starship.lua writes for that, and a cache it sourced counts as a hit.
# hw_ps stands in for that machine: $IsWindows set, _OnWindows false (so
# Test-CacheSafe checks the file the POSIX way), and functions of those names
# that answer with a Snapdragon CPU and an Adreno GPU (or fail, with HW_FAIL set)
# and count their calls. LocalApplicationData is XDG_DATA_HOME here.
HWP="$WORK/hwinfo-ps"
HWP_CACHE="$HWP/data/shell-cache/hwinfo-cache.DENTEST.ps1"
mkdir -p "$HWP/data/shell-cache"
hw_ps() {
    (cd "$WORK" && env -u STARSHIP_CPU_INTEL -u STARSHIP_CPU_AMD -u STARSHIP_GPU_NVIDIA -u STARSHIP_GPU_AMD \
        -u STARSHIP_GPU_INTEL -u _DEN_HWINFO_HIDDEN XDG_DATA_HOME="$HWP/data" COMPUTERNAME=DENTEST "$@" \
        pwsh -NoProfile -NonInteractive -Command "
            . '$DOTFILES/shell/pwsh/_helpers.ps1'
            Set-Variable -Name IsWindows -Value \$true -Scope Global -Force
            function global:_OnWindows { \$false }
            \$global:HwCalls = 0
            function global:Get-ItemProperty {
                \$global:HwCalls++
                if (\$env:HW_FAIL) { throw 'no registry here' }
                [pscustomobject]@{ ProcessorNameString = 'Snapdragon(R) X Elite - X1E80100 - Qualcomm(R) Oryon(TM) CPU' }
            }
            function global:Get-CimInstance { \$global:HwCalls++; [pscustomobject]@{ Name = 'Qualcomm(R) Adreno(TM) X1-85 GPU' } }
            . '$HWINFO_PS1'
            \"calls=\$global:HwCalls CPU=[\$env:STARSHIP_CPU_INTEL\$env:STARSHIP_CPU_AMD] GPU=[\$env:STARSHIP_GPU_INTEL]\"
        " 2>&1 | tr -d '\r')
}
HW_NONE_LINE='# den: no CPU or GPU name it recognizes'
echo "[pwsh] a detection that recognizes nothing writes cmd's comment line"
rm -f "$HWP_CACHE"
actual=$(hw_ps) || true
assert_eq "pwsh/no recognized hardware: detected" "calls=2 CPU=[] GPU=[]" "$actual"
assert_eq "pwsh/no recognized hardware: the cache says so" "$HW_NONE_LINE" "$(tr -d '\r' < "$HWP_CACHE" 2>/dev/null)"
echo "[pwsh] that cache counts as a hit: no detection"
rm -f "$HWP_CACHE"
printf '%s\n' "$HW_NONE_LINE" > "$HWP_CACHE"
actual=$(hw_ps) || true
assert_eq "pwsh/no recognized hardware: no detection the next time" "calls=0 CPU=[] GPU=[]" "$actual"
# Any safe cache file that was sourced counted as a hit, an empty one too (a
# write that failed), so the detection never ran again until refresh-hwinfo.
# As in cmd's reader, a hit needs a value or that whole line.
echo "[pwsh] an empty or cut-short cache file is not a hit: detected again"
: > "$HWP_CACHE"
actual=$(hw_ps) || true
assert_eq "pwsh/empty cache: detected" "calls=2 CPU=[] GPU=[]" "$actual"
assert_eq "pwsh/empty cache: written again" "$HW_NONE_LINE" "$(tr -d '\r' < "$HWP_CACHE" 2>/dev/null)"
printf '%s' "${HW_NONE_LINE%GPU*}" > "$HWP_CACHE"
actual=$(hw_ps) || true
assert_eq "pwsh/cut-short cache: detected" "calls=2 CPU=[] GPU=[]" "$actual"
echo "[pwsh] a detection that fails writes no cache"
rm -f "$HWP_CACHE"
actual=$(hw_ps HW_FAIL=1) || true
assert_eq "pwsh/failed detection: ran" "calls=1 CPU=[] GPU=[]" "$actual"
assert_not_exists "pwsh/failed detection: no cache, so the next start tries again" "$HWP_CACHE"
echo "[pwsh] hwinfo.ps1 writes the line cmd's starship.lua writes and reads"
actual=$(sed -n 's/^local hw_none = "\(.*\)"$/\1/p' "$DOTFILES/shell/cmd/starship.lua")
assert_eq "cmd/starship.lua's hw_none" "$HW_NONE_LINE" "$actual"
assert_eq "pwsh/hwinfo.ps1 writes and reads the same line" "1" "$(grep -cF "\$_hwNone = '$HW_NONE_LINE'" "$HWINFO_PS1")"

# =============================================================================
# Windows PowerShell 5.1 syntax, over every shell/pwsh/*.ps1
# =============================================================================
# init.ps1 dot-sources these files on Windows PowerShell 5.1 too, which cannot
# parse PowerShell 6/7 syntax and then runs none of the file: hwinfo.ps1's
# `(...)?.Trim()` put toggle-hwinfo at stake. pwsh 7's parser still reads that
# syntax, so its AST and tokens find it without a 5.1 host. The scan knows the
# constructs it lists (PowerShell 6.0 to 7.3), nothing newer. 5.1 also reads a
# file without a BOM in the ANSI code page, so the scan parses it that way too.

PWSH_SYNTAX_SCAN="$TESTTMP/pwsh_syntax_scan.ps1"
cat > "$PWSH_SYNTAX_SCAN" << 'PS1'
param([string]$Dir)
# A wrong directory must fail the scan, not pass it with no findings.
$ErrorActionPreference = 'Stop'
[System.Text.Encoding]::RegisterProvider([System.Text.CodePagesEncodingProvider]::Instance)
$files = @(Get-ChildItem -LiteralPath $Dir -Filter *.ps1 -File)
if ($files.Count -eq 0) { throw "no .ps1 files in $Dir" }
foreach ($f in $files) {
  $tokens = $null; $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
  # A message can span lines (it quotes the token); keep one finding per line.
  foreach ($e in $errors) { "$($f.Name):$($e.Extent.StartLineNumber): parse error: $($e.Message -replace '\s+', ' ')" }
  # Common ANSI code pages; in cp1252 the last byte of a UTF-8 arrow is a curly
  # quote, which PowerShell accepts as a quote.
  $bytes = [System.IO.File]::ReadAllBytes($f.FullName)
  if (-not ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)) {
    foreach ($cp in 1250, 1251, 1252, 932, 936, 949, 950) {
      $text = [System.Text.Encoding]::GetEncoding($cp).GetString($bytes)
      $ansiTokens = $null; $ansiErrors = $null
      [void][System.Management.Automation.Language.Parser]::ParseInput($text, [ref]$ansiTokens, [ref]$ansiErrors)
      foreach ($e in $ansiErrors) { "$($f.Name):$($e.Extent.StartLineNumber): parse error as cp${cp}: $($e.Message -replace '\s+', ' ')" }
    }
  }
  $hits = @($ast.FindAll({
      param($n)
      # ternary, ??, ??=, && and || (7.0); ?. and ?[] (7.1)
      ($n -is [System.Management.Automation.Language.TernaryExpressionAst]) -or
      ($n -is [System.Management.Automation.Language.PipelineChainAst]) -or
      ($n -is [System.Management.Automation.Language.BinaryExpressionAst] -and $n.Operator -eq 'QuestionQuestion') -or
      ($n -is [System.Management.Automation.Language.AssignmentStatementAst] -and $n.Operator -eq 'QuestionQuestionEquals') -or
      ($n -is [System.Management.Automation.Language.MemberExpressionAst] -and $n.NullConditional) -or
      ($n -is [System.Management.Automation.Language.IndexExpressionAst] -and $n.NullConditional) -or
      # a trailing & that backgrounds a pipeline (6.0); clean {} and M[T]() calls (7.3)
      ($n -is [System.Management.Automation.Language.PipelineAst] -and $n.Background) -or
      ($n -is [System.Management.Automation.Language.ScriptBlockAst] -and $n.CleanBlock) -or
      ($n -is [System.Management.Automation.Language.InvokeMemberExpressionAst] -and $n.GenericTypeArguments)
    }, $true))
  # 5.1 parses these tokens but reads them differently: a `u{} escape (6.0) stays
  # literal text; 0b literals and u/y/s/n type suffixes (6.2, 7.0) are not numbers.
  $hits += @($tokens | Where-Object {
      ($_.Kind -eq 'Number' -and $_.Text -match '(?i)^[-+]?0b|(u|y|s|n|ul|us|uy)(kb|mb|gb|tb|pb)?$') -or
      ($_.Kind -in 'StringExpandable', 'HereStringExpandable' -and $_.Text -match '(?<!`)(``)*`u\{')
    })
  foreach ($h in $hits) { "$($f.Name):$($h.Extent.StartLineNumber): $(($h.Extent.Text -split "`n")[0])" }
}
PS1

# One line per construct the scan knows (1-12), then 5.1-valid look-alikes (13-14),
# then a UTF-8 arrow in double quotes (15, fine) and in single quotes (16, broken
# when read as cp1252; last, so the broken string cannot swallow another line).
PWSH7_FIXTURE="$WORK/pwsh7_fixture"
mkdir -p "$PWSH7_FIXTURE" "$WORK/pwsh_empty"
cat > "$PWSH7_FIXTURE/all7.ps1" << 'PS1'
$a = $true ? 1 : 2
$b = $null ?? 1
$b ??= 2
Get-Item . && Get-Item .
$c = ${b}?.Length
$d = ${b}?[0]
Start-Sleep 1 &
function f { process { $_ } clean { 'done' } }
$e = [System.Linq.Enumerable]::Empty[string]()
$g = "`u{2192}"
$h = 0b1010
$i = 5u
$ok = 0x1b + 2gb + 5l + 1.5d + 1e3 + $b?.Length
$lit = "``u{0}" + '`u{2192}'
$arrow = "→ x"
$arrow = '→ x'
PS1

echo "[pwsh] the syntax scan flags each construct it lists, and nothing else"
actual=$(pwsh -NoProfile -NonInteractive -File "$PWSH_SYNTAX_SCAN" "$PWSH7_FIXTURE" | tr -d '\r' |
    cut -d: -f2 | sort -nu | paste -sd' ' -) || actual="${actual}[scan exited $?]"
assert_eq "pwsh/syntax scan fixture lines" "1 2 3 4 5 6 7 8 9 10 11 12 16" "$actual"

echo "[pwsh] the syntax scan fails on a directory without .ps1 files"
rc=0
pwsh -NoProfile -NonInteractive -File "$PWSH_SYNTAX_SCAN" "$WORK/pwsh_empty" >/dev/null 2>&1 || rc=$?
assert_failure "pwsh/syntax scan refuses an empty directory" "$rc"

echo "[pwsh] no PowerShell 6/7-only syntax in shell/pwsh/*.ps1"
actual=$(pwsh -NoProfile -NonInteractive -File "$PWSH_SYNTAX_SCAN" "$DOTFILES/shell/pwsh" | tr -d '\r') ||
    actual="${actual}[scan exited $?]"
assert_eq "pwsh/5.1-parsable syntax" "" "$actual"

# tests/shell/relaunch_argv.ps1 and tests/shell/head_stop.ps1 run under Windows
# PowerShell 5.1 in CI.
echo "[pwsh] no PowerShell 6/7-only syntax in tests/shell/*.ps1"
actual=$(pwsh -NoProfile -NonInteractive -File "$PWSH_SYNTAX_SCAN" "$SCRIPT_DIR" | tr -d '\r') ||
    actual="${actual}[scan exited $?]"
assert_eq "pwsh/5.1-parsable syntax in tests/shell" "" "$actual"

# PSUseCompatibleSyntax is the analyzer's view of part of the same class
# (PSScriptAnalyzer 1.25 flags lines 1-5 of the fixture only); the shell test
# image has no PSScriptAnalyzer, so the scan above is what runs there.
# pssa_compat <dir> prints one line per finding; it fails when <dir> has no
# .ps1 files or the analyzer errors, instead of printing nothing.
pssa_compat() {
    # A hashtable, not a settings file: see the PSScriptAnalyzer step in ci.yml.
    pwsh -NoProfile -NonInteractive -Command "
        \$ErrorActionPreference = 'Stop'
        \$settings = @{
            IncludeRules = @('PSUseCompatibleSyntax')
            Rules = @{ PSUseCompatibleSyntax = @{ Enable = \$true; TargetVersions = @('5.1', '7.0') } }
        }
        \$files = @(Get-ChildItem -LiteralPath '$1' -Filter *.ps1 -File)
        if (\$files.Count -eq 0) { throw 'no .ps1 files in $1' }
        \$files | ForEach-Object { Invoke-ScriptAnalyzer -Path \$_.FullName -Settings \$settings } |
            ForEach-Object { '{0}:{1}: {2}' -f \$_.ScriptName, \$_.Line, \$_.Message }
    " | tr -d '\r'
}

echo "[pwsh] PSUseCompatibleSyntax (5.1, 7.0) over shell/pwsh/*.ps1"
if pwsh -NoProfile -NonInteractive -Command 'if (Get-Module -ListAvailable PSScriptAnalyzer) { exit 0 }; exit 1' >/dev/null 2>&1; then
    # The fixture's ${b}?.Length proves the rule is on, so "" below means clean.
    actual=$(pssa_compat "$PWSH7_FIXTURE") || actual="${actual}[analyzer exited $?]"
    assert_contains "pwsh/PSUseCompatibleSyntax flags the fixture's ?." "all7.ps1:5:" "$actual"
    actual=$(pssa_compat "$DOTFILES/shell/pwsh") || actual="${actual}[analyzer exited $?]"
    assert_eq "pwsh/PSUseCompatibleSyntax 5.1 and 7.0" "" "$actual"
    actual=$(pssa_compat "$SCRIPT_DIR") || actual="${actual}[analyzer exited $?]"
    assert_eq "pwsh/PSUseCompatibleSyntax 5.1 and 7.0 in tests/shell" "" "$actual"
else
    echo "  SKIP: pwsh/PSUseCompatibleSyntax (PSScriptAnalyzer not installed)"
fi

# =============================================================================
# Windows PowerShell 5.1 has no $IsWindows, $IsLinux, $IsMacOS or $IsCoreCLR
# =============================================================================
# There they read as $null, until Set-StrictMode makes reading them an error. A
# user's script that sets it and then calls den's commands (cat, grep, ...) sets
# it for them too, so each read must sit on the right of an -or/-and whose left
# side settles the answer on 5.1 first: the edition ('Desktop' or 'Core') or
# $env:OS (Windows_NT). The scan prints each read that does not.

PWSH_PLATFORM_SCAN="$TESTTMP/pwsh_platform_scan.ps1"
cat > "$PWSH_PLATFORM_SCAN" << 'PS1'
param([string]$Dir)
$ErrorActionPreference = 'Stop'
$files = @(Get-ChildItem -LiteralPath $Dir -Filter *.ps1 -File)
if ($files.Count -eq 0) { throw "no .ps1 files in $Dir" }
# A left side that is true on 5.1 (for -or) or false there (for -and).
$orGuard = "(?i)PSEdition\s+-(eq\s+'Desktop'|ne\s+'Core')|\`$env:OS\s+-eq\s+'Windows_NT'"
$andGuard = "(?i)PSEdition\s+-(eq\s+'Core'|ne\s+'Desktop')|\`$env:OS\s+-ne\s+'Windows_NT'"
foreach ($f in $files) {
  $tokens = $null; $errors = $null
  $ast = [System.Management.Automation.Language.Parser]::ParseFile($f.FullName, [ref]$tokens, [ref]$errors)
  $reads = $ast.FindAll({
      param($n)
      $n -is [System.Management.Automation.Language.VariableExpressionAst] -and
      $n.VariablePath.UserPath -in 'IsWindows', 'IsLinux', 'IsMacOS', 'IsCoreCLR'
    }, $true)
  foreach ($v in $reads) {
    $guarded = $false
    for ($p = $v.Parent; $p -and -not $guarded; $p = $p.Parent) {
      if ($p -is [System.Management.Automation.Language.BinaryExpressionAst] -and
          $v.Extent.StartOffset -ge $p.Right.Extent.StartOffset) {
        $guarded = ($p.Operator -eq 'Or' -and $p.Left.Extent.Text -match $orGuard) -or
                   ($p.Operator -eq 'And' -and $p.Left.Extent.Text -match $andGuard)
      }
    }
    if (-not $guarded) { "$($f.Name):$($v.Extent.StartLineNumber): $($v.Extent.Text)" }
  }
}
PS1

# Lines 1-7 read a platform variable unguarded (1, 2, 4, 5) or behind a left side
# that does not settle 5.1 (3, 6, 7); 8-12 are the guarded forms den uses; 13 is
# another name.
PWSH_PLATFORM_FIXTURE="$WORK/pwsh_platform_fixture"
mkdir -p "$PWSH_PLATFORM_FIXTURE"
cat > "$PWSH_PLATFORM_FIXTURE/platform.ps1" << 'PS1'
$a = $IsWindows
$b = $IsWindows -or $PSVersionTable.PSEdition -eq 'Desktop'
$c = $PSVersionTable.PSEdition -eq 'Core' -or $IsWindows
if ($IsLinux -or $IsMacOS) { }
$h = "on $IsMacOS"
$i = $env:OS -ne 'Windows_NT' -or $IsCoreCLR
$j = $PSVersionTable.PSEdition -eq 'Desktop' -and $IsWindows
$d = $PSVersionTable.PSEdition -eq 'Desktop' -or $IsWindows
$e = $env:OS -eq 'Windows_NT' -or $IsWindows
$f = $PSVersionTable.PSEdition -ne 'Core' -or $IsWindows -ne $true
$g = $PSVersionTable.PSEdition -eq 'Core' -and ($IsLinux -or $IsMacOS)
$k = -not ($env:OS -eq 'Windows_NT' -or $IsWindows)
$l = $IsWindowsX
PS1

echo "[pwsh] the platform-variable scan flags each unguarded read, and nothing else"
actual=$(pwsh -NoProfile -NonInteractive -File "$PWSH_PLATFORM_SCAN" "$PWSH_PLATFORM_FIXTURE" | tr -d '\r' |
    cut -d: -f2 | sort -nu | paste -sd' ' -) || actual="${actual}[scan exited $?]"
assert_eq "pwsh/platform scan fixture lines" "1 2 3 4 5 6 7" "$actual"

echo "[pwsh] the platform-variable scan fails on a directory without .ps1 files"
rc=0
pwsh -NoProfile -NonInteractive -File "$PWSH_PLATFORM_SCAN" "$WORK/pwsh_empty" >/dev/null 2>&1 || rc=$?
assert_failure "pwsh/platform scan refuses an empty directory" "$rc"

echo "[pwsh] no unguarded \$IsWindows/\$IsLinux/\$IsMacOS read in shell/pwsh/*.ps1"
actual=$(pwsh -NoProfile -NonInteractive -File "$PWSH_PLATFORM_SCAN" "$DOTFILES/shell/pwsh" | tr -d '\r') ||
    actual="${actual}[scan exited $?]"
assert_eq "pwsh/platform variables read after the 5.1 check" "" "$actual"

print_summary "test_hwinfo"
[ "$FAIL" -eq 0 ]
