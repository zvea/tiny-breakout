#!/bin/bash
# Usage: tools/local_area.sh [REV]
# Local sky130 synthesis area (yosys + ABC; about a minute) of the working tree and of git
# revision REV (default HEAD), each the mean of 5 orderings of the top module's register
# declarations. Noise is about +-50..100 um2, and the real flow often differs: use
# flow.sh place for the figure that counts.
#
# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
. "$(dirname "$0")/common.sh"
REV=${1:-HEAD}
W="$ROOT/build/local_area"; rm -rf "$W"; mkdir -p "$W"
LIB=$(liberty); [ -n "$LIB" ] || { echo "sky130 library not found (set PDK_ROOT)"; exit 1; }
cp "$LIB" "$W/hd.lib"  # yowasp's yosys only sees files under its working directory
for side in rev tree; do
  if [ $side = rev ]; then SRCS=$(sources "$REV"); else SRCS=$(sources); fi  # each side's own list
  for f in $SRCS; do
    if [ $side = rev ]; then git -C "$ROOT" show "$REV:src/$f" > "$W/$side.$f"; else cp "$ROOT/src/$f" "$W/$side.$f"; fi
  done
  for f in $(echo "$SRCS" | grep -v tt_um_tiny_breakout.sv); do cat "$W/$side.$f"; done > "$W/$side.subs.v"
  orderings "$W/$side.tt_um_tiny_breakout.sv" 5 "$W/$side.top"
done
for side in rev tree; do for i in 0 1 2 3 4; do echo "$side $i"; done; done |
  xargs -P 4 -n 2 bash -c 'cd "$0" && "$1" -q -p "read_verilog -sv $2.subs.v $2.top$3.sv; synth -top tt_um_tiny_breakout -flatten; dfflibmap -liberty hd.lib; abc -liberty hd.lib; opt_clean; tee -q -o $2.stat$3.txt stat -liberty hd.lib" > /dev/null 2>&1 || echo "synthesis failed: $2 $3" >&2' "$W" "$YOSYS"
python3 - "$W" "$REV" <<'PY'
import re, sys, glob
w, rev = sys.argv[1], sys.argv[2]
def areas(side):
    return [float(re.search(r"Chip area.*: ([0-9.]+)", open(f).read()).group(1)) for f in sorted(glob.glob(f"{w}/{side}.stat*.txt"))]
a, b = areas("rev"), areas("tree")
ma, mb = sum(a) / len(a), sum(b) / len(b)
print(f"{rev:>12}: {ma:7.0f} um2  ({min(a):.0f}..{max(a):.0f}, {len(a)} runs)")
print(f"{'working tree':>12}: {mb:7.0f} um2  ({min(b):.0f}..{max(b):.0f}, {len(b)} runs)  {mb - ma:+.0f} um2")
PY
