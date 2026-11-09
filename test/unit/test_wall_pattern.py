# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for wall_pattern: the layout of the walls after a game's first.

Each wall is built the way brick_wall builds it: row 5 first, from an empty ring, then rows
0..4, each given the row before. Every level and every value of `random` is tried, which
takes well under a second.

The first test holds for any layout and should stay when you try a new one; the second checks
the current layout ("Aliens") against a model of it, and is the one to replace.
"""

import cocotb
from cocotb.triggers import Timer

from cocotb_run import run

FILL_ORDER = [5, 0, 1, 2, 3, 4]
LEVELS = [1, 2, 3]  # level 0, the first wall, is always full: brick_wall sees to that
VALUES = range(1, 32)  # the LFSR is never 0


async def build_wall(dut, level: int, value: int) -> list[int]:
    """The wall's rows 0..5 (top to bottom), each a bit mask with bit c for column c."""
    rows, prev = [0] * 6, 0  # an empty ring: the wall before was cleared
    dut.level.value = level
    dut.random.value = value
    for r in FILL_ORDER:
        dut.r.value = r
        dut.prev.value = prev
        await Timer(1, unit="ns")
        prev = rows[r] = int(dut.row.value)
    return rows


def bricks(rows: list[int]) -> int:
    return sum(bin(row).count("1") for row in rows)


@cocotb.test()
async def no_wall_is_empty(dut):
    """Any layout: every level and value gives at least one brick, or the level never ends."""
    for level in LEVELS:
        for value in VALUES:
            assert bricks(await build_wall(dut, level, value)) > 0, f"level {level}, random {value}"


@cocotb.test()
async def no_wall_repeats_the_first(dut):
    """Any layout: no wall is full, or a later level would look just like the first."""
    for level in LEVELS:
        for value in VALUES:
            rows = await build_wall(dut, level, value)
            assert bricks(rows) < 48, f"level {level}, random {value}"


def aliens(value: int) -> list[int]:
    """The current layout (see wall_pattern.sv): a mirrored seed row from `random`, never all
    four bricks, then each row grown from the one before by rule 150, or 182 when random[4] is
    set."""
    rule_182 = value >> 4 & 1
    half = [(value >> c & 1) | (c == 0 and rule_182) for c in range(4)]  # columns 0..3
    half[0] &= not (half[1] and half[2] and half[3])
    full = lambda h: sum(h[min(c, 7 - c)] << c for c in range(8))  # mirrored into 8 columns
    rows = [0] * 6
    rows[5] = full(half)
    for r in range(5):  # rows 0..4, each from the one before (row 0 from row 5)
        left, right = [half[0]] + half[:3], half[1:] + [half[3]]
        half = [(left[c] ^ half[c] ^ right[c]) | (left[c] & right[c] & rule_182) for c in range(4)]
        rows[r] = full(half)
    return rows


@cocotb.test()
async def the_walls_follow_the_aliens_rule(dut):
    """The current layout, exactly: the same walls at every level, 21 different ones over the
    31 values of `random`, of 20 to 32 bricks."""
    walls = set()
    for level in LEVELS:
        for value in VALUES:
            rows = await build_wall(dut, level, value)
            assert rows == aliens(value), f"level {level}, random {value}: {rows}"
            walls.add(tuple(rows))
    assert len(walls) == 21
    assert min(map(bricks, walls)) == 20 and max(map(bricks, walls)) == 32


def test_wall_pattern():
    run("wall_pattern", ["wall_pattern.sv"], "test_wall_pattern")
