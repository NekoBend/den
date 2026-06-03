#!/usr/bin/env bash
# test_ffmpeg.sh — Tests for ffmpeg.sh / ffmpeg.ps1 (arg parsing with mock ffmpeg).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

DOTFILES="/root/.dotfiles"
FFMPEG_SH_GUARDED="$DOTFILES/shell/posix/ffmpeg.sh"
FFMPEG_PS1="$DOTFILES/shell/pwsh/ffmpeg.ps1"

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT

# --- Mock ffmpeg/ffprobe: just echo args ---
cat > "$WORK/ffmpeg" << 'MOCK'
#!/bin/sh
echo "FFMPEG $*"
MOCK
chmod +x "$WORK/ffmpeg"

cat > "$WORK/ffprobe" << 'MOCK'
#!/bin/sh
echo "FFPROBE $*"
MOCK
chmod +x "$WORK/ffprobe"

# POSIX: prepend mock PATH before sourcing ffmpeg.sh
FFMPEG_SH_SOURCE="$WORK/ffmpeg_source.sh"
make_noninteractive_source_copy "$FFMPEG_SH_GUARDED" "$FFMPEG_SH_SOURCE"

FFMPEG_SH_TEST="$WORK/ffmpeg_test.sh"
{
    echo "export PATH=\"$WORK:\$PATH\""
    cat "$FFMPEG_SH_SOURCE"
} > "$FFMPEG_SH_TEST"

# pwsh: prepend mock PATH + strip guard line
FFMPEG_PS1_TEST="$WORK/ffmpeg_test.ps1"
{
    echo "\$env:PATH = '$WORK' + [IO.Path]::PathSeparator + \$env:PATH"
    grep -v 'Get-Command ffmpeg.*SilentlyContinue.*return' "$FFMPEG_PS1"
} > "$FFMPEG_PS1_TEST"

# =============================================================================
# Bash tests
# =============================================================================

echo "[bash] tomp4 auto output"
actual=$(run_bash "$FFMPEG_SH_TEST" 'tomp4 input.avi')
assert_contains "bash/tomp4 input" "-i input.avi" "$actual"
assert_contains "bash/tomp4 codec" "-c:v libx264" "$actual"
assert_contains "bash/tomp4 auto ext" "input.mp4" "$actual"

echo "[bash] tomp4 custom output"
actual=$(run_bash "$FFMPEG_SH_TEST" 'tomp4 input.avi out.mp4')
assert_contains "bash/tomp4 custom out" "out.mp4" "$actual"

echo "[bash] tomp4 override args"
actual=$(run_bash "$FFMPEG_SH_TEST" 'tomp4 input.avi -c:v libx265 -crf 18')
assert_contains "bash/tomp4 override codec" "-c:v libx265" "$actual"
assert_contains "bash/tomp4 override crf" "-crf 18" "$actual"
assert_not_contains "bash/tomp4 no default" "-c:v libx264" "$actual"

echo "[bash] tomp4 output + override"
actual=$(run_bash "$FFMPEG_SH_TEST" 'tomp4 input.avi out.mp4 -c:v libx265')
assert_contains "bash/tomp4 out+ovr file" "out.mp4" "$actual"
assert_contains "bash/tomp4 out+ovr codec" "-c:v libx265" "$actual"

echo "[bash] clip auto output"
actual=$(run_bash "$FFMPEG_SH_TEST" 'clip input.mp4 00:01:00 00:02:00')
assert_contains "bash/clip output" "input_clip.mp4" "$actual"
assert_contains "bash/clip start" "-ss 00:01:00" "$actual"
assert_contains "bash/clip end" "-to 00:02:00" "$actual"
assert_contains "bash/clip copy" "-c copy" "$actual"

echo "[bash] togif defaults"
actual=$(run_bash "$FFMPEG_SH_TEST" 'togif input.mp4')
assert_contains "bash/togif palettegen" "palettegen" "$actual"
assert_contains "bash/togif paletteuse" "paletteuse" "$actual"
assert_contains "bash/togif fps" "fps=10" "$actual"
assert_contains "bash/togif width" "scale=480" "$actual"

echo "[bash] thumbnail defaults"
actual=$(run_bash "$FFMPEG_SH_TEST" 'thumbnail input.mp4')
assert_contains "bash/thumbnail time" "-ss 00:00:01" "$actual"
assert_contains "bash/thumbnail frames" "-frames:v 1" "$actual"
assert_contains "bash/thumbnail output" "input.jpg" "$actual"

echo "[bash] strip-audio auto output"
actual=$(run_bash "$FFMPEG_SH_TEST" 'strip-audio input.mp4')
assert_contains "bash/strip-audio output" "input_nosound.mp4" "$actual"
assert_contains "bash/strip-audio flag" "-an" "$actual"

echo "[bash] minfo passes args to ffprobe"
actual=$(run_bash "$FFMPEG_SH_TEST" 'minfo input.mp4 -show_streams')
assert_contains "bash/minfo ffprobe" "FFPROBE" "$actual"
assert_contains "bash/minfo extra" "-show_streams" "$actual"
assert_contains "bash/minfo input" "-i input.mp4" "$actual"

echo "[bash] guard: non-interactive source skips ffmpeg helpers"
actual=$(bash -c "
    export PATH='$WORK:\$PATH'
    source '$FFMPEG_SH_GUARDED'
    type tomp4 >/dev/null 2>&1 && echo 'DEFINED' || echo 'UNDEFINED'
" | tr -d '\r')
assert_eq "bash/guard non-interactive" "UNDEFINED" "$actual"

# =============================================================================
# Zsh tests
# =============================================================================

echo "[zsh] tomp4 auto output"
actual=$(run_zsh "$FFMPEG_SH_TEST" 'tomp4 input.avi')
assert_contains "zsh/tomp4 auto ext" "input.mp4" "$actual"
assert_contains "zsh/tomp4 codec" "-c:v libx264" "$actual"

echo "[zsh] togif custom fps/width"
actual=$(run_zsh "$FFMPEG_SH_TEST" 'togif input.mp4 out.gif 15 640')
assert_contains "zsh/togif fps" "fps=15" "$actual"
assert_contains "zsh/togif width" "scale=640" "$actual"
assert_contains "zsh/togif output" "out.gif" "$actual"

echo "[zsh] clip auto output"
actual=$(run_zsh "$FFMPEG_SH_TEST" 'clip input.mp4 00:01:00 00:02:00')
assert_contains "zsh/clip output" "input_clip.mp4" "$actual"

# =============================================================================
# PowerShell tests
# =============================================================================

echo "[pwsh] tomp4 auto output"
actual=$(run_pwsh "$FFMPEG_PS1_TEST" 'tomp4 input.avi' | tr -d '\r')
assert_contains "pwsh/tomp4 auto ext" "input.mp4" "$actual"
assert_contains "pwsh/tomp4 codec" "-c:v libx264" "$actual"

# NOTE: PowerShell splits "-c:v" into "-c:" + "v" through $args (known PS limitation).
# Use non-colon flags to test the override path.
echo "[pwsh] tomp4 override"
actual=$(run_pwsh "$FFMPEG_PS1_TEST" 'tomp4 input.avi -crf 18' | tr -d '\r')
assert_contains "pwsh/tomp4 override crf" "-crf 18" "$actual"
assert_not_contains "pwsh/tomp4 no default" "-c:v libx264" "$actual"

echo "[pwsh] clip auto output"
actual=$(run_pwsh "$FFMPEG_PS1_TEST" 'clip input.mp4 00:01:00 00:02:00' | tr -d '\r')
assert_contains "pwsh/clip output" "input_clip.mp4" "$actual"
assert_contains "pwsh/clip copy" "-c copy" "$actual"

echo "[pwsh] togif custom params"
actual=$(run_pwsh "$FFMPEG_PS1_TEST" 'togif input.mp4 out.gif 15 640' | tr -d '\r')
assert_contains "pwsh/togif fps" "fps=15" "$actual"
assert_contains "pwsh/togif width" "scale=640" "$actual"

echo "[pwsh] strip-audio auto output"
actual=$(run_pwsh "$FFMPEG_PS1_TEST" 'strip-audio input.mp4' | tr -d '\r')
assert_contains "pwsh/strip-audio output" "input_nosound.mp4" "$actual"

# =============================================================================
# Summary
# =============================================================================
print_summary "test_ffmpeg"
[ "$FAIL" -eq 0 ]
