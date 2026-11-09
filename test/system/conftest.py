# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""The scenarios' two tiers, and one pytest-xdist worker per scenario.

Without options only the cheap tier runs: the scenarios marked milestone (the long game) are
deselected. --milestone runs both tiers; -m picks by mark as usual, so -m milestone runs the
long game alone.

With pytest-xdist, `-n auto` gives every scenario that will run a worker of its own. The
scenarios take from half a minute to half an hour. With fewer than twice as many tests as
workers, pytest-xdist hands them all out round-robin before any start, so two long ones can
end up on one worker, one after the other, and nothing can take the second away. One worker
per scenario avoids that: the run takes as long as the longest scenario, or the total work
divided among the cores, whichever is more.
"""

import pytest

from test_scenarios import scenarios


def pytest_addoption(parser):
    parser.addoption(
        "--milestone", action="store_true",
        help="run the milestone tier (the long game) as well as the cheap one",
    )  # fmt: skip


def pytest_configure(config):
    config.addinivalue_line(
        "markers", "milestone: the long game, run only with --milestone (or -m milestone)"
    )


def _all_tiers(config) -> bool:
    return config.getoption("--milestone", default=False) or bool(config.getoption("markexpr"))


def pytest_collection_modifyitems(config, items):
    if _all_tiers(config):
        return
    milestone = [item for item in items if item.get_closest_marker("milestone")]
    if milestone:
        config.hook.pytest_deselected(items=milestone)
        items[:] = [item for item in items if not item.get_closest_marker("milestone")]


def pytest_xdist_auto_num_workers(config):
    return sum(_all_tiers(config) or not milestone for _, milestone in scenarios())
