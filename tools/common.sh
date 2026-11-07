#!/bin/bash
# Shared by the scripts in tools/: the repo root, the design's sources (in info.yaml order),
# the sky130 cell library and the local yosys.
#
# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
YOSYS="$ROOT/.venv/bin/yowasp-yosys"

sources() { sed -n 's/^ *- "\([A-Za-z0-9_]*\.sv\)".*/\1/p' "$ROOT/info.yaml"; }

# The typical-corner library of sky130's high-density cells, from $PDK_ROOT or ciel's default
liberty() {
  find "${PDK_ROOT:-$HOME/.ciel}" -path '*sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib' \
    2>/dev/null | head -1
}

# Writes copies of a top module with pairs of register declarations swapped: synthesis
# results shift with declaration order alone, so area comparisons average over these.
# Usage: orderings TOP_FILE N OUT_PREFIX  ->  OUT_PREFIX0.sv .. OUT_PREFIX{N-1}.sv
orderings() {
  python3 - "$1" "$2" "$3" <<'PY'
import re, sys
top, n, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = open(top).read()
pairs = [None,
         (r"  logic ball_left;[^\n]*\n", r"  logic ball_up;[^\n]*\n"),
         (r"  logic       serving;[^\n]*\n", r"  logic \[1:0\] lives;[^\n]*\n"),
         (r"  logic \[4:0\] speed_level;[^\n]*\n", r"  logic \[1:0\] lives;[^\n]*\n"),
         (r"  logic \[7:0\] paddle_x4;\n", r"  logic \[9:0\] ball_x;[^\n]*\n")]
for i in range(n):
    t = s
    if pairs[i % len(pairs)]:
        ma, mb = (re.search(p, t) for p in pairs[i % len(pairs)])
        if not (ma and mb):
            sys.exit(f"orderings: no match for {pairs[i % len(pairs)]} in {top}: update tools/common.sh")
        a, b = ma.group(0), mb.group(0)
        t = t.replace(a, "\0").replace(b, a).replace("\0", b)
    open(f"{out}{i}.sv", "w").write(t)
PY
}
