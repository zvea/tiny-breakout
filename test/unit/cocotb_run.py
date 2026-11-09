# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Builds one module and runs a cocotb test module against it.

Used by the pytest entry points in the test_*.py files next to this one:

    pytest test/unit               # Verilator (default): ~70 s
    SIM=icarus pytest test/unit    # Icarus Verilog, as in CI: ~5.5 min (brick_wall alone ~4)
"""

import os
import shutil
from pathlib import Path

from cocotb_tools.runner import get_results, get_runner

UNIT_DIR = Path(__file__).resolve().parent
ROOT = UNIT_DIR.parent.parent
SRC_DIR = ROOT / "src"
TOOLS_BIN = ROOT / ".tools" / "env" / "bin"  # local simulator installs, used if none on PATH


def run(toplevel: str, sources: list[str], test_module: str) -> None:
    """Builds `sources` (packages first) and runs `test_module`. A source is a path relative
    to src/, such as a file name there, or an absolute path, such as a testbench in this
    directory, str(UNIT_DIR / "brick_wall_tb.sv")."""
    sim = os.environ.get("SIM", "verilator")
    executable = {"verilator": "verilator", "icarus": "iverilog"}[sim]
    if shutil.which(executable) is None and TOOLS_BIN.is_dir():
        os.environ["PATH"] = f"{TOOLS_BIN}{os.pathsep}{os.environ['PATH']}"
    build_dir = UNIT_DIR / "sim_build" / f"{toplevel}_{sim}"
    runner = get_runner(sim)
    runner.build(
        sources=[SRC_DIR / s for s in sources],  # an absolute s stays as it is
        hdl_toplevel=toplevel,
        build_dir=build_dir,
        always=True,
        timescale=("1ns", "1ps"),
    )
    results = runner.test(
        hdl_toplevel=toplevel,
        test_module=test_module,
        build_dir=build_dir,
        test_dir=UNIT_DIR,
    )
    num_tests, num_failed = get_results(results)
    assert num_tests > 0, f"no cocotb tests ran for {toplevel}"
    assert num_failed == 0, f"{num_failed} of {num_tests} cocotb tests failed for {toplevel}"
