#!/bin/bash
# Usage: tutorials/physical-design/regenerate.sh [RUN_DIR]
# Remakes the tutorial's data from a harden run (default runs/exp_rowtail), then the page. The
# run is only read. LibreLane's container re-runs global placement stopped at intermediate
# states (gpl/), re-runs the steps that end in a legalisation to catch the layout just before
# it (split/), dumps the route guides after antenna repair (guides/) and the GDS (gds/); each
# re-run checks that its end state equals the run's own. Then extract.py writes data.json and
# build.py the page. About 20 minutes; needs Docker and the run's PDK under ~/.ciel.
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(git -C "$HERE" rev-parse --show-toplevel)
RUN=$(cd "${1:-$ROOT/runs/exp_rowtail}" && pwd)
IMG=ghcr.io/librelane/librelane:3.0.14
OR=/nix/store/acqm3cm6m4bj83ygn6ynjksl920zz9zx-openroad-2026-02-17-python3-3.13.9-env/bin/openroad
in_container() {
  docker run --rm --user "$(id -u):$(id -g)" -v "$ROOT:$ROOT" -v "$HOME/.ciel:$HOME/.ciel:ro" \
    -e HOME=/tmp -w /tmp "$@"
}
"$HERE/gpl/capture.sh" "$RUN"
"$HERE/split/run_repro.sh" "$RUN"
in_container -e IN_ODB="$(ls "$RUN"/*-openroad-repairantennas/1-openroad-diodeinsertion/*.odb)" \
  -e OUT_GUIDE="$HERE/guides/post_antenna.guide" $IMG $OR -exit -no_splash "$HERE/guides/dump_guides.tcl"
in_container $IMG sh -c 'exec $(ls -d /nix/store/*-python3-3.13.9-env/bin/python3 | head -1) "$@"' sh \
  "$HERE/gds/dump.py" "$RUN/final/gds/tt_um_tiny_breakout.gds" "$HERE/gds/gds.json"
"$ROOT/.venv/bin/python" "$HERE/extract.py" "$RUN" "$HERE/gpl" "$HERE/split" "$HERE/data.json"
"$ROOT/.venv/bin/python" "$HERE/build.py"
