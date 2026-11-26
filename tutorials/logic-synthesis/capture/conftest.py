# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""The slow tests, which run LibreLane's container, run only with --slow."""

from pathlib import Path
import subprocess

import pytest

HERE = Path(__file__).resolve().parent


def _default_run():
    """runs/exp_rowtail in the main checkout, which holds the runs (worktrees do not)."""
    common = subprocess.run(["git", "-C", HERE, "rev-parse", "--path-format=absolute",
                             "--git-common-dir"], capture_output=True, text=True).stdout.strip()
    return str(Path(common).parent / "runs" / "exp_rowtail") if common else ""


def pytest_addoption(parser):
    parser.addoption("--slow", action="store_true",
                     help="also run the slow tests, which re-run synthesis in the container")
    parser.addoption("--capture-run", default=_default_run(),
                     help="the run the slow tests capture (default: runs/exp_rowtail)")


def pytest_configure(config):
    config.addinivalue_line("markers", "slow: runs LibreLane's container; needs --slow")


def pytest_collection_modifyitems(config, items):
    if config.getoption("--slow"):
        return
    slow = [item for item in items if item.get_closest_marker("slow")]
    if slow:
        config.hook.pytest_deselected(items=slow)
        items[:] = [item for item in items if not item.get_closest_marker("slow")]
