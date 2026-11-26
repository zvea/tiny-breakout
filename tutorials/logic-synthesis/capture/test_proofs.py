# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Tests for proofs.py, on small logs, records and dumps written for the tests."""

import json

import pytest

import proofs


@pytest.mark.parametrize("title, command", [
    ("Executing OPT_EXPR pass (perform const folding).", ["opt_expr"]),
    ("Executing OPT_CLEAN pass (remove unused cells and wires).", ["opt_clean", "-purge"]),
    ("Executing Liberty frontend: /lib/x.lib", ["read_liberty", "-lib", "/lib/x.lib"]),
    ("Executing Verilog-2005 frontend: /src/a.sv", ["read_verilog", "-sv", "/src/a.sv"]),
    ("Executing Verilog backend.", ["write_verilog", "-noattr", "out.v"]),
    ("Executing JSON backend.", ["write_json", "out.json"]),
    ("Printing statistics.", ["stat"]),
    ("Printing statistics.", ["tee", "-o", "r.rpt", "stat", "-liberty", "x.lib"]),
    ("Executing CHECK pass (checking for obvious problems).", ["tee", "-q", "-o", "c", "check"]),
    ("Printing statistics.", ["tee", "-s", "result", "stat"]),
    ("Printing statistics.", ["tee", "-a", "r.rpt", "+1", "stat"]),
    ("Printing statistics.", ["tee", "-2", "stat"]),
])
def test_header_names_command(title, command):
    assert proofs.names_command(title, command)


@pytest.mark.parametrize("title, command", [
    ("Executing OPT pass (performing simple optimizations).", ["opt_expr"]),
    ("Executing OPT_EXPR pass (perform const folding).", ["opt"]),
    ("Printing statistics.", ["tee", "-o", "stat", "check"]),
])
def test_header_does_not_name_command(title, command):
    assert not proofs.names_command(title, command)


def H(n, title):
    return ("header", n, title)


def D(n):
    return ("dump", n)


def test_assign_dumps_in_the_simple_case():
    events = [H(1, "Executing Liberty frontend: x.lib"), D(1), H(2, "Executing OPT pass."), D(2)]
    records = [{"command": ["read_liberty", "x.lib"], "dump": "0001.json"},
               {"command": ["opt"], "dump": "0002.json"}]
    a = proofs.assign_dumps(events, records)
    assert a.problems == []
    assert a.kept == [(1, "0001.json"), (2, "0002.json")]
    assert a.unchanged == [] and a.script_headers == [] and a.inner_headers == []


def test_assign_dumps_with_headers_from_the_script_inside_commands_and_none():
    events = [
        H(1, "Executing HIERARCHY pass (managing design hierarchy)."),
        H(2, "Executing AST frontend in derive mode using pre-parsed AST for module `\\top'."),
        D(2),
        D(2),  # rename prints no header
        H(3, "Rerunning passes."),
        H(4, "Executing OPT_EXPR pass (perform const folding)."),
        D(4),
    ]
    records = [
        {"command": ["hierarchy", "-top", "top"], "dump": "0001.json"},
        {"command": ["rename", "-top", "top"], "dump": "0002.json"},
        {"log_header": "Rerunning passes."},
        {"command": ["opt_expr"], "dump": "0003.json"},
    ]
    a = proofs.assign_dumps(events, records)
    assert a.problems == []
    assert a.kept == [(1, "0001.json"), (4, "0003.json")]
    assert a.unchanged == [("0002.json", "0001.json")]
    assert a.script_headers == [3]
    assert a.inner_headers == [(2, 1)]


def test_assign_dumps_with_a_script_header_before_a_command_without_one():
    events = [H(1, "Executing OPT pass."), D(1), H(2, "Rerunning OPT passes."), D(2)]
    records = [{"command": ["opt"], "dump": "0001.json"},
               {"log_header": "Rerunning OPT passes."},
               {"command": ["select", "-clear"], "dump": "0002.json"}]
    a = proofs.assign_dumps(events, records)
    assert a.problems == []
    assert a.kept == [(1, "0001.json")]
    assert a.unchanged == [("0002.json", "0001.json")]
    assert a.script_headers == [2]


def test_assign_dumps_reports_an_unexpected_header_inside_a_command():
    # A command the hook did not see would show up as an extra header of the one before.
    events = [H(1, "Executing OPT pass."), H(2, "Executing CHECK pass."), D(2)]
    a = proofs.assign_dumps(events, [{"command": ["opt"], "dump": "0001.json"}])
    assert a.problems == ["header 2 (Executing CHECK pass.) is not expected inside command opt"]


def test_assign_dumps_allows_the_derive_header_only_inside_hierarchy():
    events = [H(1, "Executing OPT pass."),
              H(2, "Executing AST frontend in derive mode using pre-parsed AST for module `\\t'."),
              D(2)]
    a = proofs.assign_dumps(events, [{"command": ["opt"], "dump": "0001.json"}])
    assert a.problems == ["header 2 (Executing AST frontend in derive mode using pre-parsed AST "
                          "for module `\\t'.) is not expected inside command opt"]


def test_assign_dumps_reports_a_header_that_does_not_name_its_command():
    events = [H(1, "Executing OPT pass."), D(1)]
    a = proofs.assign_dumps(events, [{"command": ["opt_expr"], "dump": "0001.json"}])
    assert a.problems == ["header 1 (Executing OPT pass.) does not name command opt_expr"]


def test_assign_dumps_reports_unequal_numbers_of_dumps_and_commands():
    events = [H(1, "Executing OPT pass."), D(1), D(1)]
    a = proofs.assign_dumps(events, [{"command": ["opt"], "dump": "0001.json"}])
    assert a.problems == ["2 dumps in the log, 1 commands recorded"]


def test_assign_dumps_reports_a_dump_marker_under_the_wrong_number():
    events = [H(1, "Executing OPT pass."), D(2)]
    a = proofs.assign_dumps(events, [{"command": ["opt"], "dump": "0001.json"}])
    assert a.problems == ["dump 0001.json is marked under header 2, after header 1"]


def test_assign_dumps_reports_a_script_header_missing_from_the_log():
    events = [H(1, "Executing OPT pass."), D(1)]
    records = [{"log_header": "Rerunning OPT passes."},
               {"command": ["opt"], "dump": "0001.json"}]
    a = proofs.assign_dumps(events, records)
    assert a.problems == ["header 1 (Executing OPT pass.) is not the script's header "
                          "'Rerunning OPT passes.'"]


def test_assign_dumps_reports_headers_after_the_last_dump():
    events = [H(1, "Executing OPT pass."), D(1), H(2, "Executing CHECK pass.")]
    a = proofs.assign_dumps(events, [{"command": ["opt"], "dump": "0001.json"}])
    assert a.problems == ["header 2 comes after the last dump"]


# File-level proofs, on small files in a temporary folder.

def write(path, text):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(text)
    return path


def test_identical_files(tmp_path):
    a = write(tmp_path / "a" / "x.v", "module x; endmodule\n")
    b = write(tmp_path / "b" / "x.v", "module x; endmodule\n")
    c = write(tmp_path / "c" / "x.v", "module y; endmodule\n")
    assert proofs.identical("same", a, b) == {"name": "same", "passed": True,
                                              "detail": "byte-identical"}
    result = proofs.identical("same", a, c)
    assert not result["passed"] and "differ" in result["detail"]


def test_logs_equal_after_normalisation(tmp_path):
    a = write(tmp_path / "a.log", "\n1. Executing X pass.\nABC: Time =   0.2 sec\n")
    b = write(tmp_path / "b.log", "\n1. Executing X pass.\nABC: Time =   0.3 sec\n")
    c = write(tmp_path / "c.log", "\n1. Executing Y pass.\nABC: Time =   0.3 sec\n")
    assert proofs.logs_equal("log", a, b)["passed"]
    result = proofs.logs_equal("log", a, c)
    assert not result["passed"]
    assert "-1. Executing X pass." in result["detail"]
    assert "+1. Executing Y pass." in result["detail"]


STAT_LOG = """\
 Yosys

1. Executing OPT pass.

2. Printing statistics.

=== top ===

        3 cells
        2   $_AND_
        1   $_NOT_

"""


def dump_file(path, types):
    cells = {f"c{i}": {"type": t} for i, t in enumerate(types)}
    return write(path, json.dumps({"modules": {"top": {"cells": cells}}}))


def test_statistics_agree(tmp_path):
    dumps = {2: dump_file(tmp_path / "002.json", ["$_AND_", "$_NOT_", "$_AND_"])}
    result = proofs.statistics_agree(STAT_LOG, dumps, "top")
    assert result == {"name": "dumps agree with the log's statistics", "passed": True,
                      "detail": "printouts 2: cell counts by type equal"}


def test_statistics_disagree(tmp_path):
    dumps = {2: dump_file(tmp_path / "002.json", ["$_AND_", "$_NOT_", "$_NOT_"])}
    result = proofs.statistics_agree(STAT_LOG, dumps, "top")
    assert not result["passed"]
    assert "2: $_AND_: log 2, dump 1; $_NOT_: log 1, dump 2" in result["detail"]


def test_statistics_without_a_dump(tmp_path):
    result = proofs.statistics_agree(STAT_LOG, {}, "top")
    assert not result["passed"] and "no dump after command 2" in result["detail"]


def test_json_equal(tmp_path):
    a = write(tmp_path / "a.json", '{"modules": {"m": {"attributes": {"p": "1", "q": "2"}}}}')
    b = write(tmp_path / "b.json", '{"modules": {"m": {"attributes": {"q": "2", "p": "1"}}}}')
    c = write(tmp_path / "c.json", '{"modules": {"m": {"attributes": {"q": "3", "p": "1"}}}}')
    assert proofs.json_equal("j", a, a) == {"name": "j", "passed": True,
                                            "detail": "byte-identical"}
    assert proofs.json_equal("j", a, b) == {
        "name": "j", "passed": True,
        "detail": "equal, apart from the order of modules' attributes; not byte-identical"}
    assert not proofs.json_equal("j", a, c)["passed"]


def test_json_equal_keeps_every_other_key_order(tmp_path):
    a = write(tmp_path / "a.json", '{"modules": {"m": {"ports": {"p": 1, "q": 2}}}}')
    b = write(tmp_path / "b.json", '{"modules": {"m": {"ports": {"q": 2, "p": 1}}}}')
    c = write(tmp_path / "c.json", '{"modules": {"m": {}, "n": {}}}')
    d = write(tmp_path / "d.json", '{"modules": {"n": {}, "m": {}}}')
    assert not proofs.json_equal("j", a, b)["passed"]
    assert not proofs.json_equal("j", c, d)["passed"]


def test_guarded_turns_a_parsing_error_into_a_failed_result():
    def prove():
        raise ValueError("no header 7")
    assert proofs.guarded(prove) == [{"name": "proofs could run", "passed": False,
                                      "detail": "ValueError: no header 7"}]


def test_guarded_passes_results_through():
    assert proofs.guarded(lambda x: [x], 5) == [5]
