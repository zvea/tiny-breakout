#!/bin/bash
# Usage: tools/flow_avg.sh NAME [SRC_DIR]
# TT utilisation (flow.sh place) for 3 orderings of the top module's register declarations,
# and their mean: synthesis results shift by up to a point with declaration order alone, so
# compare means. Runs the three in sequence, about 12 minutes.
set -euo pipefail
. "$(dirname "$0")/common.sh"
[ $# -ge 1 ] || { sed -n '2,5p' "$0"; exit 2; }
NAME=$1; SRC=$(cd "${2:-$ROOT/src}" && pwd)
W="$ROOT/build/flow_avg/$NAME"; rm -rf "$W"; mkdir -p "$W"
orderings "$SRC/tt_um_tiny_breakout.sv" 3 "$W/top"
vals=()
for i in 0 1 2; do
  mkdir -p "$W/$i"; cp "$SRC"/*.sv "$W/$i/"; cp "$W/top$i.sv" "$W/$i/tt_um_tiny_breakout.sv"
  vals+=("$("$ROOT/tools/flow.sh" place "${NAME}_o$i" "$W/$i" | grep -oE 'utilisation [0-9.]+' | grep -oE '[0-9.]+')")
done
python3 -c 'import sys; v=[float(x) for x in sys.argv[2:]]; print(f"{sys.argv[1]}: " + "  ".join(f"{x:.2f}" for x in v) + f"   mean {sum(v)/len(v):.2f}")' "$NAME" "${vals[@]}"
