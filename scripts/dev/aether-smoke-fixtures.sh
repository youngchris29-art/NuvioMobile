#!/usr/bin/env bash
#
# aether-smoke-fixtures.sh — fixtures for the Aether UI legs (Aether Phase 1, W4):
# iosApp/NuvioTVUITests/AetherPlayerUITests.swift and AetherSubtitleUITests.swift.
#
# Usage: scripts/dev/aether-smoke-fixtures.sh [outdir]        (default: iosApp/build/smoke, gitignored)
#        scripts/dev/aether-smoke-fixtures.sh --serve [outdir] [port]   (also starts the range server in the foreground)
#
# Files (640x360 h264 test pattern + 440 Hz AAC, so the software route plays them on the simulator;
# existing files are kept, delete one to regenerate it):
#   aether-long.mkv      600 s, keyframe every 2 s, no chapters        play / seek / pause / scan / fallback legs
#   aether-chapters.mkv  600 s copy of the above + five named chapters  chapters shelf leg
#                        (Act One 0-90, Act Two 90-240, Act Three 240-390, Act Four 390-540, Act Five 540-600;
#                         none of the names is a skip-intro/recap/credits title, so Down reaches the pill row
#                         at any position)
#   aether-subs.mkv      300 s copy + audio "eng" + two embedded SRT tracks:
#                          "Embedded EN" (eng): 30-90 s "EMBEDDED ALPHA", 120-180 s "EMBEDDED BRAVO"
#                          "Forced EN" (eng, forced disposition): 40-100 s "FORCED NOTE"
#   aether-sidecar.vtt   WebVTT sidecar (loaded through -debug.mpvSmokeSubtitleURL): 30-90 s "SIDECAR ALPHA"
#   aether-subs.srt      the "Embedded EN" cues as a standalone file (for inspection)
#
# Serve (the legs read the URLs from TEST_RUNNER_AETHER_SMOKE_URL and friends):
#   python3 "<outer repo>/scripts/device/range_server.py" 8766 <outdir>    # port, then the directory
# or pass --serve here. The server answers Range requests and logs each one.
set -euo pipefail

SERVE=0
if [[ "${1:-}" == "--serve" ]]; then SERVE=1; shift; fi
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
OUT="${1:-$ROOT/iosApp/build/smoke}"
PORT="${2:-8766}"
mkdir -p "$OUT"
cd "$OUT"
log() { echo "[aether-fixtures] $*"; }

if [[ ! -f aether-long.mkv ]]; then
  log "aether-long.mkv (600 s h264 + aac)"
  ffmpeg -hide_banner -loglevel error -y \
    -f lavfi -i "testsrc2=size=640x360:rate=15" -f lavfi -i "sine=frequency=440:sample_rate=48000" -t 600 \
    -c:v libx264 -preset veryfast -crf 28 -pix_fmt yuv420p -g 30 -keyint_min 30 -sc_threshold 0 \
    -c:a aac -b:a 64k aether-long.mkv
fi

if [[ ! -f aether-chapters.mkv ]]; then
  log "aether-chapters.mkv (named chapters)"
  cat > aether-chapters.txt <<'META'
;FFMETADATA1
[CHAPTER]
TIMEBASE=1/1000
START=0
END=90000
title=Act One
[CHAPTER]
TIMEBASE=1/1000
START=90000
END=240000
title=Act Two
[CHAPTER]
TIMEBASE=1/1000
START=240000
END=390000
title=Act Three
[CHAPTER]
TIMEBASE=1/1000
START=390000
END=540000
title=Act Four
[CHAPTER]
TIMEBASE=1/1000
START=540000
END=600000
title=Act Five
META
  ffmpeg -hide_banner -loglevel error -y -i aether-long.mkv -i aether-chapters.txt -map 0 -map_metadata 1 -map_chapters 1 -c copy aether-chapters.mkv
fi

if [[ ! -f aether-subs.srt ]]; then
  cat > aether-subs.srt <<'SRT'
1
00:00:30,000 --> 00:01:30,000
EMBEDDED ALPHA

2
00:02:00,000 --> 00:03:00,000
EMBEDDED BRAVO
SRT
fi
if [[ ! -f aether-forced.srt ]]; then
  cat > aether-forced.srt <<'SRT'
1
00:00:40,000 --> 00:01:40,000
FORCED NOTE
SRT
fi
if [[ ! -f aether-sidecar.vtt ]]; then
  cat > aether-sidecar.vtt <<'VTT'
WEBVTT

00:00:30.000 --> 00:01:30.000
SIDECAR ALPHA
VTT
fi

if [[ ! -f aether-subs.mkv ]]; then
  log "aether-subs.mkv (300 s, eng audio, embedded SRT + forced SRT)"
  ffmpeg -hide_banner -loglevel error -y -t 300 -i aether-long.mkv -i aether-subs.srt -i aether-forced.srt \
    -map 0:v -map 0:a -map 1:0 -map 2:0 -c:v copy -c:a copy -c:s srt \
    -metadata:s:a:0 language=eng \
    -metadata:s:s:0 language=eng -metadata:s:s:0 title="Embedded EN" -disposition:s:0 0 \
    -metadata:s:s:1 language=eng -metadata:s:s:1 title="Forced EN" -disposition:s:1 forced \
    aether-subs.mkv
fi

log "done"
for f in aether-long.mkv aether-chapters.mkv aether-subs.mkv; do
  echo "== $f"; ffprobe -v error -show_entries stream=index,codec_type,codec_name:stream_tags=language,title:stream_disposition=forced:format=duration -of compact "$f"
done
ls -la aether-* >/dev/null

if [[ $SERVE -eq 1 ]]; then
  log "serving $OUT on :$PORT (Ctrl-C to stop)"
  exec python3 "$ROOT/../Nuvio tvOS/scripts/device/range_server.py" "$PORT" "$OUT"
fi
