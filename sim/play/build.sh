#!/bin/sh
# Builds the interactive player. Needs Verilator 4.x (5.x's scheduler is ~2x slower for this
# tiny design). Run from this directory; then ./obj_serve/Vtt_um_tiny_breakout [port] [index.html]
# Optional features: ENABLE_SCORE=1 ./build.sh
set -e
ROOT=$(cd ../.. && pwd)
export PATH="$ROOT/.tools/v4/bin:$PATH"
rm -rf obj_serve
verilator --cc --build -O3 --inline-mult -1 --output-split 0 -Wno-fatal \
  --x-assign fast --x-initial fast \
  -CFLAGS "-O3 -march=native -fno-plt -fomit-frame-pointer -pthread" -LDFLAGS "-pthread" \
  --exe serve.cpp "$ROOT/src/colour_pkg.sv" "$ROOT/src/gamepad_pkg.sv" "$ROOT/src/gamepad_rx.sv" "$ROOT/src/vga_timing.sv" "$ROOT/src/autoplay.sv" "$ROOT/src/brick_wall.sv" "$ROOT/src/score.sv" "$ROOT/src/tiny_vga_out.sv" \
  "$ROOT/src/tt_um_tiny_breakout.sv" --top-module tt_um_tiny_breakout -Mdir obj_serve -j 8 \
  -GENABLE_SCORE="${ENABLE_SCORE:-0}" >/dev/null
echo "built obj_serve/Vtt_um_tiny_breakout"
