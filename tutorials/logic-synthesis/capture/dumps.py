# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Reading the capture's dumps: Yosys JSON netlists of the design after each command."""

import collections
import gzip
import json
from pathlib import Path


def load(path):
    """A dump file, plain or gzipped (by its .gz suffix), as parsed JSON."""
    path = Path(path)
    opener = gzip.open if path.suffix == ".gz" else open
    with opener(path, "rt", encoding="utf-8") as f:
        return json.load(f)


def cell_counts(dump, module):
    """The number of cells of each type in one module of a dump."""
    cells = dump["modules"][module]["cells"]
    return dict(collections.Counter(cell["type"] for cell in cells.values()))


def compare_counts(log_counts, dump_counts):
    """The cell types whose counts differ, as readable lines in type order. Empty if none."""
    found = []
    for t in sorted(set(log_counts) | set(dump_counts)):
        a, b = log_counts.get(t, 0), dump_counts.get(t, 0)
        if a != b:
            found.append(f"{t}: log {a}, dump {b}")
    return found
