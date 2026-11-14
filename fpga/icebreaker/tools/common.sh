#!/bin/bash
# Shared by build.sh and test/run.sh: paths, the game's sources, and the tools.
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
BOARD=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOT=$(cd "$BOARD/../.." && pwd)
VENV="$BOARD/.venv"  # this board's own tools (tools/requirements.txt)
REL=fpga/icebreaker  # BOARD from ROOT: yowasp's tools take paths relative to where they start
BUILD="$REL/build"

# game_sources: the game's sources, from info.yaml (in its order: packages first), from ROOT
game_sources() {
  sed -n 's/^ *- "\([A-Za-z0-9_]*\.sv\)".*/src\/\1/p' "$ROOT/info.yaml"
}

# need_venv: stops with a hint if this board's .venv hasn't been set up
need_venv() {
  if [ ! -x "$VENV/bin/yowasp-yosys" ]; then
    echo "No tools in $VENV: set them up as README.md shows (Setup)" >&2
    exit 1
  fi
}
