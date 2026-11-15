#!/bin/bash
# Usage: tools/flow_avg.sh NAME [SRC_DIR]
# TT utilisation and the utilisation after repair (flow.sh repair) for 3 orderings of the top
# module's register declarations, and their means: synthesis results shift by up to a point with
# declaration order alone, so compare means. Runs the three at the same time (separate run
# directories): about 1.5 minutes, against about 4 one after another.
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
for i in 0 1 2; do
  mkdir -p "$W/$i"; cp "$SRC"/*.sv "$W/$i/"; cp "$W/top$i.sv" "$W/$i/tt_um_tiny_breakout.sv"
  # SRC_DIR's own cell list for synthesis, if it has one (else flow.sh uses src's)
  if [ -f "$SRC/synth_excluded.cells" ]; then cp "$SRC/synth_excluded.cells" "$W/$i/"; fi
done
# The three at once, each into its own output file. With job control (set -m) each runs in a
# process group of its own, and doesn't start with SIGINT ignored, as a script's background
# jobs otherwise do. So an interrupt (Ctrl-C), passed on to each group, reaches flow.sh and
# LibreLane, which stops its container; and any still running when this ends (one failed) are
# stopped the same way.
pids=()
stop() { for p in "${pids[@]}"; do kill -INT -- "-$p" 2>/dev/null || true; done; }
trap 'stop; exit 130' INT
trap 'stop; exit 143' TERM
trap stop EXIT
set -m
for i in 0 1 2; do
  "$ROOT/tools/flow.sh" repair "${NAME}_o$i" "$W/$i" > "$W/$i.out" 2>&1 &
  pids[i]=$!
done
set +m
vals=(); reps=()
for i in 0 1 2; do
  if ! wait "${pids[i]}"; then
    # flow.sh says what failed and where its log is: show that, rather than end here silently
    echo "$NAME: ordering $i failed:"; cat "$W/$i.out"; exit 1
  fi
  out=$(<"$W/$i.out")
  v=$(grep -oE 'TT utilisation [0-9.]+' <<<"$out" | grep -oE '[0-9.]+' || true)
  r=$(grep -oE 'after repair [0-9.]+' <<<"$out" | grep -oE '[0-9.]+' || true)
  [ -n "$v" ] && [ -n "$r" ] || { echo "$NAME: ordering $i gave no utilisation:"; echo "$out"; exit 1; }
  vals+=("$v"); reps+=("$r")
done
line() { "$PY" -c 'import sys; v=[float(x) for x in sys.argv[2:]]; print(f"{sys.argv[1]}" + "  ".join(f"{x:.2f}" for x in v) + f"   mean {sum(v)/len(v):.2f}")' "$@"; }
line "$NAME: TT utilisation           " "${vals[@]}"
line "$NAME: utilisation after repair " "${reps[@]}"
