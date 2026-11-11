#!/bin/bash
# Usage: tools/warnings.sh RUN_DIR [--update]
# The warnings of a hardened run (RUN_DIR, e.g. runs/exp_TAG), which the flow reports but does
# not fail on. Prints their counts; fails on the ones that must never happen (an inferred
# latch, a critical disconnected pin, a clock pin over its slew limit, an antenna violation
# left after routing: LibreLane only reports those); and lists any kind of message in
# warning.log that tools/warnings.ref does not have, for a person to judge.
# --update rewrites warnings.ref from this run, once its new messages have been looked at.
#
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
set -euo pipefail
. "$(dirname "$0")/common.sh"
usage() { sed -n '2,7p' "$0"; exit 2; }
case ${1:-} in ''|-*) usage ;; esac  # RUN_DIR comes first
case $# in
  1) ;;
  2) [ "$2" = --update ] || { echo "unknown argument: $2"; usage; } ;;
  *) usage ;;
esac
RUN=$(cd "$1" && pwd)
[ -f "$RUN/final/metrics.json" ] || { echo "no final/metrics.json in $RUN: not a hardened run"; exit 1; }
"$PY" - "$RUN" "$ROOT/tools/warnings.ref" "${2:-}" <<'PY'
import glob, json, re, sys

run, ref_path, mode = sys.argv[1], sys.argv[2], sys.argv[3]
m = json.load(open(f"{run}/final/metrics.json"))

# Clock pins over their slew limit at any corner: flip-flop clock pins and clock-buffer pins,
# from the slew section of the sign-off timing checks
clock_slew = set()
sta_dirs = sorted(glob.glob(f"{run}/*-openroad-stapostpnr"))
if not sta_dirs:
    sys.exit(f"FAILED: no *-openroad-stapostpnr directory in {run}, so no sign-off timing checks to read")
sta = sta_dirs[-1]
for rpt in glob.glob(f"{sta}/*/checks.rpt"):
    text = open(rpt).read()
    if "\nmax slew\n" in text:
        section = re.split(r"\n(?:max fanout|max capacitance|max slew violation count)",
                           text.split("\nmax slew\n", 1)[1])[0]
        for pin in re.findall(r"^(\S+/\S+)\s+[\d.]+\s+[\d.]+\s+-[\d.]+ \(VIOLATED\)", section, re.M):
            if pin.endswith("/CLK") or pin.startswith(("clkbuf_", "clkload")):
                clock_slew.add(pin)

metrics = {
    "max slew violations": "design__max_slew_violation__count",
    "max fanout violations": "design__max_fanout_violation__count",
    "max capacitance violations": "design__max_cap_violation__count",
    "lint warnings": "design__lint_warning__count",
    "inferred latches": "design__inferred_latch__count",
    "critical disconnected pins": "design__critical_disconnected_pin__count",
    "antenna violating nets": "antenna__violating__nets",
    "antenna violating pins": "antenna__violating__pins",
}
counts = {k: m.get(key, "missing") for k, key in metrics.items()}
counts["clock pins over slew limit"] = len(clock_slew)
print("warnings: " + ", ".join(f"{k} {v}" for k, v in counts.items()))
# Antenna violations: the check after detailed routing, on the final wires. Global routing's
# repair can warn on the way ("Unable to repair antennas on net with diodes", in warnings.ref)
# and still clear them with a diode; this is what says it did.
must_be_zero = ("inferred latches", "critical disconnected pins", "clock pins over slew limit",
                "antenna violating nets", "antenna violating pins")
failed = [k for k in must_be_zero if counts[k] and counts[k] != "missing"]
# A metric LibreLane no longer reports (renamed in an upgrade, say) would otherwise pass unseen
failed += [f"metric {key} missing from metrics.json (renamed? update tools/warnings.sh)"
           for key in metrics.values() if key not in m]

# Kinds of message: without timestamps, numbers (counts, paths with versions) or the list of
# corners that follows "violations found in the following corners"
def kinds(path):
    out = set()
    for line in open(path):
        line = re.sub(r"^\[\d+:\d+:\d+\]\s*", "", line.rstrip())
        line = re.sub(r"\s+\S+\.py:\d+$", "", line)
        if not line or re.match(r"^\*\s+\w+_\w+$", line):
            continue
        line = re.sub(r"(?<![\w.])/(?:[^\s/]+/)+", "", line)  # paths: file names only
        out.add(re.sub(r"\d+", "N", line))
    return out

seen = kinds(f"{run}/warning.log")
if mode == "--update":
    open(ref_path, "w").write("".join(k + "\n" for k in sorted(seen)))
    print(f"wrote {len(seen)} kinds of message to tools/warnings.ref")
else:
    known = set(open(ref_path).read().splitlines())
    new = sorted(seen - known)
    for k in new:
        print(f"  NEW: {k}")
    if not new:
        print("warning.log: no new kinds of message")
if failed:
    print("FAILED: " + ", ".join(failed))
    sys.exit(1)
PY
