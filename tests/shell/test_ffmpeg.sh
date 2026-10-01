#!/usr/bin/env bash
# test_ffmpeg.sh — Tests for ffmpeg.sh / ffmpeg.ps1 (arg parsing with mock ffmpeg).
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/helpers.sh"

# helpers.sh already honours a DOTFILES override so the suite can run against a
# checkout; hardcoding it here silently discarded that and tested the INSTALLED
# copy instead, whatever DOTFILES said.
DOTFILES="${DOTFILES:-/root/.dotfiles}"
FFMPEG_SH_GUARDED="$DOTFILES/shell/posix/ffmpeg.sh"
FFMPEG_PS1="$DOTFILES/shell/pwsh/ffmpeg.ps1"

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
FFMPEG_SH_SOURCE="$TESTTMP/ffmpeg_source.sh"
make_noninteractive_source_copy "$FFMPEG_SH_GUARDED" "$FFMPEG_SH_SOURCE"

FFMPEG_SH_TEST="$TESTTMP/ffmpeg_test.sh"
{
    echo "export PATH=\"$WORK:\$PATH\""
    cat "$FFMPEG_SH_SOURCE"
} > "$FFMPEG_SH_TEST"

# pwsh: prepend mock PATH + strip guard line
FFMPEG_PS1_TEST="$TESTTMP/ffmpeg_test.ps1"
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

# togif's palette trap used to end in `trap -` on EXIT, INT, TERM and HUP,
# which left the defaults: the traps the user had were gone afterwards.
echo "[bash] togif keeps the caller's EXIT, INT, TERM and HUP traps"
actual=$(run_bash "$FFMPEG_SH_TEST" "trap 'echo user-exit' EXIT; trap 'echo user-int' INT; trap 'echo user-term' TERM; togif input.mp4 >/dev/null; trap -p EXIT INT TERM HUP")
assert_eq "bash/togif keeps the traps, and the EXIT trap still runs" "trap -- 'echo user-exit' EXIT
trap -- 'echo user-int' SIGINT
trap -- 'echo user-term' SIGTERM
user-exit" "$actual"

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

echo "[zsh] togif keeps the caller's INT, TERM and HUP traps and TRAP functions"
actual=$(run_zsh "$FFMPEG_SH_TEST" "trap 'echo user-exit' EXIT; trap 'echo user-hup' HUP; TRAPINT() { echo user-int; }; togif input.mp4 >/dev/null; trap > '$WORK/traps'; grep '^trap' '$WORK/traps'; if functions TRAPINT >/dev/null; then echo TRAPINT kept; else echo TRAPINT gone; fi")
assert_eq "zsh/togif keeps the traps and TRAPINT, and the EXIT trap still runs" "trap -- 'echo user-exit' EXIT
trap -- 'echo user-hup' HUP
TRAPINT kept
user-exit" "$actual"

echo "[zsh] clip auto output"
actual=$(run_zsh "$FFMPEG_SH_TEST" 'clip input.mp4 00:01:00 00:02:00')
assert_contains "zsh/clip output" "input_clip.mp4" "$actual"

# =============================================================================
# PowerShell tests
# =============================================================================


echo "[bash] tomp4 refuses an output that is really a second input"
err=$(run_bash "$FFMPEG_SH_TEST" 'tomp4 a.avi b.avi' 2>&1 >/dev/null || true)
assert_contains "bash/tomp4 second-input guard message" "does not end in .mp4" "$err"
actual=$(run_bash "$FFMPEG_SH_TEST" 'tomp4 a.avi b.avi' 2>/dev/null || true)
assert_eq "bash/tomp4 second-input guard runs no ffmpeg" "" "$actual"
err=$(run_bash "$FFMPEG_SH_TEST" 'tomp4 a.avi out.mp4 c.avi' 2>&1 >/dev/null || true)
assert_contains "bash/tomp4 stray positional refused" "unexpected argument 'c.avi'" "$err"
err=$(run_bash "$FFMPEG_SH_TEST" 'strip-audio a.mp4 out.mp4 c.mp4' 2>&1 >/dev/null || true)
assert_contains "bash/strip-audio stray positional refused" "unexpected argument 'c.mp4'" "$err"
err=$(run_bash "$FFMPEG_SH_TEST" 'thumbnail a.mp4 00:00:05 out.png c.mp4' 2>&1 >/dev/null || true)
assert_contains "bash/thumbnail stray positional refused" "unexpected argument 'c.mp4'" "$err"
actual=$(run_bash "$FFMPEG_SH_TEST" 'thumbnail a.mp4 00:00:05 out.png -q:v 2')
assert_contains "bash/thumbnail time+out+override still accepted" "out.png" "$actual"
actual=$(run_bash "$FFMPEG_SH_TEST" 'tomp4 a.avi out.mp4 -crf 18')
assert_contains "bash/tomp4 explicit out still accepted" "out.mp4" "$actual"

echo "[bash] minfo several inputs"
actual=$(run_bash "$FFMPEG_SH_TEST" 'minfo a.mp4 b.mp4 -show_streams')
assert_contains "bash/minfo first input" "-i a.mp4" "$actual"
assert_contains "bash/minfo second input" "-i b.mp4" "$actual"
assert_eq "bash/minfo options applied to each call" "2" "$(printf '%s\n' "$actual" | grep -c -- '-show_streams')"
err=$(run_bash "$FFMPEG_SH_TEST" 'minfo -show_streams' 2>&1 >/dev/null || true)
assert_contains "bash/minfo no input is a usage error" "usage: minfo" "$err"

# clip and thumbnail put -ss (and -to) AFTER -i, an output option: ffmpeg
# decoded every frame up to the timestamp (read every packet, with -c copy)
# and threw it away. Input seeking must come before -i, both together.
for sh in bash zsh; do
    echo "[$sh] clip and thumbnail seek on the input"
    actual=$("run_$sh" "$FFMPEG_SH_TEST" 'clip input.mp4 00:01:00 00:02:00')
    assert_contains "$sh/clip seeks before -i" "-ss 00:01:00 -to 00:02:00 -i input.mp4 -c copy input_clip.mp4" "$actual"
    actual=$("run_$sh" "$FFMPEG_SH_TEST" 'clip input.mp4 00:01:00 00:02:00 out.mp4 -c:v libx264')
    assert_contains "$sh/clip override seeks before -i" "-ss 00:01:00 -to 00:02:00 -i input.mp4 -c:v libx264 out.mp4" "$actual"
    actual=$("run_$sh" "$FFMPEG_SH_TEST" 'thumbnail input.mp4 00:00:30')
    assert_contains "$sh/thumbnail seeks before -i" "-ss 00:00:30 -i input.mp4 -frames:v 1 input.jpg" "$actual"
    # The documented override example: without -frames:v 1 ffmpeg wrote every
    # remaining frame to one image file and exited 234.
    actual=$("run_$sh" "$FFMPEG_SH_TEST" 'thumbnail input.mp4 00:00:30 -vf "scale=1920:-1"')
    assert_contains "$sh/thumbnail override keeps one frame" "-ss 00:00:30 -i input.mp4 -frames:v 1 -vf scale=1920:-1 input.jpg" "$actual"

    # minfo counted every non-dash word as an input, so an option's VALUE (the
    # json of the documented `-of json`) became a file to probe and was
    # dropped from the options: two broken ffprobe calls.
    echo "[$sh] minfo passes valued ffprobe options through"
    actual=$("run_$sh" "$FFMPEG_SH_TEST" 'minfo input.mp4 -show_streams -of json')
    assert_eq "$sh/minfo documented example is one ffprobe call" "FFPROBE -hide_banner -show_streams -of json -i input.mp4" "$actual"
    actual=$("run_$sh" "$FFMPEG_SH_TEST" 'minfo a.mp4 b.mp4 -v error -select_streams v:0')
    assert_eq "$sh/minfo several inputs, valued options" "FFPROBE -hide_banner -v error -select_streams v:0 -i a.mp4
FFPROBE -hide_banner -v error -select_streams v:0 -i b.mp4" "$actual"

    # The output check compared the extension case-sensitively; the pwsh twin
    # lowercases, and cameras and Windows tools write OUT.MP4.
    echo "[$sh] converters accept an upper-case output extension"
    actual=$("run_$sh" "$FFMPEG_SH_TEST" 'tomp4 in.avi OUT.MP4' 2>&1 || true)
    assert_contains "$sh/tomp4 OUT.MP4 accepted" "-i in.avi -c:v libx264 -c:a aac OUT.MP4" "$actual"
    actual=$("run_$sh" "$FFMPEG_SH_TEST" 'tomp3 in.wav SONG.Mp3' 2>&1 || true)
    assert_contains "$sh/tomp3 SONG.Mp3 accepted" "-b:a 192k SONG.Mp3" "$actual"
    err=$("run_$sh" "$FFMPEG_SH_TEST" 'tomp4 a.avi B.AVI' 2>&1 >/dev/null || true)
    assert_contains "$sh/tomp4 still refuses B.AVI" "does not end in .mp4" "$err"
done

echo "[pwsh] clip and thumbnail seek on the input"
actual=$(run_pwsh "$FFMPEG_PS1_TEST" 'clip input.mp4 00:01:00 00:02:00' | tr -d '\r')
assert_contains "pwsh/clip seeks before -i" "-ss 00:01:00 -to 00:02:00 -i input.mp4 -c copy" "$actual"
actual=$(run_pwsh "$FFMPEG_PS1_TEST" 'clip input.mp4 00:01:00 00:02:00 out.mp4 -crf 18' | tr -d '\r')
assert_contains "pwsh/clip override seeks before -i" "-ss 00:01:00 -to 00:02:00 -i input.mp4 -crf 18 out.mp4" "$actual"
actual=$(run_pwsh "$FFMPEG_PS1_TEST" 'thumbnail input.mp4 00:00:30' | tr -d '\r')
assert_contains "pwsh/thumbnail seeks before -i" "-ss 00:00:30 -i input.mp4 -frames:v 1 input.jpg" "$actual"
actual=$(run_pwsh "$FFMPEG_PS1_TEST" 'thumbnail input.mp4 00:00:30 -vf scale=1920:-1' | tr -d '\r')
assert_contains "pwsh/thumbnail override keeps one frame" "-ss 00:00:30 -i input.mp4 -frames:v 1 -vf scale=1920:-1 input.jpg" "$actual"

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

echo "[pwsh] tomp4 refuses an output that is really a second input"
err=$(run_pwsh "$FFMPEG_PS1_TEST" 'tomp4 a.avi b.avi' 2>&1 >/dev/null || true)
assert_contains "pwsh/tomp4 second-input guard message" "does not end in .mp4" "$err"
actual=$(run_pwsh "$FFMPEG_PS1_TEST" 'tomp4 a.avi b.avi' 2>/dev/null || true)
assert_eq "pwsh/tomp4 second-input guard runs no ffmpeg" "" "$actual"
err=$(run_pwsh "$FFMPEG_PS1_TEST" 'tomp4 a.avi out.mp4 c.avi' 2>&1 >/dev/null || true)
assert_contains "pwsh/tomp4 stray positional refused" "unexpected argument 'c.avi'" "$err"
err=$(run_pwsh "$FFMPEG_PS1_TEST" 'strip-audio a.mp4 out.mp4 c.mp4' 2>&1 >/dev/null || true)
assert_contains "pwsh/strip-audio stray positional refused" "unexpected argument 'c.mp4'" "$err"
err=$(run_pwsh "$FFMPEG_PS1_TEST" 'thumbnail a.mp4 00:00:05 out.png c.mp4' 2>&1 >/dev/null || true)
assert_contains "pwsh/thumbnail stray positional refused" "unexpected argument 'c.mp4'" "$err"

echo "[pwsh] minfo several inputs"
actual=$(run_pwsh "$FFMPEG_PS1_TEST" 'minfo a.mp4 b.mp4 -show_streams')
assert_contains "pwsh/minfo first input" "-i a.mp4" "$actual"
assert_contains "pwsh/minfo second input" "-i b.mp4" "$actual"


# =============================================================================
# Summary
# =============================================================================
print_summary "test_ffmpeg"
[ "$FAIL" -eq 0 ]
