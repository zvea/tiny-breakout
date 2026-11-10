#!/bin/bash
# Builds the iCE40UP5K bitstream locally, as CI's ice40 workflow does: with Tiny
# Tapeout's own flow (tt-support-tools' tt_fpga.py), its wrapper and its pins for the TT FPGA
# breakout board. Placed and routed against info.yaml's clock_hz, with the action's seed.
# The flow writes to the top-level build/ (02-nextpnr.log, tt_um_tiny_breakout.bin, ...).
# Usage: tools/build.sh [SEED]  (nextpnr's placement seed, default 10 as CI pins it)
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)
cd "$ROOT"

if [ ! -f tt/tt_fpga.py ]; then
  echo "No tt-support-tools in tt/: see tools/README.md at the top of the repo (Setup)" >&2
  exit 1
fi
for tool in yosys nextpnr-ice40 icepack; do
  command -v "$tool" > /dev/null || {
    echo "No $tool on PATH: install oss-cad-suite (see README.md)" >&2
    exit 1
  }
done

hz=$(sed -n 's/^ *clock_hz: *\([0-9][0-9]*\).*/\1/p' info.yaml)
[ -n "$hz" ] || { echo "No clock_hz in info.yaml" >&2; exit 1; }
export TT_FPGA_FREQ=$(awk -v hz="$hz" 'BEGIN { print hz / 1e6 }')
export TT_FPGA_SEED=${1:-10}

.venv/bin/python tt/tt_tool.py --create-user-config
.venv/bin/python tt/tt_fpga.py harden
# nextpnr's last Max frequency line is the one after routing
grep -E 'Max frequency for clock' build/02-nextpnr.log | tail -1 | sed 's/^Info: */  /'
