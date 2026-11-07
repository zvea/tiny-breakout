#!/bin/bash
# Usage: tools/flow.sh place|harden TAG [SRC_DIR]
# Runs the Tiny Tapeout flow (LibreLane, dockerized) with src/config.json on the sources in
# SRC_DIR (default src), into runs/exp_TAG, and prints the results:
#   place:  up to global placement; TT's utilisation figure (GPL-0019). About 4 minutes.
#   harden: the whole flow; also DRC, LVS, antenna and timing. About 15 minutes.
# EXTRA_CFG='{"KEY": value}' overrides config values, for experiments.
# Needs src/user_config.json: ./tt/tt_tool.py --create-user-config
set -euo pipefail
. "$(dirname "$0")/common.sh"
[ $# -ge 2 ] || { sed -n '2,9p' "$0"; exit 2; }
MODE=$1; TAG=$2; SRC=$(cd "${3:-$ROOT/src}" && pwd)
case $MODE in
  place)  TO=(--to OpenROAD.GlobalPlacement) ;;
  harden) TO=() ;;
  *)      sed -n '2,9p' "$0"; exit 2 ;;
esac
cd "$ROOT"
[ -f src/user_config.json ] || { echo "missing src/user_config.json: run ./tt/tt_tool.py --create-user-config"; exit 1; }
source .venv/bin/activate
D=runs/exp_$TAG; C=.exp_src_$TAG
rm -rf "./$D" "./$C"; mkdir -p "$D" "$C"
trap 'rm -rf -- "./$C"' EXIT  # the source copy goes even if interrupted
cp "$SRC"/*.sv "$C/"
python - "$C" <<'PY'
import json, os, sys
c = sys.argv[1]
cfg = json.load(open("src/config.json")); cfg.update(json.load(open("src/user_config.json")))
cfg.update(json.loads(os.environ.get("EXTRA_CFG", "{}")))
cfg["VERILOG_FILES"] = [f for f in cfg["VERILOG_FILES"] if os.path.exists(os.path.join(c, f.replace("dir::", "")))]
json.dump(cfg, open(os.path.join(c, "config_merged.json"), "w"), indent=2)
PY
python -m librelane --docker-no-tty --dockerized --run-tag "exp_$TAG" --force-run-dir "$D" \
  "${TO[@]}" "$C/config_merged.json" > "$D.log" 2>&1 || { echo "$TAG: FLOW FAILED (see $D.log)"; tail -5 "$D.log"; exit 1; }
UTIL=$(grep -hE '^\[INFO GPL-0019\] (Util|Utilization):' "$D"/*-openroad-globalplacement/openroad-globalplacement.log | head -1 | sed -E 's/.*: *//')
echo "$TAG: TT utilisation $UTIL"
if [ "$MODE" = harden ]; then
  python3 - "$D/final/metrics.json" <<'PY'
import json, sys
m = json.load(open(sys.argv[1]))
for k in ["route__drc_errors", "magic__drc_error__count", "design__lvs_error__count",
          "antenna__violating__nets", "timing__setup__ws", "timing__hold__ws",
          "design__instance__utilization", "route__wirelength"]:
    print(f"  {k}: {m.get(k, 'n/a')}")
PY
  echo "  GDS: $D/final/gds/tt_um_tiny_breakout.gds"
fi
