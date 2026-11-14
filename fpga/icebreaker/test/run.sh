#!/bin/bash
# Runs the simulation test (tb_breakout_vga.sv) with Verilator: the one on PATH, else the
# project's .tools/env one (see test/README.md at the top of the repo), as the unit tests do.
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/../tools/common.sh"

if ! command -v verilator > /dev/null && [ -x "$ROOT/.tools/env/bin/verilator" ]; then
  PATH="$ROOT/.tools/env/bin:$PATH"
fi
command -v verilator > /dev/null || { echo "No Verilator: see README.md" >&2; exit 1; }

cd "$ROOT"
mkdir -p "$BUILD"
rm -rf "$BUILD/sim"  # from scratch: a build by another Verilator would point at its files

# Warnings don't stop the test (-Wno-fatal): the game is linted by CI's test workflow
verilator --binary --timing -j 0 -O2 --top-module tb_breakout_vga \
  --Mdir "$BUILD/sim" -o tb -Wno-fatal \
  $(game_sources) $REL/src/breakout_vga.sv $REL/test/tb_breakout_vga.sv \
  > "$BUILD/sim.log" 2>&1 || { tail -30 "$BUILD/sim.log"; exit 1; }
"$BUILD/sim/tb" | tee "$BUILD/test.log"
grep -qx PASS "$BUILD/test.log"
