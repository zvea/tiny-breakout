# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Reading Yosys logs: numbered headers, statistics printouts, dump markers, normalisation."""

import re

# A top-level header is a numbered line after a blank line, such as "12. Executing OPT pass.".
_HEADER = re.compile(r"(\d+)\. (.+)")

# The capture writes each dump inside its own log level, so its header is "N.1." under the
# current top-level number N. A dump is JSON, or RTLIL while the design has processes.
_DUMP_MARKER = re.compile(r"(\d+)\.1\. Executing (?:JSON|RTLIL) backend\.")
# The RTLIL backend logs one more line, with the file's name.
_RTLIL_FILENAME = re.compile(r"Output filename: .*")
# With RTLIL beside JSON, the RTLIL backend follows the JSON backend in the same log level,
# so its header is "N.2." under the same N.
_RTLIL_BESIDE = "{}.2. Executing RTLIL backend."


def top_level_headers(text):
    """The log's numbered top-level headers, as (number, title) pairs in order.

    Raises ValueError if the numbers do not count up from 1 without gaps.
    """
    headers = []
    for number, title in find_headers(text):
        if number != len(headers) + 1:
            raise ValueError(f"expected header {len(headers) + 1}, found {number}. {title}")
        headers.append((number, title))
    return headers


def find_headers(text):
    """(number, title) for each top-level header line, without checking the numbering."""
    lines = text.split("\n")
    found = []
    for i, line in enumerate(lines):
        m = _HEADER.fullmatch(line)
        if m and i > 0 and lines[i - 1] == "":
            found.append((int(m.group(1)), m.group(2)))
    return found


# In a statistics table, a count, then an area column (a number or "-") if the table has one,
# then the name. Names of cell types are indented further than the cell count's own line.
_STAT_ROW = re.compile(r"\s*(\d+)\s+(?:[-0-9.E+]+\s+)?(\S.*)")


def statistics(text, number, top):
    """Cell counts by type from the statistics printout under top-level header `number`.

    Reads the table of module `top`. Raises ValueError if the header is not a statistics
    printout, if it has no table for `top`, or if the counts by type do not add up to the
    table's cell count.
    """
    lines = text.split("\n")
    start = _header_line(lines, number)
    if lines[start] != f"{number}. Printing statistics.":
        raise ValueError(f"header {number} is not a statistics printout")
    for i in range(start + 1, len(lines)):
        if _HEADER.fullmatch(lines[i]):
            raise ValueError(f"no table for module {top} under header {number}")
        if lines[i] == f"=== {top} ===":
            start = i
            break
    else:
        raise ValueError(f"no table for module {top} under header {number}")
    total = None
    counts = {}
    for line in lines[start + 1:]:
        if _HEADER.fullmatch(line) or line.startswith("=== "):
            break
        m = _STAT_ROW.fullmatch(line)
        if total is None:
            if m and m.group(2) == "cells":
                total = int(m.group(1))
            continue
        if not m:
            break
        counts[m.group(2).strip()] = int(m.group(1))
    if total is None:
        raise ValueError(f"no cell count under header {number}")
    if sum(counts.values()) != total:
        raise ValueError(
            f"cell types under header {number} sum to {sum(counts.values())}, not {total}")
    return counts


def _header_line(lines, number):
    """The index of top-level header `number` in `lines`."""
    for i, line in enumerate(lines):
        m = _HEADER.fullmatch(line)
        if m and int(m.group(1)) == number and i > 0 and lines[i - 1] == "":
            return i
    raise ValueError(f"no header {number}")


def events(text):
    """Top-level headers and dump markers of a dump run's log, in order.

    A header is ("header", number, title). A dump is ("dump", number), where number is the
    top-level header it was written under.
    """
    found = []
    lines = text.split("\n")
    for i, line in enumerate(lines):
        if i == 0 or lines[i - 1] != "":
            continue
        m = _DUMP_MARKER.fullmatch(line)
        if m:
            found.append(("dump", int(m.group(1))))
            continue
        m = _HEADER.fullmatch(line)
        if m:
            found.append(("header", int(m.group(1)), m.group(2)))
    return found


def strip_dumps(text, reference):
    """A dump run's log with the dumps' lines taken out, to compare with `reference`.

    A dump's lines are its marker, the blank line before it, and for RTLIL the file name
    line. A dump written as JSON and RTLIL also has the RTLIL backend's header (N.2), the
    blank line before it and the file name line. Yosys prints the blank line before a
    marker only if the log does not already end with one. So when the dump is followed by a
    line that is not blank, the blank line may be the log's own. It is kept if the line
    before it is not blank, and `reference`, the same log without dumps, has a blank line
    there followed by the same line.
    """
    lines = text.split("\n")
    ref = reference.split("\n")
    kept = []
    i = 0
    while i < len(lines):
        if not (_DUMP_MARKER.fullmatch(lines[i]) and kept and kept[-1] == ""):
            kept.append(lines[i])
            i += 1
            continue
        number = _DUMP_MARKER.fullmatch(lines[i]).group(1)
        i = _after_backend(lines, i)
        if (i + 1 < len(lines) and lines[i] == ""
                and lines[i + 1] == _RTLIL_BESIDE.format(number)):
            i = _after_backend(lines, i + 1)
        kept.pop()
        # Restore the blank line only if the line before it is not blank, and the reference
        # has the blank line here, followed by the same line.
        k = len(kept)
        if (i < len(lines) and lines[i] != "" and kept[-1] != ""
                and k + 1 < len(ref) and ref[k] == "" and ref[k + 1] == lines[i]):
            kept.append("")
    return "\n".join(kept)


def _after_backend(lines, i):
    """The index after a dump's backend header at lines[i], and for RTLIL its file name."""
    rtlil = "RTLIL" in lines[i]
    i += 1
    if rtlil and i < len(lines) and _RTLIL_FILENAME.fullmatch(lines[i]):
        i += 1
    return i


# Normalisation: the differences allowed between the run's log and a capture's. Each rule is
# as narrow as it can be. Everything else must match exactly.
#
# 1. ABC's temporary folders have random six-character names. The run made them under /tmp.
#    The capture keeps them, so Yosys makes them in the working folder, named _tmp_yosys-abc-*.
#    Both kinds become ABC_TEMP_DIR.
_ABC_TEMP_DIR = re.compile(r"(?:/tmp/|_tmp_)yosys-abc-[A-Za-z0-9]{6}(?![A-Za-z0-9])")
# 2. Yosys reports removing those folders. The capture keeps them, so it does not. These two
#    exact lines are dropped.
_CLEANUP_LINES = {"Removing temp directory.", "Removing global temp directory."}
# 3. ABC prints how long some of its commands took. In lines from ABC, "time = 0.42 sec" (or
#    "Time =") becomes "time = <time> sec".
_ABC_TIME = re.compile(r"([Tt]ime =)\s+\d+\.\d+ sec")


def normalise(text):
    """The log with the differences above replaced or removed."""
    out = []
    for line in text.split("\n"):
        if line in _CLEANUP_LINES:
            continue
        line = _ABC_TEMP_DIR.sub("ABC_TEMP_DIR", line)
        if line.startswith("ABC: "):
            line = _ABC_TIME.sub(r"\1 <time> sec", line)
        out.append(line)
    return "\n".join(out)
