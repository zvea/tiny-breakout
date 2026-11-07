#!/bin/bash
# Usage: tools/lec.sh RUN_DIR [SRC_DIR]
# Logical equivalence check of the RTL in SRC_DIR (default src) against the final netlist of a
# hardened run (RUN_DIR/final/nl), so synthesis, resizing and clock-tree changes are proven not
# to change the logic. LVS only compares the layout with that netlist. The cells are modelled
# from the sky130 Liberty file; buffers, delay cells and clock buffers become wires. Registers
# pair up by name, and yosys proves each matched signal (registers and outputs) equivalent.
#
# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
. "$(dirname "$0")/common.sh"
[ $# -ge 1 ] || { sed -n '2,7p' "$0"; exit 2; }
RUN=$(cd "$1" && pwd); SRC=$(cd "${2:-$ROOT/src}" && pwd)
NL="$RUN/final/nl/tt_um_tiny_breakout.nl.v"
[ -f "$NL" ] || { echo "no final netlist: $NL"; exit 1; }
W="$ROOT/build/lec"; rm -rf "$W"; mkdir -p "$W"
LIB=$(liberty); [ -n "$LIB" ] || { echo "sky130 library not found (set PDK_ROOT)"; exit 1; }
cp "$LIB" "$W/hd.lib"
for f in $(sources); do cat "$SRC/$f"; done > "$W/rtl.v"
cp "$NL" "$W/netlist.v"
cd "$W"
# RTL side: splitnets names each bit like the netlist's single-bit nets (ball_x[3]).
# Netlist side: plain opt_clean, as -purge would also drop the named internal nets.
if "$YOSYS" -q -p "
  read_verilog -sv rtl.v; hierarchy -top tt_um_tiny_breakout; proc; memory; flatten; opt_clean; splitnets;
  rename tt_um_tiny_breakout gold; design -stash rtl;
  read_liberty -ignore_miss_func hd.lib; read_verilog netlist.v; hierarchy -top tt_um_tiny_breakout; flatten; opt_clean;
  rename tt_um_tiny_breakout gate; design -stash netlist;
  design -copy-from rtl -as gold gold; design -copy-from netlist -as gate gate;
  equiv_make gold gate eq; hierarchy -top eq; equiv_simple -seq 4; equiv_induct -seq 4;
  tee -q -o lec.txt equiv_status -assert" > lec.log 2>&1; then
  echo "EQUIVALENT: $(grep -oE '[0-9]+ \$equiv cells' lec.txt | head -1 | grep -oE '^[0-9]+') matched signals proven"
else
  echo "NOT EQUIVALENT (or the check failed; see build/lec/lec.log):"
  grep -E 'ERROR|Of those|Unproven' lec.log lec.txt 2>/dev/null | head -8; exit 1
fi
