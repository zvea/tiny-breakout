#!/bin/bash
# Tests tools/flow_avg.sh, in a scratch repo where flow.sh is a stand-in that takes 2 s and
# reports a utilisation from the ordering's number: the means are printed right, the three
# orderings run at the same time (all start before any ends), a failed ordering stops it with
# that ordering's output, and an interrupt (Ctrl-C) stops it and everything it started.
# Usage: tools/test/flow_avg_test.sh
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
errors=0
fail() { echo "FAIL: $*"; errors=$((errors + 1)); }

mkdir -p "$T/repo/tools" "$T/repo/src"
cp "$ROOT/tools/flow_avg.sh" "$ROOT/tools/common.sh" "$T/repo/tools/"
cp "$ROOT"/src/*.sv "$T/repo/src/"
ln -s "$ROOT/.venv" "$T/repo/.venv"
# The stand-in: "flow.sh repair TAG SRC_DIR". Ordering i reports 80+i and 79+i; it logs when it
# starts and ends, and fails if its tag is $FAIL_TAG.
cat > "$T/repo/tools/flow.sh" <<'EOF'
#!/bin/bash
tag=$2; i=${tag##*_o}
echo "start $i $(date +%s.%N)" >> "$T/log"
if [ -n "${HANG:-}" ]; then  # a long job in a foreground child, as flow.sh runs LibreLane
  bash -c 'echo "child $1 $$" >> "$T/log"; exec sleep 60' _ "$i"
fi
sleep 2
echo "end $i $(date +%s.%N)" >> "$T/log"
if [ "$tag" = "${FAIL_TAG:-}" ]; then echo "$tag: FLOW FAILED (see runs/exp_$tag.log)"; exit 1; fi
echo "$tag: TT utilisation 8$i.00 %"
echo "$tag: utilisation after repair $((79 + i)).00 %"
EOF
chmod +x "$T/repo/tools/flow.sh"
export T

# The means, and the orderings at the same time
out=$("$T/repo/tools/flow_avg.sh" demo "$T/repo/src") || fail "exit status $? with no failure"
want="demo: TT utilisation           80.00  81.00  82.00   mean 81.00
demo: utilisation after repair 79.00  80.00  81.00   mean 80.00"
[ "$out" = "$want" ] || fail "output:
$out
expected:
$want"
last_start=$(awk '$1 == "start" { print $3 }' "$T/log" | sort -n | tail -1)
first_end=$(awk '$1 == "end" { print $3 }' "$T/log" | sort -n | head -1)
started=$(awk '$1 == "start"' "$T/log" | wc -l)
[ "$started" = 3 ] || fail "$started orderings started, not 3"
awk -v s="$last_start" -v e="$first_end" 'BEGIN { exit !(s < e) }' ||
  fail "the orderings ran one after another (last start $last_start, first end $first_end)"

# A failed ordering: a non-zero exit status, naming it and showing its output
rm -f "$T/log"
if out=$(FAIL_TAG=demo_o1 "$T/repo/tools/flow_avg.sh" demo "$T/repo/src"); then
  fail "exit status 0 with ordering 1 failed"
fi
grep -q "ordering 1 failed" <<<"$out" || fail "the failure doesn't name ordering 1: $out"
grep -q "demo_o1: FLOW FAILED" <<<"$out" || fail "the failure doesn't show flow.sh's output: $out"

# An interrupt, as Ctrl-C sends it to the terminal's foreground process group: flow_avg stops
# with status 130, and no flow.sh or child of one is left running. (Job control in this test
# gives flow_avg its own process group, as a shell started from a terminal has.)
rm -f "$T/log"
set -m
HANG=1 "$T/repo/tools/flow_avg.sh" demo "$T/repo/src" > "$T/int.out" 2>&1 &
pid=$!
set +m
for _ in $(seq 50); do [ "$(grep -c '^child' "$T/log" 2>/dev/null)" = 3 ] && break; sleep 0.1; done
kill -INT -- "-$pid"
status=0
for _ in $(seq 50); do kill -0 "$pid" 2>/dev/null || break; sleep 0.1; done
if kill -0 "$pid" 2>/dev/null; then
  fail "still running 5 s after the interrupt"; kill -KILL -- "-$pid" 2>/dev/null || true
else
  wait "$pid" || status=$?
  [ "$status" = 130 ] || fail "exit status $status after the interrupt, not 130"
fi
sleep 0.5
left=$(awk '$1 == "child" { print $3 }' "$T/log" | while read -r c; do
  kill -0 "$c" 2>/dev/null && echo "$c"; done || true)
[ -z "$left" ] || { fail "flows' children still running after the interrupt: $left"; kill $left; }
pgrep -f "$T/repo/tools/flow.sh" > /dev/null && fail "a flow.sh still running after the interrupt"

[ "$errors" = 0 ] || { echo "$errors failure(s)"; exit 1; }
echo "flow_avg: PASS"
