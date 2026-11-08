# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""With pytest-xdist, `-n auto` gives every scenario a worker of its own.

The scenarios take from seconds to over ten minutes. With fewer than twice as many tests as
workers, pytest-xdist hands them all out round-robin before any start, so two long ones can
end up on one worker, one after the other, and nothing can take the second away. One worker
per scenario avoids that: the run takes as long as the longest scenario, or the total work
divided among the cores, whichever is more.
"""

from test_scenarios import scenario_names


def pytest_xdist_auto_num_workers(config):
    return len(scenario_names())
