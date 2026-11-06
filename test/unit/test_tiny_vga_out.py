# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for tiny_vga_out: registered colour and sync on the TinyVGA PMOD pins.

TinyVGA PMOD pins, uo_out[7:0]: {hsync, B0, G0, R0, vsync, B1, G1, R1}, where R1/R0 are
the high/low bits of red, and so on.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from cocotb_run import run


def pins(r: int, g: int, b: int, h_sync_n: int, v_sync_n: int) -> int:
    """Expected uo_out for a colour and sync levels."""
    bit = lambda value, n: (value >> n) & 1  # noqa: E731
    return (
        h_sync_n << 7 | bit(b, 0) << 6 | bit(g, 0) << 5 | bit(r, 0) << 4
        | v_sync_n << 3 | bit(b, 1) << 2 | bit(g, 1) << 1 | bit(r, 1)
    )  # fmt: skip


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.colour.value = 0
    dut.visible.value = 0
    dut.h_sync_n.value = 1
    dut.v_sync_n.value = 1
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    await ReadOnly()
    assert int(dut.uo_out.value) == pins(0, 0, 0, 1, 1), "reset: black, syncs inactive"
    await RisingEdge(dut.clk)
    dut.rst_n.value = 1


async def drive(dut, r, g, b, visible, h_sync_n=1, v_sync_n=1) -> int:
    """Applies inputs for one clock and returns uo_out after that clock edge."""
    dut.colour.value = r << 4 | g << 2 | b  # colour_pkg::rgb_t is {r, g, b}
    dut.visible.value = visible
    dut.h_sync_n.value, dut.v_sync_n.value = h_sync_n, v_sync_n
    await RisingEdge(dut.clk)
    await ReadOnly()
    value = int(dut.uo_out.value)
    await RisingEdge(dut.clk)
    return value


@cocotb.test()
async def every_colour_lands_on_its_pins(dut):
    await start(dut)
    for colour in range(64):
        r, g, b = colour >> 4, (colour >> 2) & 3, colour & 3
        assert await drive(dut, r, g, b, visible=1) == pins(r, g, b, 1, 1), f"colour {colour:06b}"


@cocotb.test()
async def blanking_forces_black(dut):
    await start(dut)
    assert await drive(dut, 3, 3, 3, visible=0) == pins(0, 0, 0, 1, 1)
    assert await drive(dut, 2, 1, 3, visible=0, h_sync_n=0) == pins(0, 0, 0, 0, 1)


@cocotb.test()
async def sync_levels_pass_through(dut):
    await start(dut)
    for h in (0, 1):
        for v in (0, 1):
            assert await drive(dut, 1, 2, 3, 1, h, v) == pins(1, 2, 3, h, v), f"h {h}, v {v}"


@cocotb.test()
async def outputs_change_one_clock_after_the_inputs(dut):
    await start(dut)
    await drive(dut, 0, 0, 0, visible=1)
    dut.colour.value = 3 << 4  # red
    await ReadOnly()
    assert int(dut.uo_out.value) == pins(0, 0, 0, 1, 1), "output must not follow the input combinationally"
    await RisingEdge(dut.clk)
    await ReadOnly()
    assert int(dut.uo_out.value) == pins(3, 0, 0, 1, 1), "output updates on the next clock edge"


def test_tiny_vga_out():
    run("tiny_vga_out", ["colour_pkg.sv", "tiny_vga_out.sv"], "test_tiny_vga_out")
