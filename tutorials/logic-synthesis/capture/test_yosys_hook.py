# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Tests for yosys_hook.py, with a stand-in for Yosys's Python module that records calls."""

import yosys_hook


class FakeModule:
    def __init__(self, name, processes=False):
        self.name = name
        self.processes = processes

    def clone(self):
        return FakeModule(self.name + "'", self.processes)

    def has_processes(self):
        return self.processes


class FakeYs:
    """Records, in order, the calls the hook makes into Yosys."""

    def __init__(self):
        calls = self.calls = []

        class Design:
            def __init__(self, modules=()):
                # Yosys's Python module cannot return modules(), only the modules_ dict.
                self.modules_ = {m.name: m for m in modules}

            def add(self, module):
                self.modules_[module.name] = module

            def run_pass(self, *command):
                calls.append(("run_pass", self, command))

            def sort(self):
                calls.append(("sort", self))

        class Pass:
            @staticmethod
            def call(design, command):
                calls.append(("Pass.call", design, list(command)))

        self.Design = Design
        self.Pass = Pass

    def log_push(self):
        self.calls.append(("log_push",))

    def log_pop(self):
        self.calls.append(("log_pop",))

    def log_header(self, design, message):
        self.calls.append(("log_header", design, message))


def test_abc_keeps_its_temporary_files():
    ys = FakeYs()
    yosys_hook.install(ys)
    d = ys.Design()
    d.run_pass("abc", "-script", "x.abc")
    d.run_pass("opt", "-fast")
    assert ys.calls == [
        ("run_pass", d, ("abc", "-nocleanup", "-script", "x.abc")),
        ("run_pass", d, ("opt", "-fast")),
    ]


def test_no_dumps_without_a_dump_folder():
    ys = FakeYs()
    yosys_hook.install(ys)
    ys.Design([FakeModule("top")]).run_pass("opt")
    assert [c[0] for c in ys.calls] == ["run_pass"]


def test_a_dump_after_every_command_from_a_copy_in_its_own_log_level():
    ys = FakeYs()
    records = []
    yosys_hook.install(ys, dump_dir="/d", record=records.append)
    d = ys.Design([FakeModule("top"), FakeModule("cell")])
    d.run_pass("opt_expr")
    d.run_pass("tee", "-o", "r.rpt", "stat")
    names = [c[0] for c in ys.calls]
    # The copy is sorted, so a dump does not depend on the order objects were made in.
    assert names == ["run_pass", "sort", "log_push", "Pass.call", "log_pop"] * 2
    for sort, call, path in zip([ys.calls[1], ys.calls[6]], [ys.calls[3], ys.calls[8]],
                                ["/d/0001.json", "/d/0002.json"]):
        _, copy, command = call
        assert sort[1] is copy
        assert command == ["write_json", path]
        assert copy is not d
        assert list(copy.modules_) == ["top'", "cell'"]
    assert records == [
        {"command": ["opt_expr"], "dump": "0001.json"},
        {"command": ["tee", "-o", "r.rpt", "stat"], "dump": "0002.json"},
    ]


def test_log_headers_from_the_script_are_recorded_and_still_printed():
    ys = FakeYs()
    records = []
    yosys_hook.install(ys, dump_dir="/d", record=records.append)
    d = ys.Design()
    ys.log_header(d, "Rerunning OPT passes.")
    assert ys.calls == [("log_header", d, "Rerunning OPT passes.")]
    assert records == [{"log_header": "Rerunning OPT passes."}]


def test_a_design_with_processes_is_dumped_as_rtlil():
    # Yosys's JSON cannot hold processes, which exist until the proc passes have run.
    ys = FakeYs()
    records = []
    yosys_hook.install(ys, dump_dir="/d", record=records.append)
    ys.Design([FakeModule("top", processes=True), FakeModule("cell")]).run_pass("hierarchy")
    assert ys.calls[3][2] == ["write_rtlil", "/d/0001.il"]
    assert records == [{"command": ["hierarchy"], "dump": "0001.il"}]
