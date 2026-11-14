#!/bin/bash
# Builds the iCEBreaker bitstream, build/icebreaker.bin: synthesis (yosys), place and route
# (nextpnr) and packing (icepack). Logs are in build/.
# Usage: tools/build.sh [SEED]  (nextpnr's placement seed, default 1)
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
seed=${1:-1}

need_venv
cd "$ROOT"  # yowasp's tools see only the directory they start in, and below
mkdir -p "$BUILD"

# The SystemVerilog through yosys-slang; icebreaker_top.v (plain Verilog, with the PLL)
# through yosys's own front end. -j 1: yowasp's yosys (WebAssembly) has no threads.
echo "Synthesis: $BUILD/synth.log"
"$VENV/bin/yowasp-yosys" -q -l "$BUILD/synth.log" -p "
  read_slang -j 1 --top breakout_vga $(game_sources | tr '\n' ' ') $REL/src/breakout_vga.sv
  read_verilog $REL/src/icebreaker_top.v
  synth_ice40 -top icebreaker_top -json $BUILD/icebreaker.json
" > /dev/null

# Timed at the PLL's 25.125 MHz, which everything runs on. nextpnr fails if timing does.
echo "Place and route: $BUILD/pnr.log"
"$VENV/bin/yowasp-nextpnr-ice40" -q -l "$BUILD/pnr.log" \
  --up5k --package sg48 --json "$BUILD/icebreaker.json" --pcf "$REL/src/icebreaker.pcf" \
  --asc "$BUILD/icebreaker.asc" --freq 25.125 --seed "$seed"

echo "Bitstream: $BUILD/icebreaker.bin"
"$VENV/bin/yowasp-icepack" "$BUILD/icebreaker.asc" "$BUILD/icebreaker.bin"

# A summary, from nextpnr's log: the chip's resources the design uses (those it uses at all),
# and the clock's maximum frequency after routing (the report after "Routing complete": the
# one before it is placement's estimate) against its target (--freq)
echo
echo "Resources (used / on the chip):"
sed -n '/Device utilisation:/,/^$/p' "$BUILD/pnr.log" |
  sed -nE 's/^Info:[[:space:]]+([A-Za-z0-9_]+): +([0-9]+)\/ *([0-9]+) +([0-9]+)%.*/\1 \2 \3 \4/p' |
  awk '$2 > 0 { printf "  %-14s %6d / %6d  %3d%%\n", $1, $2, $3, $4 }'
echo "Timing (maximum frequency after routing):"
TIMING=$(sed -n '/Routing complete/,$p' "$BUILD/pnr.log" | grep "Max frequency for clock" |
  sed -nE "s/.*clock +'([^']+)': +([0-9.]+) MHz \((PASS|FAIL) at ([0-9.]+) MHz.*/\1 \2 \3 \4/p" |
  awk '{ printf "  %-22s %7.2f MHz (target %.2f): %s, %.1fx margin\n", $1, $2, $4, $3, $2 / $4 }' ||
  true)  # none found: say so below, rather than end the script (pipefail)
echo "${TIMING:-  none found after routing in $BUILD/pnr.log: has the report changed?}"
