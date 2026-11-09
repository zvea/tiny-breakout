#!/bin/bash
# Shared by the scripts in tools/: the repo root, the design's sources (in info.yaml order),
# the sky130 cell library, and the .venv's Python and yosys.
#
# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
PY="$ROOT/.venv/bin/python"  # the project's .venv, for every script
YOSYS="$ROOT/.venv/bin/yowasp-yosys"

# sources [REV]: those of git revision REV (its own info.yaml), or of the working tree
sources() {
  if [ -n "${1:-}" ]; then git -C "$ROOT" show "$1:info.yaml"; else cat "$ROOT/info.yaml"; fi |
    sed -n 's/^ *- "\([A-Za-z0-9_]*\.sv\)".*/\1/p'
}

# The typical-corner library of sky130's high-density cells, from $PDK_ROOT or ciel's default:
# the PDK version LibreLane uses if that is there, else the first by path. Prints nothing if
# there is none, so that callers (under set -euo pipefail) reach their own message.
liberty() {
  local libs want
  libs=$({ find "${PDK_ROOT:-$HOME/.ciel}" -path '*sky130A/libs.ref/sky130_fd_sc_hd/lib/sky130_fd_sc_hd__tt_025C_1v80.lib' \
    2>/dev/null || true; } | sort)
  want=$(sed -n 's/^sky130: *//p' "$ROOT"/.venv/lib/python*/site-packages/librelane/pdk_hashes.yaml 2>/dev/null || true)
  # The first non-empty line (reading all of it: no early exit to break the pipe)
  { if [ -n "$want" ]; then grep -F "/$want/" <<<"$libs" || true; fi; echo "$libs"; } |
    awk 'NF && !done { print; done = 1 }'
}

# Writes copies of a top module with pairs of register declarations swapped: synthesis
# results shift with declaration order alone, so area comparisons average over these.
# Usage: orderings TOP_FILE N OUT_PREFIX  ->  OUT_PREFIX0.sv .. OUT_PREFIX{N-1}.sv
orderings() {
  "$PY" - "$1" "$2" "$3" <<'PY'
import re, sys
top, n, out = sys.argv[1], int(sys.argv[2]), sys.argv[3]
s = open(top).read()
pairs = [None,
         (r"  logic ball_left;[^\n]*\n", r"  logic ball_up;[^\n]*\n"),
         (r"  logic       serving;[^\n]*\n", r"  logic \[1:0\] lives;[^\n]*\n"),
         (r"  logic \[4:0\] speed_level;[^\n]*\n", r"  logic \[1:0\] lives;[^\n]*\n"),
         (r"  logic \[7:0\] paddle_[xc]4;\n", r"  logic \[9:0\] ball_x;[^\n]*\n")]  # x4 before ef9f82d
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
