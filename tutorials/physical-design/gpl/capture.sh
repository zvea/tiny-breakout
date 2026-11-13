#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
# Re-runs the run's global placement step in LibreLane's container, stopped early at each
# frame, writing frames/<frame>.def. Frames: initial placement after k conjugate-gradient
# iterations (ip0..ip5), Nesterov placement stopped at an overflow target (ovNN), and the
# routability snapshot (snap).
# Usage: capture.sh RUN_DIR
set -e
RUN=$(cd "$1" && pwd); HERE=$(cd "$(dirname "$0")" && pwd)
P=$(git -C "$HERE" rev-parse --show-toplevel)   # mounted read-only: the run is inside it
STEP=$(cd "$RUN" && ls -d [0-9]*-openroad-globalplacement)
IMG=ghcr.io/librelane/librelane:3.0.14
PY=/nix/store/8y4m6wgn5kqlbig1qwnwbxijqqp0jwib-python3-3.13.9-env/bin/python3
OR=/nix/store/acqm3cm6m4bj83ygn6ynjksl920zz9zx-openroad-2026-02-17-python3-3.13.9-env/bin/openroad
mkdir -p "$HERE/fake_design" "$HERE/frames" "$HERE/logs" && touch "$HERE/fake_design/synth_excluded.cells"
# the run's config points at a temporary source dir that no longer exists; both paths are
# synthesis-only and unused here
python3 - "$RUN/$STEP/config.json" "$HERE/config.json" "$HERE/fake_design" <<'PYEOF'
import json, sys
c = json.load(open(sys.argv[1]))
c["SYNTH_EXCLUDED_CELL_FILE"] = sys.argv[3] + "/synth_excluded.cells"
c["DESIGN_DIR"] = sys.argv[3]
json.dump(c, open(sys.argv[2], "w"), indent=1)
PYEOF
frame() {  # name, extra global_placement arguments
  local O="$HERE/work/$1"; rm -rf "$O"; mkdir -p "$O"
  docker run --rm --user "$(id -u):$(id -g)" -v "$P:$P:ro" -v "$HERE:$HERE:rw" \
    -v "$HOME/.ciel:$HOME/.ciel:ro" -e HOME=/tmp -w /tmp \
    -e REPRO_OUT="$HERE/frames" -e FRAME="$1" -e GPL_EXTRA="$2" \
    -e _LLN_OVERRIDE_OPENROAD="$HERE/openroad_wrapper.sh" -e REAL_OPENROAD="$OR" \
    $IMG $PY -m librelane.steps run --id OpenROAD.GlobalPlacement -c "$HERE/config.json" \
      -i "$RUN/$STEP/state_in.json" -o "$O" --condensed > "$HERE/logs/$1.log" 2>&1 || true
  [ -s "$HERE/frames/$1.def" ] || { echo "$1: no DEF (see logs/$1.log)"; return 1; }
}
jobs=()
for k in 0 1 2 3 4 5; do jobs+=("ip$k|-skip_nesterov_place -initial_place_max_iter $k"); done
for ov in 0.97 0.95 0.92 0.88 0.84 0.80 0.76 0.72 0.68 0.64 0.60 0.55 0.50 0.45 0.40 0.35 \
          0.28 0.25 0.22 0.19 0.16 0.13 0.10; do jobs+=("ov${ov#0.}|-overflow $ov"); done
# the routability snapshot every round rewinds to: the first iteration below 0.6 (GPL-0038)
jobs+=("snap|-overflow 0.597")
for j in "${jobs[@]}"; do
  ( frame "${j%%|*}" "${j#*|}" ) &
  while [ "$(jobs -r | wc -l)" -ge 4 ]; do wait -n; done
done
wait
# check: stopping at the run's own target (0.1) must give the run's own placement
diff -q <(awk '/^COMPONENTS /,/^END COMPONENTS/' "$HERE/frames/ov10.def") \
        <(awk '/^COMPONENTS /,/^END COMPONENTS/' "$RUN/$STEP/tt_um_tiny_breakout.def") \
  && echo "ov10 matches the run's placement"
ls "$HERE/frames" | wc -l
