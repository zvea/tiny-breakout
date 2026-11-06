# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for frame_rng: a 5-bit maximal-length LFSR advanced once per frame."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from cocotb_run import run


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.frame_tick.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def read(dut) -> int:
    await ReadOnly()
    value = int(dut.lfsr.value)
    await RisingEdge(dut.clk)
    return value


async def frame(dut):
    dut.frame_tick.value = 1
    await RisingEdge(dut.clk)
    dut.frame_tick.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def advances_only_on_frame_tick(dut):
    await start(dut)
    value = await read(dut)
    await ClockCycles(dut.clk, 20)
    assert await read(dut) == value, "changed without frame_tick"
    await frame(dut)
    assert await read(dut) != value, "did not advance on frame_tick"


@cocotb.test()
async def covers_all_31_nonzero_values(dut):
    await start(dut)
    seen = []
    for _ in range(31):
        seen.append(await read(dut))
        await frame(dut)
    assert sorted(seen) == list(range(1, 32)), "maximal-length sequence, never zero"
    assert await read(dut) == seen[0], "period 31"


@cocotb.test()
async def low_bits_are_nearly_uniform(dut):
    """Each 2-bit field takes every value 7 or 8 times per period (the game's dice)."""
    await start(dut)
    values = []
    for _ in range(31):
        values.append(await read(dut))
        await frame(dut)
    for shift in (0, 2):
        counts = [sum(((v >> shift) & 3) == k for v in values) for k in range(4)]
        assert all(c in (7, 8) for c in counts), f"bits [{shift + 1}:{shift}]: {counts}"


def test_frame_rng():
    run("frame_rng", ["frame_rng.sv"], "test_frame_rng")
