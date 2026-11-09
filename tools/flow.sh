#!/bin/bash
# Usage: tools/flow.sh place|harden TAG [SRC_DIR]
# Runs the Tiny Tapeout flow (LibreLane, dockerized) with src/config.json on the sources in
# SRC_DIR (default src), into runs/exp_TAG, and prints the results:
#   place:  up to global placement; TT's utilisation figure (GPL-0019). About 4 minutes.
#   harden: the whole flow; also DRC, LVS, antenna, timing, tools/warnings.sh and tools/lec.sh.
#           About 15 minutes.
# EXTRA_CFG='{"KEY": value}' overrides config values, for experiments.
# Needs src/user_config.json: ./tt/tt_tool.py --create-user-config
#
# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
. "$(dirname "$0")/common.sh"
usage() { sed -n '2,9p' "$0"; exit 2; }
[ $# -ge 2 ] && [ $# -le 3 ] || usage
MODE=$1; TAG=$2
case $MODE in
  place)  TO=(--to OpenROAD.GlobalPlacement) ;;
  harden) TO=() ;;
  *)      usage ;;
esac
valid_name "$TAG" || { echo "TAG: letters, digits, _ . - only, not starting with a dot"; usage; }
SRC=$(cd "${3:-$ROOT/src}" && pwd)
cd "$ROOT"
[ -f src/user_config.json ] || { echo "missing src/user_config.json: run ./tt/tt_tool.py --create-user-config"; exit 1; }
D=runs/exp_$TAG; C=.exp_src_$TAG
rm -rf "./$D" "./$C"; mkdir -p "$D" "$C"
trap 'rm -rf -- "./$C"' EXIT  # the source copy goes even if interrupted
# The sources, and the cell list config.json gives synthesis (dir::): SRC_DIR's, else src's
CELLS="$SRC/synth_excluded.cells"; [ -f "$CELLS" ] || CELLS="$ROOT/src/synth_excluded.cells"
cp "$SRC"/*.sv "$CELLS" "$C/"
# VERILOG_FILES: info.yaml's sources, in its order, that SRC_DIR has (user_config.json's list
# is a copy of info.yaml's from when it was made)
"$PY" - "$C" $(sources) <<'PY'
import json, os, sys
c, sources = sys.argv[1], sys.argv[2:]
cfg = json.load(open("src/config.json")); cfg.update(json.load(open("src/user_config.json")))
cfg["VERILOG_FILES"] = [f"dir::{f}" for f in sources if os.path.exists(os.path.join(c, f))]
cfg.update(json.loads(os.environ.get("EXTRA_CFG", "{}")))
json.dump(cfg, open(os.path.join(c, "config_merged.json"), "w"), indent=2)
PY
"$PY" -m librelane --docker-no-tty --dockerized --run-tag "exp_$TAG" --force-run-dir "$D" \
  ${TO[@]+"${TO[@]}"} "$C/config_merged.json" > "$D.log" 2>&1 || { echo "$TAG: FLOW FAILED (see $D.log)"; tail -5 "$D.log"; exit 1; }
# n/a if the log lacks the line, so the rest of the report still prints
UTIL=$(grep -hE '^\[INFO GPL-0019\] (Util|Utilization):' "$D"/*-openroad-globalplacement/openroad-globalplacement.log | head -1 | sed -E 's/.*: *//' || true)
UTIL=${UTIL:-n/a}
echo "$TAG: TT utilisation $UTIL"
if [ "$MODE" = harden ]; then
  "$PY" - "$D/final/metrics.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for k in ["route__drc_errors", "magic__drc_error__count", "design__lvs_error__count",
          "antenna__violating__nets", "timing__setup__ws", "timing__hold__ws",
          "design__instance__utilization", "route__wirelength"]:
    print(f"  {k}: {m.get(k, 'n/a')}")
PY
  echo "  GDS: $D/final/gds/tt_um_tiny_breakout.gds"
  # Warnings the flow reports but does not fail on; then the netlist must implement the RTL
  # (LVS only checks the layout against the netlist). Both run before either can fail.
  FAIL=0
  "$ROOT/tools/warnings.sh" "$D" | sed 's/^/  /' || FAIL=1
  LEC=$("$ROOT/tools/lec.sh" "$D" "$C") || FAIL=1
  echo "LEC: $LEC" | sed 's/^/  /'
  exit $FAIL
fi
