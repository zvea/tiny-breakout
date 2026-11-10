#!/bin/bash
# Shared by build.sh and test/run.sh: paths, the game's and hdl-util's sources, and the tools.
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
BOARD=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
ROOT=$(cd "$BOARD/../.." && pwd)
VENV="$BOARD/.venv"  # this board's own tools (tools/requirements.txt)
REL=fpga/tang_nano_20k  # BOARD from ROOT: yowasp's tools take paths relative to where they start
BUILD="$REL/build"

# game_sources: the game's sources, from info.yaml (in its order: packages first), from ROOT
game_sources() {
  sed -n 's/^ *- "\([A-Za-z0-9_]*\.sv\)".*/src\/\1/p' "$ROOT/info.yaml"
}

# hdmi_sources: hdl-util/hdmi's sources, from the submodule, from ROOT
HDMI="$REL/third_party/hdmi"
hdmi_sources() { ls "$HDMI"/src/*.sv; }

# need_hdmi: stops with a hint if the hdl-util/hdmi submodule hasn't been checked out
need_hdmi() {
  if [ ! -f "$HDMI/src/hdmi.sv" ]; then
    echo "No hdl-util/hdmi in $HDMI: run 'git submodule update --init $HDMI'" >&2
    exit 1
  fi
}

# need_venv: stops with a hint if this board's .venv hasn't been set up
need_venv() {
  if [ ! -x "$VENV/bin/yowasp-yosys" ]; then
    echo "No tools in $VENV: set them up as README.md shows (Setup)" >&2
    exit 1
  fi
}
