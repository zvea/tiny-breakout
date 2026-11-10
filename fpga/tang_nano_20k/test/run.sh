#!/bin/bash
# Runs the simulation test (tb_breakout_hdmi.sv) with Verilator: the one on PATH, else the
# project's .tools/env one (see test/README.md at the top of the repo), as the unit tests do.
# Usage: test/run.sh [FRAMES]  (the demo's length, default 400: about 7 s of play)
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../tools/common.sh"
frames=${1:-400}

if ! command -v verilator > /dev/null && [ -x "$ROOT/.tools/env/bin/verilator" ]; then
  PATH="$ROOT/.tools/env/bin:$PATH"
fi
command -v verilator > /dev/null || { echo "No Verilator: see README.md" >&2; exit 1; }

cd "$ROOT"
prepare_hdmi  # the same patched hdl-util as the build
rm -rf "$BUILD/sim"  # from scratch: a build by another Verilator would point at its files

# Warnings don't stop the test (-Wno-fatal): hdl-util has lint warnings of its own, and the
# game is linted by CI's test workflow
verilator --binary --timing -j 0 -O2 --top-module tb_breakout_hdmi \
  --Mdir "$BUILD/sim" -o tb -Wno-fatal \
  $(game_sources) $(hdmi_sources) $REL/src/breakout_hdmi.sv $REL/test/tb_breakout_hdmi.sv \
  > "$BUILD/sim.log" 2>&1 || { tail -30 "$BUILD/sim.log"; exit 1; }
"$BUILD/sim/tb" +frames="$frames" | tee "$BUILD/test.log"
grep -qx PASS "$BUILD/test.log"
