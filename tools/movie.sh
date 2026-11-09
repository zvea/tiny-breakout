#!/bin/bash
# Usage: tools/movie.sh [-o FILE] [--extra SECONDS] [SRC_DIR]
# A movie of the demo, with its sound: the design (in SRC_DIR, default src) from reset with no
# controller connected, until SECONDS (default 3) into the second level. Simulated in Verilator
# with the player's model (sim/play/sim.h), so it shows exactly what the chip would, the sound
# as the Audio Pmod plays it. Writes FILE (default build/demo.mp4): H.264 and AAC, 640x480 at
# 60 fps. Takes several minutes; needs Verilator 4 (.tools/v4, else PATH) and ffmpeg.
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
. "$(dirname "$0")/common.sh"
usage() { sed -n '2,7p' "$0"; exit 2; }
OUT="$ROOT/build/demo.mp4"
EXTRA=3
while [ $# -gt 0 ]; do
  case "$1" in
    -o) [ $# -ge 2 ] || usage; OUT=$(abspath "$2"); shift 2 ;;
    --extra) [ $# -ge 2 ] && [[ $2 =~ ^(0|[1-9][0-9]*)$ ]] || usage; EXTRA=$2; shift 2 ;;
    --) shift; break ;;
    -*) echo "unknown option $1"; usage ;;
    *) break ;;
  esac
done
[ $# -le 1 ] || usage
SRC=$(cd "${1:-$ROOT/src}" && pwd)
command -v ffmpeg > /dev/null || { echo "ffmpeg not found"; exit 1; }
# Verilator 4: sim.h relies on its internals (see sim/play/build.sh); 5 fails with C++ errors
if [ -x "$ROOT/.tools/v4/bin/verilator" ]; then export PATH="$ROOT/.tools/v4/bin:$PATH"; fi
VERSION=$(verilator --version 2>/dev/null || true)
case $VERSION in
  "Verilator 4."*) ;;
  *) echo "movie.sh needs Verilator 4, in .tools/v4 or on PATH (see test/README.md); found: ${VERSION:-none}"
     exit 1 ;;
esac
W="$ROOT/build/movie"; rm -rf "$W"; mkdir -p "$W" "$(dirname "$OUT")"
case "$(uname -s)" in
  Darwin) CFLAGS="-O3" ;;
  *)      CFLAGS="-O3 -march=native" ;;
esac
verilator --cc --exe --build -O3 -Wno-fatal --x-assign fast --x-initial fast \
  -CFLAGS "$CFLAGS -I$ROOT/sim/play" --top-module tt_um_tiny_breakout -Mdir "$W/obj" -j 8 \
  "$ROOT/tools/movie.cpp" $(for f in $(sources); do echo "$SRC/$f"; done) > "$W/build.log" 2>&1 ||
  { echo "Verilator failed: see $W/build.log"; tail -5 "$W/build.log"; exit 1; }
# The picture, encoded as it is simulated (flat colours: x264's animation tuning keeps it small)
"$W/obj/Vtt_um_tiny_breakout" "$W/audio.raw" $((EXTRA * 60)) |
  ffmpeg -hide_banner -loglevel error -f rawvideo -pix_fmt rgb24 -s 640x480 -r 60 -i - \
    -c:v libx264 -preset slow -tune animation -crf 24 -pix_fmt yuv420p "$W/video.mp4"
# Then the sound alongside it, its loudest moment at -1 dB
RAW=(-f s16le -ar 48000 -ac 1 -i "$W/audio.raw")
PEAK=$(ffmpeg -hide_banner "${RAW[@]}" -af volumedetect -f null - 2>&1 |
  sed -n 's/.*max_volume: \(-*[0-9.]*\) dB.*/\1/p')
GAIN=$("$PY" -c "print(-1 - ${PEAK:-0})")
ffmpeg -hide_banner -loglevel error -y -i "$W/video.mp4" "${RAW[@]}" -af "volume=${GAIN}dB" \
  -c:v copy -c:a aac -b:a 96k -shortest -movflags +faststart "$OUT"
SECS=$(ffprobe -v error -show_entries format=duration -of csv=p=0 "$OUT" | cut -d. -f1)
echo "wrote $OUT ($(($(wc -c < "$OUT") / 1024)) KiB, $SECS s)"
