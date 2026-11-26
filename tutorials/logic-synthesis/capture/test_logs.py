# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Tests for logs.py, on small Yosys-style logs written for the tests."""

import pytest

import logs

LOG = """\
 Yosys 1.23 (git sha1 0abc123, cc 4.5)

1. Executing Verilog-2005 frontend: /src/a.sv
Parsing SystemVerilog input from `/src/a.sv' to AST representation.

2. Executing HIERARCHY pass (managing design hierarchy).

3. Executing AST frontend in derive mode using pre-parsed AST for module `\\top'.

3.1. Analyzing design hierarchy..
Top module:  \\top

4. Rerunning passes.

5. Printing statistics.

=== top ===

        +----------Local Count, excluding submodules.
        |
       12 wires
       14 wire bits
        3 ports
        5 port bits
        7 cells
        4   $_AND_
        2   $_DFF_P_
        1   $scopeinfo

6. Printing statistics.

=== top ===

        +----------Local Count, excluding submodules.
        |        +-Local Area, excluding submodules.
        |        |
       12        - wires
        3        - ports
        3  1.2E+03 cells
        1        -   $_MUX_
        2 9.87E+02   lib__dff_1

   Area for cell type $_MUX_ is unknown!

7. Executing ABC pass (technology mapping using ABC).
"""


def test_top_level_headers_in_order():
    assert logs.top_level_headers(LOG) == [
        (1, "Executing Verilog-2005 frontend: /src/a.sv"),
        (2, "Executing HIERARCHY pass (managing design hierarchy)."),
        (3, "Executing AST frontend in derive mode using pre-parsed AST for module `\\top'."),
        (4, "Rerunning passes."),
        (5, "Printing statistics."),
        (6, "Printing statistics."),
        (7, "Executing ABC pass (technology mapping using ABC)."),
    ]


def test_headers_need_a_blank_line_before_them():
    text = "\n1. Executing X pass.\nsome output\n2. Not a header\n\n2. Executing Y pass.\n"
    assert logs.top_level_headers(text) == [(1, "Executing X pass."), (2, "Executing Y pass.")]


def test_headers_must_count_up_from_one():
    with pytest.raises(ValueError, match="expected header 2"):
        logs.top_level_headers("\n1. Executing X pass.\n\n3. Executing Y pass.\n")


def test_statistics_with_counts_only():
    assert logs.statistics(LOG, 5, "top") == {"$_AND_": 4, "$_DFF_P_": 2, "$scopeinfo": 1}


def test_statistics_with_counts_and_areas():
    assert logs.statistics(LOG, 6, "top") == {"$_MUX_": 1, "lib__dff_1": 2}


def test_statistics_of_a_header_that_is_not_one():
    with pytest.raises(ValueError, match="header 2 is not a statistics printout"):
        logs.statistics(LOG, 2, "top")


def test_statistics_need_the_table_of_the_given_module():
    with pytest.raises(ValueError, match="no table for module other under header 5"):
        logs.statistics(LOG, 5, "other")


def test_statistics_whose_types_do_not_sum_to_the_cell_count():
    bad = LOG.replace("        4   $_AND_", "        3   $_AND_")
    with pytest.raises(ValueError, match="sum to 6, not 7"):
        logs.statistics(bad, 5, "top")


# The run keeps ABC's temporary files out of the way and removes them; the capture keeps them.
RUN_LOG = "ABC: + read_library /tmp/yosys-abc-Ab3dE9/stdcells.genlib \n" + """\
Removing temp directory.
Removing global temp directory.
9.1. Extracting gate netlist of module `\\top' to `/tmp/yosys-abc-Xy7Wq2/input.blif'..
ABC: Parsing finished successfully.  Parsing time =     0.42 sec
ABC: Memory =   21.50 MB. Time =     1.37 sec
"""
CAPTURE_LOG = "ABC: + read_library /tmp/yosys-abc-Kp4Lm8/stdcells.genlib \n" + """\
9.1. Extracting gate netlist of module `\\top' to `_tmp_yosys-abc-Rt5Uv6/input.blif'..
ABC: Parsing finished successfully.  Parsing time =     0.33 sec
ABC: Memory =   21.50 MB. Time =     0.91 sec
"""


def test_normalise_makes_run_and_capture_logs_equal():
    expected = (
        "ABC: + read_library ABC_TEMP_DIR/stdcells.genlib \n"
        "9.1. Extracting gate netlist of module `\\top' to `ABC_TEMP_DIR/input.blif'..\n"
        "ABC: Parsing finished successfully.  Parsing time = <time> sec\n"
        "ABC: Memory =   21.50 MB. Time = <time> sec\n"
    )
    assert logs.normalise(RUN_LOG) == expected
    assert logs.normalise(CAPTURE_LOG) == expected


@pytest.mark.parametrize("line", [
    "ABC: Memory =   21.51 MB.",  # a memory figure is not a timing
    "Time =     0.42 sec",  # timings are only replaced in ABC's output
    "Removing temp directory. ",  # only the exact cleanup lines are dropped
    "ABC: + read_blif /tmp/yosys-abc-Ab3dE/input.blif",  # a temp-dir name has six characters
    "Reading /tmp/other-Ab3dE9/x",  # other temporary paths are kept
    "Running ABC script: <abc-temp-dir>/abc.script",  # Yosys's own stand-in for the name
])
def test_normalise_leaves_other_lines_alone(line):
    assert logs.normalise(line + "\n") == line + "\n"


DUMP_LOG = """\
 Yosys 1.23

1. Executing Verilog-2005 frontend: /src/a.sv
Parsing SystemVerilog input.

1.1. Executing JSON backend.

2. Executing OPT pass (performing simple optimizations).

2.1. Executing OPT_EXPR pass (perform const folding).
Optimizing module top.

2.1. Executing RTLIL backend.
Output filename: /d/0002.il
[INFO] A line from the script.

2.1. Executing JSON backend.

3. Executing JSON backend.

3.1. Executing JSON backend.
"""


def test_events_list_headers_and_dumps_in_order():
    assert logs.events(DUMP_LOG) == [
        ("header", 1, "Executing Verilog-2005 frontend: /src/a.sv"),
        ("dump", 1),
        ("header", 2, "Executing OPT pass (performing simple optimizations)."),
        ("dump", 2),
        ("dump", 2),
        ("header", 3, "Executing JSON backend."),
        ("dump", 3),
    ]


PLAIN_LOG = """\
 Yosys 1.23

1. Executing Verilog-2005 frontend: /src/a.sv
Parsing SystemVerilog input.

2. Executing OPT pass (performing simple optimizations).

2.1. Executing OPT_EXPR pass (perform const folding).
Optimizing module top.
[INFO] A line from the script.

3. Executing JSON backend.
"""


def test_strip_dumps_gives_the_log_without_them():
    assert logs.strip_dumps(DUMP_LOG, PLAIN_LOG) == PLAIN_LOG


def test_strip_dumps_keeps_a_blank_line_the_log_had_before_a_dump():
    # Yosys prints a blank line before a header only if the log does not end with one
    # already. So before a dump followed by a plain line, the blank line may be the log's.
    plain = PLAIN_LOG.replace("top.\n[INFO]", "top.\n\n[INFO]")
    assert logs.strip_dumps(DUMP_LOG, plain) == plain


def test_strip_dumps_keeps_no_blank_line_before_a_header():
    # The blank line before a dump followed by a header is always the dump's own.
    plain = PLAIN_LOG.replace("input.\n\n2.", "input.\n2.")
    assert logs.strip_dumps(DUMP_LOG, plain) == PLAIN_LOG


def test_strip_dumps_restores_no_blank_line_after_another_one():
    # Two blank lines before a dump: the log is not what Yosys writes, so nothing is restored.
    dump = " Yosys 1.23\n\n1. Executing X pass.\nx\n\n\n1.1. Executing JSON backend.\ny\n"
    plain = " Yosys 1.23\n\n1. Executing X pass.\nx\n\n\ny\n"
    assert logs.strip_dumps(dump, plain) == " Yosys 1.23\n\n1. Executing X pass.\nx\n\ny\n"
