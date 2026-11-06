# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Builds the black-box scenario tests (scenarios.cpp) with Verilator and runs each one.

    pytest test/system

The design's source files are read from info.yaml, so this stays in step with the flow.
Needs Verilator 4.x: sim/play/sim.h uses its one-eval-per-clock trick.
"""

import shutil
import subprocess
from pathlib import Path

import pytest
import yaml

HERE = Path(__file__).resolve().parent
ROOT = HERE.parent.parent
BUILD = HERE / "build"
LOCAL_VERILATOR = ROOT / ".tools" / "v4" / "bin" / "verilator"


def sources() -> list[Path]:
    info = yaml.safe_load((ROOT / "info.yaml").read_text())
    return [ROOT / "src" / f for f in info["project"]["source_files"]]


def scenario_names() -> list[str]:
    return [
        line.split('"')[1]
        for line in (HERE / "scenarios.cpp").read_text().splitlines()
        if line.strip().startswith('{"')
    ]


@pytest.fixture(scope="session")
def scenarios_binary() -> Path:
    verilator = str(LOCAL_VERILATOR) if LOCAL_VERILATOR.exists() else shutil.which("verilator")
    assert verilator, "Verilator 4.x not found"
    cmd = [
        verilator, "--cc", "--build", "-O3", "-Wno-fatal",
        "--x-assign", "fast", "--x-initial", "fast",
        "-CFLAGS", f"-O3 -I{ROOT / 'sim' / 'play'}",
        "--exe", str(HERE / "scenarios.cpp"), *map(str, sources()),
        "--top-module", "tt_um_tiny_breakout", "-Mdir", str(BUILD), "-j", "8",
    ]  # fmt: skip
    result = subprocess.run(cmd, capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    return BUILD / "Vtt_um_tiny_breakout"


@pytest.mark.parametrize("name", scenario_names())
def test_scenario(scenarios_binary: Path, name: str):
    result = subprocess.run([scenarios_binary, name], capture_output=True, text=True, timeout=900)
    print(result.stdout)
    assert result.returncode == 0, result.stdout + result.stderr
