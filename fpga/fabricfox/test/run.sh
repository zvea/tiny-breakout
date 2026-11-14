#!/bin/bash
# Checks the pin file (src/fabricfox.pcf) against the board's own, from Tiny Tapeout's
# breakout-pcb repository at a fixed commit: every pin the game uses (clk, rst_n, ui_in, uo_out
# and uio) must be there, on the board's pin for it, and nothing else.
# Usage: test/run.sh [BOARD_PCF]  (the board's pin file; default: fetched from GitHub)
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../tools/common.sh"

# The FabricFox FPGASIC (ttdbv3-fpga-ICE40UP5k): its pin file as of e6cff32, which gave the
# pins the game's names; the same pins as Tiny Tapeout's support tools use
# (tt_fpga_fabricfoxv2.pcf)
BOARD_REPO=TinyTapeout/breakout-pcb
BOARD_COMMIT=e6cff3234d9ed300e53bc2b6d4941920eac1dcb0
BOARD_PATH=ASIC-simulator/ttdbv3-fpga-ICE40UP5k/fabricfox.pcf

mkdir -p "$BOARD/build"
board_pcf=${1:-}
if [ -z "$board_pcf" ]; then
  board_pcf="$BOARD/build/board.pcf"
  curl -fsSL -o "$board_pcf" \
    "https://raw.githubusercontent.com/$BOARD_REPO/$BOARD_COMMIT/$BOARD_PATH"
fi

# pins FILE: each set_io's name and pin, "name pin" sorted, whatever its options
pins() {
  sed 's/#.*//' "$1" | awk '$1 == "set_io" { print $(NF - 1), $NF }' | sort
}

# The game's pins: the names our top module has
want=$( (echo clk; echo rst_n
         for bus in ui_in uo_out uio; do
           for i in 0 1 2 3 4 5 6 7; do echo "${bus}[$i]"; done
         done) | sort)

ours=$(pins "$BOARD/src/fabricfox.pcf")
theirs=$(pins "$board_pcf" | join - <(echo "$want"))  # only the game's pins, of the board's

fail=0
if [ "$(echo "$ours" | cut -d' ' -f1)" != "$want" ]; then
  echo "FAIL: the pin file should have exactly the game's 26 pins; differences (< want, > has):"
  diff <(echo "$want") <(echo "$ours" | cut -d' ' -f1) || true
  fail=1
fi
if [ "$ours" != "$theirs" ]; then
  echo "FAIL: pins differ from the board's (< board's, > ours):"
  diff <(echo "$theirs") <(echo "$ours") || true
  fail=1
fi
[ "$fail" = 0 ] || { echo FAIL; exit 1; }
echo "$(echo "$ours" | wc -l) pins, the same as the board's pin file: PASS"
