# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""The checks that a capture is faithful to the run. Each returns a result dict:
{"name": ..., "passed": True or False, "detail": ...}.
"""

import dataclasses
import difflib
import filecmp
import json

import dumps as dumps_mod
import logs

# Header titles that do not follow "Executing <NAME> pass", by command.
_TITLES = {
    "read_liberty": "Executing Liberty frontend",
    "read_verilog": "Executing Verilog-2005 frontend",
    "write_verilog": "Executing Verilog backend",
    "write_json": "Executing JSON backend",
    "stat": "Printing statistics",
}


# Headers a command may print after its own, at the top level, by command. hierarchy
# elaborates each module and announces it with a top-level header.
_INNER_TITLES = {
    "hierarchy": ("Executing AST frontend in derive mode",),
}


def names_command(title, command):
    """Whether a log header's title names the Yosys command it was printed for.

    For tee, the command is the one tee runs.
    """
    name = _run_command(command)[0]
    return title.startswith(_TITLES.get(name, f"Executing {name.upper()} pass"))


def _run_command(command):
    """The command itself, or for tee the command after tee's options."""
    if command[0] != "tee":
        return command
    i = 1
    while command[i].startswith(("-", "+")):
        # -o, -a and -s take an argument; -q and the +N/-N verbosity changes do not
        i += 2 if command[i] in ("-o", "-a", "-s") else 1
    return command[i:]


@dataclasses.dataclass
class Assignment:
    """Which dump shows the design after which numbered command of the log."""

    kept: list  # (header number, dump name): the dump after each command with a header
    unchanged: list  # (dump name, previous dump name): commands that print no header
    script_headers: list  # header numbers printed by the script between commands
    inner_headers: list  # (header number, command's header number): extra headers of a command
    problems: list  # anything that does not fit


def assign_dumps(events, records):
    """Matches a dump run's log events (logs.events) with the hook's records.

    Between one dump and the next, the log has: the script's own headers, recorded by the
    hook; then the command's header, which must name it; then any more headers the command
    printed. A command may print no header at all.
    """
    a = Assignment([], [], [], [], [])
    commands = [r for r in records if "command" in r]
    marks = [e for e in events if e[0] == "dump"]
    if len(marks) != len(commands):
        a.problems.append(f"{len(marks)} dumps in the log, {len(commands)} commands recorded")
        return a

    # The log's headers before each dump, and the script's headers before each command.
    segments, seg = [], []
    for e in events:
        if e[0] == "header":
            seg.append(e)
        else:
            segments.append((e[1], seg))
            seg = []
    for e in seg:
        a.problems.append(f"header {e[1]} comes after the last dump")
    script, pending = [], []
    for r in records:
        if "log_header" in r:
            pending.append(r["log_header"])
        else:
            script.append(pending)
            pending = []

    last_header, last_dump = 0, None
    for record, (marked, headers), expected in zip(commands, segments, script):
        name, command = record["dump"], record["command"]
        if headers:
            last_header = headers[-1][1]
        for message in expected:
            if not headers or headers[0][2] != message.strip():
                got = f"header {headers[0][1]} ({headers[0][2]})" if headers else "no header"
                a.problems.append(f"{got} is not the script's header {message.strip()!r}")
                return a
            a.script_headers.append(headers[0][1])
            headers = headers[1:]
        if marked != last_header:
            a.problems.append(f"dump {name} is marked under header {marked}, "
                              f"after header {last_header}")
        if not headers:
            a.unchanged.append((name, last_dump))
            continue
        own, title = headers[0][1], headers[0][2]
        if not names_command(title, command):
            a.problems.append(f"header {own} ({title}) does not name command {command[0]}")
        a.kept.append((own, name))
        allowed = _INNER_TITLES.get(_run_command(command)[0], ())
        for h in headers[1:]:
            if not h[2].startswith(allowed):
                a.problems.append(f"header {h[1]} ({h[2]}) is not expected inside command "
                                  f"{command[0]}")
            a.inner_headers.append((h[1], own))
        last_dump = name
    return a


def identical(name, a, b):
    """Whether two files are byte-identical."""
    same = filecmp.cmp(a, b, shallow=False)
    return {"name": name, "passed": same,
            "detail": "byte-identical" if same else f"{a} and {b} differ"}


def logs_equal(name, a, b, strip_dumps_from_b=False):
    """Whether two logs are equal after normalisation (logs.normalise).

    With strip_dumps_from_b, the second log's dump markers are taken out first.
    """
    text_a = a.read_text(encoding="utf-8")
    text_b = b.read_text(encoding="utf-8")
    if strip_dumps_from_b:
        text_b = logs.strip_dumps(text_b, text_a)
    lines_a = logs.normalise(text_a).split("\n")
    lines_b = logs.normalise(text_b).split("\n")
    if lines_a == lines_b:
        return {"name": name, "passed": True,
                "detail": f"{len(lines_a)} lines equal after normalisation"}
    diff = difflib.unified_diff(lines_a, lines_b, str(a), str(b), lineterm="", n=1)
    return {"name": name, "passed": False, "detail": "\n".join(list(diff)[:40])}


def statistics_agree(log_text, dump_paths, top):
    """Whether each statistics printout in the log matches the dump after that command.

    `dump_paths` maps header numbers to dump files. Compares cell counts by type in `top`.
    """
    numbers = [n for n, title in logs.top_level_headers(log_text)
               if title == "Printing statistics."]
    problems = []
    for n in numbers:
        if n not in dump_paths:
            problems.append(f"no dump after command {n}")
            continue
        found = dumps_mod.compare_counts(logs.statistics(log_text, n, top),
                                         dumps_mod.cell_counts(dumps_mod.load(dump_paths[n]), top))
        if found:
            problems.append(f"{n}: " + "; ".join(found))
    listed = ", ".join(map(str, numbers))
    return {"name": "dumps agree with the log's statistics", "passed": not problems,
            "detail": "; ".join(problems) if problems
            else f"printouts {listed}: cell counts by type equal"}


class _Object(list):
    """A JSON object as its (key, value) pairs, in file order."""


def _load_ordered(path):
    """A JSON file with every object kept as its pairs in order."""
    with open(path, encoding="utf-8") as f:
        return json.load(f, object_pairs_hook=_Object)


def _sort_module_attributes(tree):
    """`tree` with the attributes of each module under "modules" in sorted order."""
    out = _Object()
    for key, value in tree:
        if key == "modules":
            value = _Object(
                (name, _Object((k, _Object(sorted(v)) if k == "attributes" else v)
                               for k, v in module))
                for name, module in value)
        out.append((key, value))
    return out


def json_equal(name, a, b):
    """Whether two Yosys JSON files are equal, apart from the order of modules' attributes.

    Every other object must have its keys in the same order.
    """
    if filecmp.cmp(a, b, shallow=False):
        return {"name": name, "passed": True, "detail": "byte-identical"}
    same = _sort_module_attributes(_load_ordered(a)) == _sort_module_attributes(_load_ordered(b))
    return {"name": name, "passed": same,
            "detail": "equal, apart from the order of modules' attributes; not byte-identical"
            if same else f"{a} and {b} differ"}


def guarded(prove, *args):
    """The results of prove(*args), or one failed result if it cannot read its inputs."""
    try:
        return prove(*args)
    except ValueError as e:
        return [{"name": "proofs could run", "passed": False,
                 "detail": f"ValueError: {e}"}]
