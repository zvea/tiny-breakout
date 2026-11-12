#!/bin/bash
# Usage: test/formal/prove.sh [NAME...]
# Runs the formal proofs in test/formal: NAME.sv for each NAME given, else every .sv there.
# Each is a proof by induction (yosys's SAT-based temporal induction, no external solver) that
# its top module, named after its file, satisfies its asserts under its assumes. A proof's file
# says what it needs:
#   // sources: FILE ...                the design files it reads (`chip`: all of info.yaml's)
#   (* connect = "INSTANCE.SIGNAL" *)   on a wire: driven by that signal inside an instance,
#                                       as yosys has no hierarchical references
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
. "$(dirname "$0")/../../tools/common.sh"
cd "$ROOT"
[ -x "$YOSYS" ] || YOSYS=yowasp-yosys  # without the .venv (as in CI): pip's, on the PATH
mkdir -p build/formal

if [ $# -gt 0 ]; then names=("$@"); else names=($(cd test/formal && ls *.sv | sed 's/\.sv$//')); fi

for name in "${names[@]}"; do
  file=test/formal/$name.sv
  [ -f "$file" ] || { echo "$name: no $file"; exit 2; }
  sources=$(sed -n 's|^// sources: ||p' "$file")
  [ -n "$sources" ] || { echo "$name: no '// sources:' line in $file"; exit 2; }
  [ "$sources" = chip ] && sources=$(for f in $(sources); do printf 'src/%s ' "$f"; done)
  connections=$(sed -n 's|.*(\* *connect *= *"\([^"]*\)" *\*).*[] ]\([A-Za-z_][A-Za-z0-9_]*\);.*|connect -nounset -set \2 \1|p' "$file")
  log=build/formal/$name.log
  "$YOSYS" -q -l "$log" -p "
    read_verilog -sv -formal $sources $file
    hierarchy -check -top $name
    proc
    flatten
    cd $name
    chformal -lower
    $connections
    memory
    opt -fast
    sat -tempinduct -prove-asserts -set-assumes -maxsteps 4
  " > /dev/null || { echo "$name: FAILED (see $log)"; exit 1; }
  grep -q 'Induction step proven: SUCCESS' "$log" || { echo "$name: not proven (see $log)"; exit 1; }
  echo "$name: proven"
done
