#!/bin/sh
# Builds the interactive player. Needs Verilator 4.x: sim.h relies on its internals (and 5.x
# is ~2x slower here). Run from this directory; then ./obj_serve/Vtt_um_tiny_breakout [port]
# [index.html].
set -e
ROOT=$(cd ../.. && pwd)
export PATH="$ROOT/.tools/v4/bin:$PATH"
# The sources listed in info.yaml, in order
SOURCES=$(sed -n 's/^ *- "\([a-z_]*\.sv\)".*/\1/p' "$ROOT/info.yaml" | sed "s|^|$ROOT/src/|")
rm -rf obj_serve
verilator --cc --build -O3 --inline-mult -1 --output-split 0 -Wno-fatal \
  --x-assign fast --x-initial fast \
  -CFLAGS "-O3 -march=native -fno-plt -fomit-frame-pointer -pthread" -LDFLAGS "-pthread" \
  --exe serve.cpp $SOURCES --top-module tt_um_tiny_breakout -Mdir obj_serve -j 8 >/dev/null
echo "built obj_serve/Vtt_um_tiny_breakout"
