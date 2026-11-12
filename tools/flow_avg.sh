#!/bin/bash
# Usage: tools/flow_avg.sh NAME [SRC_DIR]
# TT utilisation and the utilisation after repair (flow.sh repair) for 3 orderings of the top
# module's register declarations, and their means: synthesis results shift by up to a point with
# declaration order alone, so compare means. Runs the three in sequence, about 15 minutes.
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
. "$(dirname "$0")/common.sh"
usage() { sed -n '2,5p' "$0"; exit 2; }
[ $# -ge 1 ] && [ $# -le 2 ] || usage
NAME=$1
valid_name "$NAME" || { echo "NAME: letters, digits, _ . - only, not starting with a dot"; usage; }
SRC=$(cd "${2:-$ROOT/src}" && pwd)
W="$ROOT/build/flow_avg/$NAME"; rm -rf "$W"; mkdir -p "$W"
orderings "$SRC/tt_um_tiny_breakout.sv" 3 "$W/top"
vals=(); reps=()
for i in 0 1 2; do
  mkdir -p "$W/$i"; cp "$SRC"/*.sv "$W/$i/"; cp "$W/top$i.sv" "$W/$i/tt_um_tiny_breakout.sv"
  # SRC_DIR's own cell list for synthesis, if it has one (else flow.sh uses src's)
  if [ -f "$SRC/synth_excluded.cells" ]; then cp "$SRC/synth_excluded.cells" "$W/$i/"; fi
  # flow.sh says what failed and where its log is: show that, rather than end here silently
  if ! out=$("$ROOT/tools/flow.sh" repair "${NAME}_o$i" "$W/$i"); then
    echo "$NAME: ordering $i failed:"; echo "$out"; exit 1
  fi
  v=$(grep -oE 'TT utilisation [0-9.]+' <<<"$out" | grep -oE '[0-9.]+' || true)
  r=$(grep -oE 'after repair [0-9.]+' <<<"$out" | grep -oE '[0-9.]+' || true)
  [ -n "$v" ] && [ -n "$r" ] || { echo "$NAME: ordering $i gave no utilisation:"; echo "$out"; exit 1; }
  vals+=("$v"); reps+=("$r")
done
line() { "$PY" -c 'import sys; v=[float(x) for x in sys.argv[2:]]; print(f"{sys.argv[1]}" + "  ".join(f"{x:.2f}" for x in v) + f"   mean {sum(v)/len(v):.2f}")' "$@"; }
line "$NAME: TT utilisation           " "${vals[@]}"
line "$NAME: utilisation after repair " "${reps[@]}"
