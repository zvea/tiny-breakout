#!/bin/sh
# Builds the interactive player. Needs Verilator 4.x, in .tools/v4 or on PATH (see
# test/README.md): sim.h relies on its internals (and 5.x is ~2x slower here). Run it from
# anywhere; then, from this directory, ./obj_serve/Vtt_um_tiny_breakout [port] [index.html].
#
# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -e
cd "$(dirname "$0")"  # obj_serve and serve.cpp are relative to this directory
ROOT=$(cd ../.. && pwd)
export PATH="$ROOT/.tools/v4/bin:$PATH"
# The sources listed in info.yaml, in order
SOURCES=$(sed -n 's/^ *- "\([A-Za-z0-9_]*\.sv\)".*/\1/p' "$ROOT/info.yaml" | sed "s|^|$ROOT/src/|")
case "$(uname -s)" in
  Darwin) CFLAGS="-O3 -fomit-frame-pointer -pthread" ;;  # Apple clang: no -march=native or -fno-plt
  *)      CFLAGS="-O3 -march=native -fno-plt -fomit-frame-pointer -pthread" ;;
esac
rm -rf obj_serve
verilator --cc --build -O3 --inline-mult -1 --output-split 0 -Wno-fatal \
  --x-assign fast --x-initial fast \
  -CFLAGS "$CFLAGS" -LDFLAGS "-pthread" \
  --exe serve.cpp $SOURCES --top-module tt_um_tiny_breakout -Mdir obj_serve -j 8 >/dev/null
echo "built obj_serve/Vtt_um_tiny_breakout"
