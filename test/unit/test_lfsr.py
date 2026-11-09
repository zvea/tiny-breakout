# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for lfsr: the game's 5-bit LFSR (x^5 + x^3 + 1), stepping once per frame."""

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
    value = int(dut.value.value)
    await RisingEdge(dut.clk)
    return value


def lfsr_states(n: int) -> list[int]:
    """The LFSR's value at each of the first n frames after reset (seed 1)."""
    states, s = [], 1
    for _ in range(n):
        states.append(s)
        s = ((s << 1) & 0x1F) | (((s >> 4) ^ (s >> 2)) & 1)
    return states


@cocotb.test()
async def steps_only_at_frame_tick_through_all_31_non_zero_values(dut):
    assert sorted(set(lfsr_states(31))) == list(range(1, 32))
    await start(dut)
    for expected in lfsr_states(40):
        for _ in range(3):  # steady between frame_ticks
            assert await read(dut) == expected
        dut.frame_tick.value = 1
        await RisingEdge(dut.clk)
        dut.frame_tick.value = 0


def test_lfsr():
    run("lfsr", ["lfsr.sv"], "test_lfsr")
