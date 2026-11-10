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

# hdmi_sources: hdl-util/hdmi's sources, as patched by prepare_hdmi, from ROOT
hdmi_sources() { ls "$BUILD"/hdmi/src/*.sv; }

# prepare_hdmi: copies hdl-util/hdmi's sources from the submodule into build/hdmi and applies
# third_party/hdl_util_hdmi.patch there; the submodule itself is left as upstream has it
prepare_hdmi() {
  local sub="$REL/third_party/hdmi"
  if [ ! -f "$sub/src/hdmi.sv" ]; then
    echo "No hdl-util/hdmi in $sub: run 'git submodule update --init $sub'" >&2
    exit 1
  fi
  rm -rf "$BUILD/hdmi"
  mkdir -p "$BUILD/hdmi"
  cp -R "$sub/src" "$BUILD/hdmi/"
  patch -s -d "$BUILD/hdmi" -p1 < "$REL/third_party/hdl_util_hdmi.patch"
}

# need_venv: stops with a hint if this board's .venv hasn't been set up
need_venv() {
  if [ ! -x "$VENV/bin/yowasp-yosys" ]; then
    echo "No tools in $VENV: set them up as README.md shows (Setup)" >&2
    exit 1
  fi
}
