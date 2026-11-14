#!/bin/bash
# Builds the FabricFox bitstream, build/fabricfox.bin: synthesis (yosys), place and route
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

# The SystemVerilog through yosys-slang; fabricfox_top.v (plain Verilog, with the I/O cells)
# through yosys's own front end. -j 1: yowasp's yosys (WebAssembly) has no threads.
echo "Synthesis: $BUILD/synth.log"
"$VENV/bin/yowasp-yosys" -q -l "$BUILD/synth.log" -p "
  read_slang -j 1 --top tt_um_tiny_breakout $(game_sources | tr '\n' ' ')
  read_verilog $REL/src/fabricfox_top.v
  synth_ice40 -top fabricfox_top -json $BUILD/fabricfox.json
" > /dev/null

# Timed at the clock the demo board supplies, info.yaml's clock_hz (25.175 MHz, 640x480 at
# 60 Hz), which everything runs on. nextpnr fails if timing does.
hz=$(sed -n 's/^ *clock_hz: *\([0-9][0-9]*\).*/\1/p' "$ROOT/info.yaml")
[ -n "$hz" ] || { echo "No clock_hz in info.yaml" >&2; exit 1; }
mhz=$(awk -v hz="$hz" 'BEGIN { print hz / 1e6 }')
echo "Place and route at $mhz MHz: $BUILD/pnr.log"
"$VENV/bin/yowasp-nextpnr-ice40" -q -l "$BUILD/pnr.log" \
  --up5k --package sg48 --json "$BUILD/fabricfox.json" --pcf "$REL/src/fabricfox.pcf" \
  --asc "$BUILD/fabricfox.asc" --freq "$mhz" --seed "$seed"

echo "Bitstream: $BUILD/fabricfox.bin"
"$VENV/bin/yowasp-icepack" "$BUILD/fabricfox.asc" "$BUILD/fabricfox.bin"

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
