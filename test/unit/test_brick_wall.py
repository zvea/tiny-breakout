# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for brick_wall: 8 x 6 bricks of 64 x 16 px at x 64..575, y 64..159.

The beam position is driven directly, so any pixel can be probed without video timing.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from cocotb_run import run

COLS, ROWS = 8, 6
ALL = [(r, c) for r in range(ROWS) for c in range(COLS)]


def centre(r: int, c: int) -> tuple[int, int]:
    return 64 * (1 + c) + 32, 16 * (4 + r) + 8


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.refill.value = 0
    dut.clear.value = 0
    dut.h_pos.value = 0
    dut.v_pos.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def probe(dut, x: int, y: int) -> dict[str, int]:
    """Puts the beam at (x, y) and reads the combinational outputs."""
    dut.h_pos.value = x
    dut.v_pos.value = y
    await ReadOnly()
    out = {n: int(getattr(dut, n).value) for n in ("brick_px", "brick_row", "over_columns", "empty")}
    await RisingEdge(dut.clk)
    return out


async def pulse(dut, name: str, x: int = 0, y: int = 0):
    """One-clock pulse on `clear` or `refill` with the beam at (x, y)."""
    dut.h_pos.value = x
    dut.v_pos.value = y
    getattr(dut, name).value = 1
    await RisingEdge(dut.clk)
    getattr(dut, name).value = 0
    await RisingEdge(dut.clk)


async def standing(dut) -> set[tuple[int, int]]:
    return {(r, c) for r, c in ALL if (await probe(dut, *centre(r, c)))["brick_px"]}


@cocotb.test()
async def full_wall_after_reset(dut):
    await start(dut)
    for r, c in ALL:
        out = await probe(dut, *centre(r, c))
        assert out["brick_px"] == 1, f"brick {r},{c} missing"
        assert out["brick_row"] == r, f"brick {r},{c} reports row {out['brick_row']}"
    assert (await probe(dut, 100, 100))["empty"] == 0


@cocotb.test()
async def gaps_and_surroundings_are_not_bricks(dut):
    await start(dut)
    for r, c in ALL:
        x, y = centre(r, c)
        for gx in (x - 32, x - 31):  # 2-px gap on the left edge
            assert (await probe(dut, gx, y))["brick_px"] == 0, f"left gap of {r},{c}"
        for gy in (y - 8, y - 7):  # 2-px gap on the top edge
            assert (await probe(dut, x, gy))["brick_px"] == 0, f"top gap of {r},{c}"
        assert (await probe(dut, x - 30, y - 6))["brick_px"] == 1, f"corner of {r},{c}"
    for x, y in [(32, 100), (600, 100), (300, 40), (300, 63), (300, 160), (300, 400)]:
        assert (await probe(dut, x, y))["brick_px"] == 0, f"({x}, {y}) is outside the wall"


@cocotb.test()
async def clear_removes_only_the_brick_under_the_beam(dut):
    rng = random.Random(2)
    await start(dut)
    model = set(ALL)
    for r, c in rng.sample(ALL, 12):
        await pulse(dut, "clear", *centre(r, c))
        model.discard((r, c))
        assert await standing(dut) == model, f"after clearing {r},{c}"
    await pulse(dut, "clear", 300, 300)  # beam outside the wall: nothing to clear
    assert await standing(dut) == model


@cocotb.test()
async def empty_after_last_brick_then_refill(dut):
    await start(dut)
    for i, (r, c) in enumerate(ALL):
        assert (await probe(dut, 0, 0))["empty"] == 0, f"empty with {len(ALL) - i} bricks left"
        await pulse(dut, "clear", *centre(r, c))
    assert (await probe(dut, 0, 0))["empty"] == 1
    assert await standing(dut) == set()
    await pulse(dut, "refill")
    assert (await probe(dut, 0, 0))["empty"] == 0
    assert await standing(dut) == set(ALL)


@cocotb.test()
async def over_columns_spans_the_wall_width(dut):
    await start(dut)
    for y in (10, 100, 300):
        for x in (0, 63, 64, 300, 575, 576, 639):
            expected = int(64 <= x <= 575)
            assert (await probe(dut, x, y))["over_columns"] == expected, f"x={x}, y={y}"


def test_brick_wall():
    run("brick_wall", ["brick_wall.sv"], "test_brick_wall")
