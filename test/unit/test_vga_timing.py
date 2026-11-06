# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for vga_timing: 640x480 @ 60 Hz (800 x 525 clocks per frame).

The tests wait on signal edges rather than stepping the clock from Python, so the
simulator runs whole frames without calling back into Python on every cycle.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge
from cocotb.utils import get_sim_time

from cocotb_run import run

PERIOD_NS = 40
H_TOTAL = 800
V_TOTAL = 525
FRAME = H_TOTAL * V_TOTAL


def now() -> int:
    """Current simulation time in clock cycles."""
    return round(get_sim_time("ns") / PERIOD_NS)


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, PERIOD_NS, unit="ns").start())
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    await ReadOnly()
    assert (int(dut.h_pos.value), int(dut.v_pos.value)) == (0, 0), "reset must clear the counters"
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1


async def position(dut) -> tuple[int, int]:
    await ReadOnly()
    return int(dut.h_pos.value), int(dut.v_pos.value)


@cocotb.test()
async def h_sync_pulse(dut):
    """h_sync_n: 96 clocks low, every 800 clocks, starting at h_pos 656."""
    await start(dut)
    await FallingEdge(dut.h_sync_n)
    t0 = now()
    assert (await position(dut))[0] == 656
    await RisingEdge(dut.h_sync_n)
    t1 = now()
    await FallingEdge(dut.h_sync_n)
    t2 = now()
    assert t1 - t0 == 96, "sync pulse length"
    assert t2 - t0 == H_TOTAL, "line length"


@cocotb.test()
async def v_sync_pulse(dut):
    """v_sync_n: 2 lines low, every 525 lines, starting at line 490."""
    await start(dut)
    await FallingEdge(dut.v_sync_n)
    t0 = now()
    assert await position(dut) == (0, 490)
    await RisingEdge(dut.v_sync_n)
    t1 = now()
    await FallingEdge(dut.v_sync_n)
    t2 = now()
    assert t1 - t0 == 2 * H_TOTAL, "sync pulse length"
    assert t2 - t0 == FRAME, "frame length"


@cocotb.test()
async def visible_area(dut):
    """visible: 640 clocks on each of 480 lines per frame, starting at (0, 0)."""
    await start(dut)
    await RisingEdge(dut.vblank_start)  # align to a frame boundary

    lines = 0
    while True:
        await RisingEdge(dut.visible)
        t0 = now()
        h, v = await position(dut)
        if lines == 480:
            # the next visible line belongs to the following frame
            assert (h, v) == (0, 0)
            break
        assert (h, v) == (0, lines), f"visible line {lines} starts at the wrong place"
        await FallingEdge(dut.visible)
        assert now() - t0 == 640, f"visible line {lines} length"
        lines += 1


@cocotb.test()
async def vblank_start_strobe(dut):
    """vblank_start: one clock wide, once per frame, at line 480 column 0."""
    await start(dut)
    await RisingEdge(dut.vblank_start)
    t0 = now()
    assert await position(dut) == (0, 480)
    await FallingEdge(dut.vblank_start)
    assert now() - t0 == 1, "strobe width"
    await RisingEdge(dut.vblank_start)
    assert now() - t0 == FRAME, "strobe period"


def test_vga_timing():
    run("vga_timing", ["vga_timing.sv"], "test_vga_timing")
