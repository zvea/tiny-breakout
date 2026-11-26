# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Runs LibreLane's synthesis script inside Yosys, with two changes for the capture.

Usage, in LibreLane's container:
    yosys -y yosys_hook.py -- <the arguments LibreLane gave its script>

Environment:
    CAPTURE_LIBRELANE_SCRIPT  path of LibreLane's synthesize.py (required)
    CAPTURE_DUMP_DIR          folder for dumps; no dumps if unset

The changes:
- Both ABC calls get -nocleanup, so ABC's temporary files are kept.
- With a dump folder, the design is written after every command the script runs: as JSON,
  or as RTLIL while it has processes (until the proc passes), which JSON cannot hold.
  The script's own log headers and each command are recorded in commands.jsonl there.

A dump must not change what follows. So it writes a copy of the design, sorted by name, and
it writes it inside a log level of its own, so the log's top-level numbering stays the same.
"""

import importlib.util
import json
import os
import sys


def install(ys, dump_dir=None, record=None):
    """Wraps the script's way of running commands in Yosys's Python module `ys`.

    `record` takes one dict per event. It is used only when there is a dump folder.
    """
    run_pass = ys.Design.run_pass
    count = 0

    def hooked_run_pass(self, *command):
        nonlocal count
        if command and command[0] == "abc":
            command = ("abc", "-nocleanup", *command[1:])
        run_pass(self, *command)
        if dump_dir is not None:
            count += 1
            name = f"{count:04d}"
            name += dump(ys, self, os.path.join(dump_dir, name))
            record({"command": list(command), "dump": name})

    ys.Design.run_pass = hooked_run_pass

    if dump_dir is not None:
        log_header = ys.log_header

        def hooked_log_header(design, message, *args):
            record({"log_header": message})
            return log_header(design, message, *args)

        ys.log_header = hooked_log_header


def dump(ys, design, path):
    """Writes a copy of `design` to `path` plus a suffix, inside a log level of its own.

    The copy is written as Yosys JSON, or as RTLIL while it has processes, which JSON cannot
    hold. Returns the suffix: ".json" or ".il".
    """
    copy = ys.Design()
    for module in design.modules_.values():
        copy.add(module.clone())
    # Sorted by name, so the file does not depend on the order objects were made in.
    copy.sort()
    if any(m.has_processes() for m in copy.modules_.values()):
        backend, suffix = "write_rtlil", ".il"
    else:
        backend, suffix = "write_json", ".json"
    ys.log_push()
    try:
        ys.Pass.call(copy, [backend, path + suffix])
    finally:
        ys.log_pop()
    return suffix


def main():
    script = os.environ["CAPTURE_LIBRELANE_SCRIPT"]
    dump_dir = os.environ.get("CAPTURE_DUMP_DIR")
    # The script imports its neighbours, such as ys_common, which sets up run_pass.
    sys.path.insert(0, os.path.dirname(script))
    import ys_common

    record = None
    if dump_dir is not None:
        log = open(os.path.join(dump_dir, "commands.jsonl"), "w", encoding="utf-8")

        def record(event):
            log.write(json.dumps(event) + "\n")
            log.flush()

    install(ys_common.ys, dump_dir, record)
    spec = importlib.util.spec_from_file_location("synthesize", script)
    synthesize = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(synthesize)
    synthesize.synthesize()


if __name__ == "__main__":
    main()
