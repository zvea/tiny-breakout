# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Builds the black-box scenario tests (scenarios.cpp) with Verilator and runs each one.

The scenarios come in two tiers (see the table at the end of scenarios.cpp):

- cheap: controls, demo, losing_every_ball and opening, ~3 min in parallel; run all the time
- milestone: long_game, a game from a new game to the third wall, ~25 min; run at milestones

    pytest test/system -n auto               # the cheap tier, in parallel (pytest-xdist)
    pytest test/system -n auto --milestone   # both tiers
    pytest test/system -m milestone          # the long game alone
    pytest test/system                       # the cheap tier, one after another

The design's source files are read from info.yaml, so this stays in step with the flow.
Needs Verilator 4.x: sim/play/sim.h uses its one-eval-per-clock trick.
"""

import fcntl
import os
import shutil
import subprocess
import uuid
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


def scenarios() -> list[tuple[str, bool]]:
    """Each scenario's name, and whether it is in the milestone tier, from the table at the end
    of scenarios.cpp (only its lines: tables of other things elsewhere look the same)."""
    text = (HERE / "scenarios.cpp").read_text()
    table = text[text.index("const Scenario scenarios[] = {"):]
    table = table[: table.index("\n};")]
    return [
        (line.split('"')[1], "MILESTONE" in line)
        for line in table.splitlines()
        if line.strip().startswith('{"')
    ]


# Each scenario's time limit, by tier, only so that one that hangs fails instead of holding up
# the run (the scenarios' own waits are capped, and their long rounds stop at the first
# failure). The cheap tier's longest, lost_at_speed, can play 8 rounds and pass: about 14,000
# frames, 12 minutes at 50 ms a frame, and up to 20,000 if autoplay is slow to clear its bricks,
# or more on a busy machine. So 30 minutes may be a slow run as well as a hang. The long game
# takes about 25, so 2 hours is a hang.
CHEAP_TIMEOUT = 30 * 60
MILESTONE_TIMEOUT = 2 * 60 * 60

# Identifies this test run: pytest-xdist gives all its workers the same one
RUN_ID = os.environ.get("PYTEST_XDIST_TESTRUNUID") or uuid.uuid4().hex


@pytest.fixture(scope="session")
def scenarios_binary() -> Path:
    """Builds once per test run. With pytest-xdist every worker asks: the first builds under a
    lock, the others wait for it and reuse the build."""
    BUILD.mkdir(exist_ok=True)
    with open(BUILD / "build.lock", "w") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        stamp = BUILD / "built-for-run"
        if not (stamp.exists() and stamp.read_text() == RUN_ID):
            _build()
            stamp.write_text(RUN_ID)
    return BUILD / "Vtt_um_tiny_breakout"


def _build() -> None:
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


@pytest.mark.parametrize(
    "name",
    [pytest.param(name, marks=pytest.mark.milestone) if milestone else name
     for name, milestone in scenarios()],
)  # fmt: skip
def test_scenario(request: pytest.FixtureRequest, scenarios_binary: Path, name: str):
    milestone = request.node.get_closest_marker("milestone") is not None
    timeout = MILESTONE_TIMEOUT if milestone else CHEAP_TIMEOUT
    try:
        result = subprocess.run(
            [scenarios_binary, name], capture_output=True, text=True, timeout=timeout
        )
    except subprocess.TimeoutExpired as e:
        # What it printed before it was stopped (bytes here, even with text=True)
        output = e.stdout.decode(errors="replace") if e.stdout else ""
        pytest.fail(
            f"{name} still running after {timeout // 60} min, stopped\n{output}", pytrace=False
        )
    print(result.stdout)
    assert result.returncode == 0, result.stdout + result.stderr
