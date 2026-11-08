#!/bin/bash
# Usage: tools/equiv.sh [REV]
# Formal equivalence check (yosys equiv_make / equiv_simple / equiv_induct on the flattened
# designs) of the working tree against git revision REV (default HEAD), plus each side's local
# synthesis area. For refactors and renames that must not change the hardware.
# GOLD_RENAMES='rename old new; ...' renames signals in REV's design first, so renamed
# registers still pair up.
#
# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
. "$(dirname "$0")/common.sh"
REV=${1:-HEAD}
W="$ROOT/build/equiv"; rm -rf "$W"; mkdir -p "$W"
LIB=$(liberty); [ -n "$LIB" ] || { echo "sky130 library not found (set PDK_ROOT)"; exit 1; }
cp "$LIB" "$W/hd.lib"
for f in $(sources "$REV"); do git -C "$ROOT" show "$REV:src/$f"; done > "$W/gold.v"
for f in $(sources); do cat "$ROOT/src/$f"; done > "$W/new.v"
cd "$W"
for f in gold new; do
  "$YOSYS" -q -p "read_verilog -sv $f.v; synth -top tt_um_tiny_breakout -flatten; dfflibmap -liberty hd.lib; abc -liberty hd.lib; opt_clean; tee -q -o $f.stat.txt stat -liberty hd.lib" > $f.log 2>&1 ||
    { echo "synthesis failed for $f:"; grep -E ERROR $f.log; exit 1; }
  echo "$f: $(grep -oE 'Chip area.*: [0-9.]+' $f.stat.txt | grep -oE '[0-9.]+$') um2"
done
if "$YOSYS" -q -p "read_verilog -sv gold.v; hierarchy -top tt_um_tiny_breakout; proc; memory; flatten; rename tt_um_tiny_breakout gold; cd gold; ${GOLD_RENAMES:-} cd ..; design -stash g1;
  read_verilog -sv new.v; hierarchy -top tt_um_tiny_breakout; proc; memory; flatten; rename tt_um_tiny_breakout gate; design -stash g2;
  design -copy-from g1 -as gold gold; design -copy-from g2 -as gate gate;
  opt_clean; equiv_make gold gate eq; hierarchy -top eq; equiv_simple -seq 4; equiv_induct -seq 4; tee -q -o equiv.txt equiv_status -assert" > equiv.log 2>&1; then
  echo "EQUIVALENT: $(grep -E 'Found|proven' equiv.txt | tr -s ' ' | head -2 | tr '\n' ' ')"
else
  echo "NOT EQUIVALENT (or the check failed; see build/equiv/equiv.log):"
  grep -E 'ERROR|Found|proven|Unproven' equiv.log equiv.txt 2>/dev/null | head -5; exit 1
fi
