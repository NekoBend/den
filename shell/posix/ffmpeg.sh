#!/bin/sh
# ffmpeg.sh — FFmpeg helper functions.
# Sourced by .bashrc / .zshrc. POSIX-compatible.
# Deploy target: ~/.config/shell/ffmpeg.sh
#
# All functions accept ffmpeg arg overrides: once a hyphen-prefixed arg is
# encountered after the positional args, all remaining args replace the
# default preset (the args between -i and output).

# Skip in non-interactive shells
case $- in *i*) ;; *) return 0 2>/dev/null || exit 0;; esac

command -v ffmpeg >/dev/null 2>&1 || return 0

# tomp4 <input> [output] [-ffmpeg overrides] — Convert to H.264/AAC mp4.
#   tomp4 input.avi                        → defaults
#   tomp4 input.avi out.mp4                → custom output
#   tomp4 input.avi -c:v libx265 -crf 18  → override (auto output)
#   tomp4 input.avi out.mp4 -c:v libx265  → override + custom output
# _ff_check_out <fn> <out> <ext>: an explicit output that does not carry the
# target extension is almost always a second INPUT mistaken for an output
# (`tomp4 a.avi b.avi` would overwrite b.avi, since ffmpeg runs with -y).
# The converters take one input per call; refuse instead of destroying it.
# The extension is compared without regard to case (OUT.MP4 from a camera or
# a Windows tool is an mp4), as the pwsh twin's lowercased check does.
_ff_check_out() {
  case "$(printf '%s' "$2" | tr '[:upper:]' '[:lower:]')" in
    *."$3") return 0 ;;
  esac
  echo "$1: output '$2' does not end in .$3; one input per call (for several files: for f in *.ext; do $1 \"\$f\"; done)" >&2
  return 1
}

# _ff_no_extra <fn> "$@": after <in> [out], a further non-option argument is a
# stray positional (a third file, a typo); refuse rather than hand it to ffmpeg.
_ff_no_extra() {
  _fn="$1"; shift
  if [ $# -gt 0 ] && [ "${1#-}" = "$1" ]; then
    echo "$_fn: unexpected argument '$1' (usage: $_fn <in> [out] [ffmpeg args])" >&2
    unset _fn
    return 1
  fi
  unset _fn
  return 0
}

tomp4() {
  _in="$1"; shift
  _out=""
  [ $# -gt 0 ] && [ "${1#-}" = "$1" ] && { _out="$1"; shift; }
  [ -z "$_out" ] && _out="${_in%.*}.mp4"
  _ff_check_out tomp4 "$_out" mp4 || return 1
  _ff_no_extra tomp4 "$@" || return 1
  if [ $# -gt 0 ]; then
    ffmpeg -hide_banner -loglevel error -y -i "$_in" "$@" "$_out"
  else
    ffmpeg -hide_banner -loglevel error -y -i "$_in" -c:v libx264 -c:a aac "$_out"
  fi
}

# towebm <input> [output] [-ffmpeg overrides] — Convert to VP9/Opus webm.
#   towebm input.mp4 -c:v libsvtav1 -crf 30  → override with AV1
towebm() {
  _in="$1"; shift
  _out=""
  [ $# -gt 0 ] && [ "${1#-}" = "$1" ] && { _out="$1"; shift; }
  [ -z "$_out" ] && _out="${_in%.*}.webm"
  _ff_check_out towebm "$_out" webm || return 1
  _ff_no_extra towebm "$@" || return 1
  if [ $# -gt 0 ]; then
    ffmpeg -hide_banner -loglevel error -y -i "$_in" "$@" "$_out"
  else
    ffmpeg -hide_banner -loglevel error -y -i "$_in" -c:v libvpx-vp9 -c:a libopus "$_out"
  fi
}

# tomp3 <input> [output] [-ffmpeg overrides] — Extract/convert audio to MP3 192k.
#   tomp3 input.wav -b:a 320k  → override bitrate
tomp3() {
  _in="$1"; shift
  _out=""
  [ $# -gt 0 ] && [ "${1#-}" = "$1" ] && { _out="$1"; shift; }
  [ -z "$_out" ] && _out="${_in%.*}.mp3"
  _ff_check_out tomp3 "$_out" mp3 || return 1
  _ff_no_extra tomp3 "$@" || return 1
  if [ $# -gt 0 ]; then
    ffmpeg -hide_banner -loglevel error -y -i "$_in" "$@" "$_out"
  else
    ffmpeg -hide_banner -loglevel error -y -i "$_in" -vn -c:a libmp3lame -b:a 192k "$_out"
  fi
}

# towav <input> [output] [-ffmpeg overrides] — Convert to WAV PCM 16-bit.
#   towav input.flac -c:a pcm_s24le  → override to 24-bit
towav() {
  _in="$1"; shift
  _out=""
  [ $# -gt 0 ] && [ "${1#-}" = "$1" ] && { _out="$1"; shift; }
  [ -z "$_out" ] && _out="${_in%.*}.wav"
  _ff_check_out towav "$_out" wav || return 1
  _ff_no_extra towav "$@" || return 1
  if [ $# -gt 0 ]; then
    ffmpeg -hide_banner -loglevel error -y -i "$_in" "$@" "$_out"
  else
    ffmpeg -hide_banner -loglevel error -y -i "$_in" -c:a pcm_s16le "$_out"
  fi
}

# toflac <input> [output] [-ffmpeg overrides] — Convert to FLAC lossless.
#   toflac input.wav -compression_level 12  → override compression
toflac() {
  _in="$1"; shift
  _out=""
  [ $# -gt 0 ] && [ "${1#-}" = "$1" ] && { _out="$1"; shift; }
  [ -z "$_out" ] && _out="${_in%.*}.flac"
  _ff_check_out toflac "$_out" flac || return 1
  _ff_no_extra toflac "$@" || return 1
  if [ $# -gt 0 ]; then
    ffmpeg -hide_banner -loglevel error -y -i "$_in" "$@" "$_out"
  else
    ffmpeg -hide_banner -loglevel error -y -i "$_in" -c:a flac "$_out"
  fi
}

# togif <input> [output] [fps] [width] [-ffmpeg overrides] — Convert to GIF.
#   togif input.mp4                           → 2-pass palette, 10fps, 480w
#   togif input.mp4 out.gif 15 640            → custom params
#   togif input.mp4 -vf "fps=5,scale=320:-1"  → single-pass override
togif() {
  _in="$1"; shift
  _out=""
  [ $# -gt 0 ] && [ "${1#-}" = "$1" ] && { _out="$1"; shift; }
  [ -z "$_out" ] && _out="${_in%.*}.gif"
  _ff_check_out togif "$_out" gif || return 1
  _fps=""
  [ $# -gt 0 ] && [ "${1#-}" = "$1" ] && { _fps="$1"; shift; }
  [ -z "$_fps" ] && _fps="10"
  _w=""
  [ $# -gt 0 ] && [ "${1#-}" = "$1" ] && { _w="$1"; shift; }
  [ -z "$_w" ] && _w="480"
  if [ $# -gt 0 ]; then
    ffmpeg -hide_banner -loglevel error -y -i "$_in" "$@" "$_out"
  else
    _filters="fps=${_fps},scale=${_w}:-1:flags=lanczos"
    _palette="$(mktemp "${TMPDIR:-/tmp}/palette.XXXXXX.png")" || return 1
    # NOTE: trap, chmod 600 and -- are required — do not remove.
    # The palette trap is togif's own: afterwards the caller's EXIT, INT,
    # TERM and HUP traps come back, not the defaults. zsh puts them back
    # itself when togif returns (local_traps); bash keeps them to eval.
    _tg_traps=
    if [ -n "${ZSH_VERSION-}" ]; then
      setopt local_options local_traps
    else
      _tg_traps=$(trap -p EXIT INT TERM HUP)
    fi
    trap 'rm -f -- "$_palette"' EXIT INT TERM HUP
    chmod 600 -- "$_palette" 2>/dev/null
    ffmpeg -hide_banner -loglevel error -y -i "$_in" \
      -vf "${_filters},palettegen" -update 1 -- "$_palette" \
      && ffmpeg -hide_banner -loglevel error -y -i "$_in" -i "$_palette" \
           -lavfi "${_filters} [x]; [x][1:v] paletteuse" -- "$_out"
    _rc=$?
    trap - EXIT INT TERM HUP
    eval "$_tg_traps"
    unset _tg_traps
    rm -f -- "$_palette"
    return "$_rc"
  fi
}

# minfo <input> [extra ffprobe args] — Show media info (ffprobe compact format).
#   minfo input.mp4 -show_streams -of json  → extra ffprobe args
minfo() {
  # Several inputs are fine: each is probed in turn with the same options.
  # The inputs are the leading non-option words, and everything from the
  # first dash word on is passed to every ffprobe call verbatim, as the file
  # header says and the pwsh twin does: counting every non-dash word as an
  # input made the value of an option (the json of `-of json`) a file to
  # probe, and dropped it from the options.
  _n=0
  for _a in "$@"; do
    case "$_a" in -*) break ;; esac
    _n=$((_n + 1))
  done
  if [ "$_n" -eq 0 ]; then
    echo "usage: minfo <file...> [ffprobe args]" >&2
    unset _n _a
    return 1
  fi
  _rc=0
  _i=0
  for _a in "$@"; do
    _i=$((_i + 1))
    [ "$_i" -gt "$_n" ] && break
    _minfo_one "$_a" "$_n" "$@" || _rc=1
  done
  unset _n _a _i
  return "$_rc"
}

# _minfo_one <input> <n> "$@": ffprobe <input> with the arguments of "$@"
# that follow its first <n> (the inputs), i.e. the options, as given.
_minfo_one() {
  _target="$1"
  _skip="$2"
  shift 2
  shift "$_skip"
  ffprobe -hide_banner "$@" -i "$_target"
  _mrc=$?
  unset _target _skip
  return "$_mrc"
}

# clip <input> <start> <end> [output] [-ffmpeg overrides] — Cut video segment.
#   clip input.mp4 00:01:00 00:02:00                   → copy codec
#   clip input.mp4 00:01:00 00:02:00 -c:v libx264      → re-encode
#   clip input.mp4 00:01:00 00:02:00 out.mp4 -c:v h264 → custom output + override
clip() {
  _in="$1"; shift
  _ss="$1"; shift
  _to="$1"; shift
  _out=""
  [ $# -gt 0 ] && [ "${1#-}" = "$1" ] && { _out="$1"; shift; }
  [ -z "$_out" ] && _out="${_in%.*}_clip.${_in##*.}"
  # -ss and -to go BEFORE -i: as input options they make ffmpeg seek in the
  # input, where after -i it decoded (or, with -c copy, read) everything up to
  # the start and threw it away, seconds to minutes for a cut late in a long
  # file. Both move together: an input -ss with an output -to would read -to
  # as relative to the new start. Re-encoding stays frame-accurate; -c copy
  # starts at a keyframe either way.
  if [ $# -gt 0 ]; then
    ffmpeg -hide_banner -loglevel error -y -ss "$_ss" -to "$_to" -i "$_in" "$@" "$_out"
  else
    ffmpeg -hide_banner -loglevel error -y -ss "$_ss" -to "$_to" -i "$_in" -c copy "$_out"
  fi
}

# strip-audio <input> [output] [-ffmpeg overrides] — Remove audio track.
#   strip-audio input.mp4                  → copy video, drop audio
#   strip-audio input.mp4 -c:v libx265    → re-encode video, drop audio
strip-audio() {
  _in="$1"; shift
  _out=""
  [ $# -gt 0 ] && [ "${1#-}" = "$1" ] && { _out="$1"; shift; }
  [ -z "$_out" ] && _out="${_in%.*}_nosound.${_in##*.}"
  _ff_no_extra strip-audio "$@" || return 1
  if [ $# -gt 0 ]; then
    ffmpeg -hide_banner -loglevel error -y -i "$_in" -an "$@" "$_out"
  else
    ffmpeg -hide_banner -loglevel error -y -i "$_in" -an -c:v copy "$_out"
  fi
}

# thumbnail <input> [time] [output] [-ffmpeg overrides] — Extract frame as image.
#   thumbnail input.mp4                            → frame at 00:00:01
#   thumbnail input.mp4 00:00:30                   → frame at 30s
#   thumbnail input.mp4 00:00:30 -vf "scale=1920:-1"  → override
#   thumbnail input.mp4 00:00:30 out.png -q:v 2   → custom output + override
thumbnail() {
  _in="$1"; shift
  _t=""
  [ $# -gt 0 ] && [ "${1#-}" = "$1" ] && { _t="$1"; shift; }
  [ -z "$_t" ] && _t="00:00:01"
  _out=""
  [ $# -gt 0 ] && [ "${1#-}" = "$1" ] && { _out="$1"; shift; }
  [ -z "$_out" ] && _out="${_in%.*}.jpg"
  _ff_no_extra thumbnail "$@" || return 1
  # -ss before -i seeks the input instead of decoding every frame up to the
  # time (clip says more). -frames:v 1 comes first in the override form too:
  # without it ffmpeg writes every remaining frame to the one image file and
  # exits with an error; an override that sets -frames:v itself still wins.
  ffmpeg -hide_banner -loglevel error -y -ss "$_t" -i "$_in" -frames:v 1 "$@" "$_out"
}
