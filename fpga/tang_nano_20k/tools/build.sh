#!/bin/bash
# Builds the Tang Nano 20K bitstream, build/tn20k.fs: synthesis (yosys), place and route
# (nextpnr) and packing (apicula's gowin_pack). Logs are in build/.
# Usage: tools/build.sh [SEED]  (nextpnr's placement seed, default 1)
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/common.sh"
seed=${1:-1}

need_venv
cd "$ROOT"  # yowasp's tools see only the directory they start in, and below
prepare_hdmi

# The Gowin primitives first, as black boxes for both front ends. tn20k_top.v (plain Verilog,
# with them) goes through yosys's own front end; the SystemVerilog through yosys-slang, which
# reads hdl-util's unpacked-array ports. -j 1: yowasp's yosys (WebAssembly) has no threads.
# hdl-util's serializer picks its primitives by macro: SYNTHESIS (which slang defines) would
# take Xilinx's, so it is undefined, and GW_IDE selects Gowin's OSER10.
echo "Synthesis: $BUILD/synth.log"
"$VENV/bin/yowasp-yosys" -q -l "$BUILD/synth.log" -p "
  read_verilog -lib -specify +/gowin/cells_sim.v +/gowin/cells_xtra_gw2a.v
  read_slang -j 1 -U SYNTHESIS -D GW_IDE --top breakout_hdmi \
    $(game_sources | tr '\n' ' ') $(hdmi_sources | tr '\n' ' ') $REL/src/breakout_hdmi.sv
  read_verilog $REL/src/tn20k_top.v
  synth_gowin -family gw2a -top tn20k_top -json $BUILD/tn20k.json
" > /dev/null

# Timed at the pixel clock, which nearly everything runs on. The 126 MHz clock only drives the
# serialisers' fast side, which nextpnr doesn't time; clk_audio (48 kHz) passes trivially.
# nextpnr fails if timing does.
echo "Place and route: $BUILD/pnr.log"
"$VENV/bin/yowasp-nextpnr-himbaechel-gowin" -q -l "$BUILD/pnr.log" \
  --json "$BUILD/tn20k.json" --write "$BUILD/tn20k_pnr.json" \
  --device GW2AR-LV18QN88C8/I7 --vopt family=GW2A-18C --vopt cst="$REL/src/tn20k.cst" \
  --freq 25.2 --seed "$seed"
grep -E "Max frequency for clock" "$BUILD/pnr.log" | tail -2 | sed 's/^Info: */  /'

echo "Bitstream: $BUILD/tn20k.fs"
"$VENV/bin/gowin_pack" -d GW2A-18C -o "$BUILD/tn20k.fs" "$BUILD/tn20k_pnr.json"
