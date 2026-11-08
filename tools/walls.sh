#!/bin/bash
# Usage: tools/walls.sh [--png FILE] [SRC_DIR]
# Every wall that wall_pattern.sv (in SRC_DIR, default src) builds after a game's first: each
# level and each value of the LFSR, built the way brick_wall builds it (row 5 first, from an
# empty ring, then rows 0..4, each given the row before). Prints each different wall once,
# with the inputs that give it and its brick count, then a summary; fails if any is empty.
# --png also draws them as the top of the game screen. A few seconds; needs Verilator.
# For a layout's cost, run tools/local_area.sh.
#
# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
. "$(dirname "$0")/common.sh"
PNG=""
if [ "${1:-}" = --png ]; then PNG=$(realpath -m "$2"); shift 2; fi
SRC=$(cd "${1:-$ROOT/src}" && pwd)
# Verilator from the local tools (test/README.md), with that environment's compiler, else PATH's
if [ -x "$ROOT/.tools/env/bin/verilator" ]; then export PATH="$ROOT/.tools/env/bin:$PATH"; fi
VERILATOR=verilator
W="$ROOT/build/walls"; rm -rf "$W"; mkdir -p "$W"
cat > "$W/main.cpp" <<'CPP'
#include "Vwall_pattern.h"
#include <cstdio>
int main() {
  Vwall_pattern m;
  const int order[6] = {5, 0, 1, 2, 3, 4};  // the ring's fill order
  for (int level = 1; level <= 3; level++)
    for (int random = 1; random < 32; random++) {
      int rows[6] = {}, prev = 0;  // an empty ring: the wall before was cleared
      for (int r : order) {
        m.r = r;
        m.prev = prev;
        m.level = level;
        m.random = random;
        m.eval();
        rows[r] = prev = m.row;
      }
      printf("%d %d", level, random);
      for (int row : rows) printf(" %d", row);
      printf("\n");
    }
}
CPP
"$VERILATOR" --cc --exe --build -Wno-fatal --top-module wall_pattern -Mdir "$W/obj" \
  "$SRC/wall_pattern.sv" "$W/main.cpp" > "$W/build.log" 2>&1 ||
  { echo "Verilator failed: see $W/build.log"; tail -5 "$W/build.log"; exit 1; }
"$W/obj/Vwall_pattern" > "$W/walls.txt"
"$ROOT/.venv/bin/python" - "$W/walls.txt" "$PNG" <<'PY'
import sys
from collections import defaultdict

lines = [list(map(int, l.split())) for l in open(sys.argv[1])]
walls = defaultdict(list)  # rows 0..5 -> [(level, random), ...]
for level, random, *rows in lines:
    walls[tuple(rows)].append((level, random))
bricks = lambda rows: sum(bin(r).count("1") for r in rows)
art = lambda row: "".join("#" if row >> c & 1 else "." for c in range(8))  # column 0 leftmost

def inputs(where):
    """The inputs giving a wall, compactly: the random values, by the levels that share them."""
    by_value = defaultdict(set)
    for level, random in where:
        by_value[random].add(level)
    groups = defaultdict(list)
    for random, levels in sorted(by_value.items()):
        groups[tuple(sorted(levels))].append(random)
    name = lambda ls: "all levels" if ls == (1, 2, 3) else "level " + ",".join(map(str, ls))
    return "; ".join(f"{name(ls)}: random {','.join(map(str, rs))}" for ls, rs in groups.items())

order = sorted(walls, key=lambda w: (bricks(w), w))
for i in range(0, len(order), 6):  # six walls side by side
    group = order[i:i + 6]
    for r in range(6):
        print("   ".join(art(w[r]) for w in group))
    print("   ".join(f"{bricks(w):>2} bricks" for w in group))
    print()
for n, w in enumerate(order, 1):
    print(f"{n:>2}. {bricks(w):>2} bricks  {inputs(walls[w])}")
counts = [bricks(w) for w in order]
print(f"\n{len(order)} different walls from {len(lines)} inputs, {min(counts)} to {max(counts)} "
      f"bricks; per level: " + ", ".join(
          f"{level}: {len({tuple(rows) for l, _, *rows in lines if l == level})}" for level in (1, 2, 3)))

if sys.argv[2]:  # the top of the game screen for each wall, in the game's colours
    from PIL import Image, ImageDraw
    lv = [0, 85, 170, 255]
    rgb = lambda b: (lv[b >> 4 & 3], lv[b >> 2 & 3], lv[b & 3])
    colours = [rgb(c) for c in (0b110000, 0b111000, 0b111100, 0b001100, 0b001011, 0b100011)]
    tw, th, per = 272, 92, 6
    sheet = Image.new("RGB", (per * (tw + 8) + 8, ((len(order) + per - 1) // per) * (th + 8) + 8))
    for k, w in enumerate(order):
        im = Image.new("RGB", (640, 480))
        d = ImageDraw.Draw(im)
        d.rectangle([64, 32, 575, 479], fill=rgb(1))
        for box in ([56, 24, 583, 31], [56, 24, 63, 479], [576, 24, 583, 479]):
            d.rectangle(box, fill=rgb(0b010101))
        for r in range(6):
            for c in range(8):
                if w[r] >> c & 1:
                    d.rectangle([64 * (c + 1) + 2, 16 * (r + 4) + 2, 64 * (c + 1) + 63, 16 * (r + 4) + 15],
                                fill=colours[r])
        tile = im.crop((48, 0, 592, 184)).resize((tw, th))
        sheet.paste(tile, (8 + (k % per) * (tw + 8), 8 + (k // per) * (th + 8)))
    sheet.save(sys.argv[2])
    print(f"drew {len(order)} walls in {sys.argv[2]}")

if min(counts) == 0:
    sys.exit("FAILED: an empty wall: its level would never end")
PY
