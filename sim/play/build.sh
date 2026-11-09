#!/bin/sh
# Builds the interactive player. Needs Verilator 4.x, in .tools/v4 or on PATH (see
# test/README.md): sim.h relies on its internals (and 5.x is ~2x slower here). Run it from
# anywhere; then, e.g. from this directory, ./obj_serve/Vtt_um_tiny_breakout [port] [index.html].
#
# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -e
cd "$(dirname "$0")"  # obj_serve and serve.cpp are relative to this directory
ROOT=$(cd ../.. && pwd)
export PATH="$ROOT/.tools/v4/bin:$PATH"
# Verilator 5 fails later with a C++ error about __Vclklast__TOP__clk: say so up front
VERSION=$(verilator --version 2>/dev/null || true)
case "$VERSION" in
  "Verilator 4."*) ;;
  "") echo "build.sh: verilator not found; the player needs Verilator 4.x (see test/README.md)" >&2; exit 1 ;;
  *)  echo "build.sh: found ${VERSION%% rev*}; the player needs Verilator 4.x (see test/README.md)" >&2; exit 1 ;;
esac
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
