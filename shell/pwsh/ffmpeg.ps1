# ffmpeg.ps1 — FFmpeg helper functions for PowerShell.
# Dot-sourced by init.ps1.
#
# All functions accept ffmpeg arg overrides: once a hyphen-prefixed arg is
# encountered after the positional args, all remaining args replace the
# default preset (the args between -i and output).
# Uses $args (no param blocks) so ffmpeg flags like -c:v pass through.

if (-not (Get-Command ffmpeg -ErrorAction SilentlyContinue)) { return }

function _SplitPosExtra {
    $pos   = [System.Collections.Generic.List[string]]::new()
    $extra = [System.Collections.Generic.List[string]]::new()
    $hitDash = $false
    foreach ($a in $args) {
        if (-not $hitDash -and "$a".StartsWith('-')) { $hitDash = $true }
        if ($hitDash) { $extra.Add($a) } else { $pos.Add($a) }
    }
    return @(, $pos) + @(, $extra)
}

# tomp4 <input> [output] [-ffmpeg overrides] — Convert to H.264/AAC mp4.
#   tomp4 input.avi                        → defaults
#   tomp4 input.avi out.mp4                → custom output
#   tomp4 input.avi -c:v libx265 -crf 18  → override (auto output)
#   tomp4 input.avi out.mp4 -c:v libx265  → override + custom output
function tomp4 {
    $pos, $extra = _SplitPosExtra @args
    $In  = $pos[0]
    $Out = if ($pos.Count -gt 1) { $pos[1] } else { [IO.Path]::ChangeExtension($In, '.mp4') }
    if ($extra.Count -gt 0) {
        ffmpeg -hide_banner -loglevel error -y -i $In @extra $Out
    } else {
        ffmpeg -hide_banner -loglevel error -y -i $In -c:v libx264 -c:a aac $Out
    }
}

# towebm <input> [output] [-ffmpeg overrides] — Convert to VP9/Opus webm.
#   towebm input.mp4 -c:v libsvtav1 -crf 30  → override with AV1
function towebm {
    $pos, $extra = _SplitPosExtra @args
    $In  = $pos[0]
    $Out = if ($pos.Count -gt 1) { $pos[1] } else { [IO.Path]::ChangeExtension($In, '.webm') }
    if ($extra.Count -gt 0) {
        ffmpeg -hide_banner -loglevel error -y -i $In @extra $Out
    } else {
        ffmpeg -hide_banner -loglevel error -y -i $In -c:v libvpx-vp9 -c:a libopus $Out
    }
}

# tomp3 <input> [output] [-ffmpeg overrides] — Extract/convert audio to MP3 192k.
#   tomp3 input.wav -b:a 320k  → override bitrate
function tomp3 {
    $pos, $extra = _SplitPosExtra @args
    $In  = $pos[0]
    $Out = if ($pos.Count -gt 1) { $pos[1] } else { [IO.Path]::ChangeExtension($In, '.mp3') }
    if ($extra.Count -gt 0) {
        ffmpeg -hide_banner -loglevel error -y -i $In @extra $Out
    } else {
        ffmpeg -hide_banner -loglevel error -y -i $In -vn -c:a libmp3lame -b:a 192k $Out
    }
}

# towav <input> [output] [-ffmpeg overrides] — Convert to WAV PCM 16-bit.
#   towav input.flac -c:a pcm_s24le  → override to 24-bit
function towav {
    $pos, $extra = _SplitPosExtra @args
    $In  = $pos[0]
    $Out = if ($pos.Count -gt 1) { $pos[1] } else { [IO.Path]::ChangeExtension($In, '.wav') }
    if ($extra.Count -gt 0) {
        ffmpeg -hide_banner -loglevel error -y -i $In @extra $Out
    } else {
        ffmpeg -hide_banner -loglevel error -y -i $In -c:a pcm_s16le $Out
    }
}

# toflac <input> [output] [-ffmpeg overrides] — Convert to FLAC lossless.
#   toflac input.wav -compression_level 12  → override compression
function toflac {
    $pos, $extra = _SplitPosExtra @args
    $In  = $pos[0]
    $Out = if ($pos.Count -gt 1) { $pos[1] } else { [IO.Path]::ChangeExtension($In, '.flac') }
    if ($extra.Count -gt 0) {
        ffmpeg -hide_banner -loglevel error -y -i $In @extra $Out
    } else {
        ffmpeg -hide_banner -loglevel error -y -i $In -c:a flac $Out
    }
}

# togif <input> [output] [fps] [width] [-ffmpeg overrides] — Convert to GIF.
#   togif input.mp4                            → 2-pass palette, 10fps, 480w
#   togif input.mp4 out.gif 15 640             → custom params
#   togif input.mp4 -vf "fps=5,scale=320:-1"  → single-pass override
function togif {
    $pos, $extra = _SplitPosExtra @args
    $In  = $pos[0]
    $Out = if ($pos.Count -gt 1) { $pos[1] } else { [IO.Path]::ChangeExtension($In, '.gif') }
    $Fps   = if ($pos.Count -gt 2) { $pos[2] } else { '10' }
    $Width = if ($pos.Count -gt 3) { $pos[3] } else { '480' }
    if ($extra.Count -gt 0) {
        ffmpeg -hide_banner -loglevel error -y -i $In @extra $Out
    } else {
        $filters = "fps=${Fps},scale=${Width}:-1:flags=lanczos"
        $tmpDir = Join-Path ([IO.Path]::GetTempPath()) ("togif-" + [guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $tmpDir -Force
        try {
            $palette = Join-Path $tmpDir 'palette.png'
            ffmpeg -hide_banner -loglevel error -y -i $In -vf "${filters},palettegen" -update 1 $palette
            ffmpeg -hide_banner -loglevel error -y -i $In -i $palette -lavfi "${filters} [x]; [x][1:v] paletteuse" $Out
        } finally {
            Remove-Item -Path $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
}

# minfo <input> [extra ffprobe args] — Show media info (ffprobe compact format).
#   minfo input.mp4 -show_streams -of json  → extra ffprobe args
function minfo {
    $In = $args[0]
    $extra = @($args | Select-Object -Skip 1)
    ffprobe -hide_banner @extra -i $In
}

# clip <input> <start> <end> [output] [-ffmpeg overrides] — Cut video segment.
#   clip input.mp4 00:01:00 00:02:00                   → copy codec
#   clip input.mp4 00:01:00 00:02:00 -c:v libx264      → re-encode
#   clip input.mp4 00:01:00 00:02:00 out.mp4 -c:v h264 → custom output + override
function clip {
    $pos, $extra = _SplitPosExtra @args
    $In    = $pos[0]
    $Start = $pos[1]
    $End   = $pos[2]
    if ($pos.Count -gt 3) {
        $Out = $pos[3]
    } else {
        $base = [IO.Path]::GetFileNameWithoutExtension($In)
        $ext  = [IO.Path]::GetExtension($In)
        $dir  = [IO.Path]::GetDirectoryName($In)
        $Out  = [IO.Path]::Combine($dir, "${base}_clip${ext}")
    }
    if ($extra.Count -gt 0) {
        ffmpeg -hide_banner -loglevel error -y -i $In -ss $Start -to $End @extra $Out
    } else {
        ffmpeg -hide_banner -loglevel error -y -i $In -ss $Start -to $End -c copy $Out
    }
}

# strip-audio <input> [output] [-ffmpeg overrides] — Remove audio track.
#   strip-audio input.mp4                  → copy video, drop audio
#   strip-audio input.mp4 -c:v libx265    → re-encode video, drop audio
function strip-audio {
    $pos, $extra = _SplitPosExtra @args
    $In = $pos[0]
    if ($pos.Count -gt 1) {
        $Out = $pos[1]
    } else {
        $base = [IO.Path]::GetFileNameWithoutExtension($In)
        $ext  = [IO.Path]::GetExtension($In)
        $dir  = [IO.Path]::GetDirectoryName($In)
        $Out  = [IO.Path]::Combine($dir, "${base}_nosound${ext}")
    }
    if ($extra.Count -gt 0) {
        ffmpeg -hide_banner -loglevel error -y -i $In -an @extra $Out
    } else {
        ffmpeg -hide_banner -loglevel error -y -i $In -an -c:v copy $Out
    }
}

# thumbnail <input> [time] [output] [-ffmpeg overrides] — Extract frame as image.
#   thumbnail input.mp4                             → frame at 00:00:01
#   thumbnail input.mp4 00:00:30                    → frame at 30s
#   thumbnail input.mp4 00:00:30 -vf "scale=1920:-1"  → override
#   thumbnail input.mp4 00:00:30 out.png -q:v 2    → custom output + override
function thumbnail {
    $pos, $extra = _SplitPosExtra @args
    $In   = $pos[0]
    $Time = if ($pos.Count -gt 1) { $pos[1] } else { '00:00:01' }
    $Out  = if ($pos.Count -gt 2) { $pos[2] } else { [IO.Path]::ChangeExtension($In, '.jpg') }
    if ($extra.Count -gt 0) {
        ffmpeg -hide_banner -loglevel error -y -i $In -ss $Time @extra $Out
    } else {
        ffmpeg -hide_banner -loglevel error -y -i $In -ss $Time -frames:v 1 $Out
    }
}
