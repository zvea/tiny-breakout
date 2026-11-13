#!/bin/bash
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
# Re-run the placement steps that end in a legalisation (32 repair design,
# 35 CTS, 37 hold repair) in LibreLane's container, writing the layout before
# and after the legalisation into out/<step>/. The run itself is mounted
# read-only. Usage: run_repro.sh [run_dir]
set -e
HERE=$(cd "$(dirname "$0")" && pwd)
P=$(git -C "$HERE" rev-parse --show-toplevel)   # mounted read-only: the run is inside it
RUN=$(cd "${1:-$P/runs/exp_rowtail}" && pwd)
IMG=ghcr.io/librelane/librelane:3.0.14
PY=/nix/store/8y4m6wgn5kqlbig1qwnwbxijqqp0jwib-python3-3.13.9-env/bin/python3
OR=/nix/store/acqm3cm6m4bj83ygn6ynjksl920zz9zx-openroad-2026-02-17-python3-3.13.9-env/bin/openroad
mkdir -p "$HERE/fake_design" && touch "$HERE/fake_design/synth_excluded.cells"
for pair in 32-openroad-repairdesignpostgpl:OpenROAD.RepairDesignPostGPL 35-openroad-cts:OpenROAD.CTS 37-openroad-resizertimingpostcts:OpenROAD.ResizerTimingPostCTS; do
  step=${pair%%:*}; id=${pair#*:}
  O="$HERE/out/$step"; rm -rf "$O"; mkdir -p "$O"
  # the run's config points at a temporary source dir that no longer exists;
  # both paths are synthesis-only and unused by these steps
  python3 - "$RUN/$step/config.json" "$O/config.json" "$HERE/fake_design" <<'PYEOF'
import json, sys
c = json.load(open(sys.argv[1]))
c["SYNTH_EXCLUDED_CELL_FILE"] = sys.argv[3] + "/synth_excluded.cells"
c["DESIGN_DIR"] = sys.argv[3]
json.dump(c, open(sys.argv[2], "w"), indent=1)
PYEOF
  docker run --rm --user "$(id -u):$(id -g)" -v "$P:$P:ro" -v "$HERE:$HERE:rw" \
    -v "$HOME/.ciel:$HOME/.ciel:ro" -e HOME=/tmp -w /tmp \
    -e REPRO_OUT="$O" -e _LLN_OVERRIDE_OPENROAD="$HERE/openroad_wrapper.sh" -e REAL_OPENROAD="$OR" \
    $IMG $PY -m librelane.steps run --id $id -c "$O/config.json" -i "$RUN/$step/state_in.json" \
      -o "$O/step" --condensed > "$O/run.log" 2>&1 || true
  # check: the legalised result must equal the run's own DEF for the step
  ok=1
  for sec in COMPONENTS PINS NETS; do
    if ! diff -q <(awk "/^$sec /,/^END $sec/" "$O/after_legalise.def") \
                 <(awk "/^$sec /,/^END $sec/" "$RUN/$step/tt_um_tiny_breakout.def") >/dev/null; then
      ok=0; echo "$step: $sec differs from the run"
    fi
  done
  [ $ok = 1 ] && echo "$step: after_legalise.def matches the run (components, pins, nets)"
done
