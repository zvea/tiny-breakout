# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for gamepad_rx, driving the Gamepad PMOD protocol from Python.

A report is 24 bits, second controller first; each bit is valid on a rising edge of
pmod_clk, and a pmod_latch pulse ends the report. Button order within a controller,
first to last: b, y, select, start, up, down, left, right, a, x, l, r.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from cocotb_run import run

BUTTONS = ["b", "y", "select", "start", "up", "down", "left", "right", "a", "x", "l", "r"]
NO_CONTROLLER = [1] * 12


def controller(*pressed: str) -> list[int]:
    """One controller's 12 report bits with the given buttons pressed."""
    return [int(name in pressed) for name in BUTTONS]


def expected(bits: list[int]) -> int:
    """gamepad_t value for one controller's report bits (b is the most significant bit)."""
    value = 0
    for bit in bits:
        value = (value << 1) | bit
    return value


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.pmod_latch.value = 0
    dut.pmod_clk.value = 0
    dut.pmod_data.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1


async def send(dut, first: list[int], second: list[int], latch: bool = True, half: int = 4):
    """Sends one report: controller 2 (`second`) first, then controller 1 (`first`).

    `half` is half a PMOD clock period in system clocks; the real PMOD is much slower
    than the 25 MHz system clock, which only matters for the synchronisers.
    """
    for bit in second + first:
        dut.pmod_data.value = bit
        await ClockCycles(dut.clk, half)
        dut.pmod_clk.value = 1
        await ClockCycles(dut.clk, half)
        dut.pmod_clk.value = 0
    if latch:
        await ClockCycles(dut.clk, half)
        dut.pmod_latch.value = 1
        await ClockCycles(dut.clk, half)
        dut.pmod_latch.value = 0
    await ClockCycles(dut.clk, 8)  # through the synchroniser and edge detector


async def buttons(dut) -> int:
    await ReadOnly()
    value = int(dut.buttons.value)
    await RisingEdge(dut.clk)
    return value


@cocotb.test()
async def nothing_pressed_after_reset(dut):
    await start(dut)
    await ClockCycles(dut.clk, 5)
    assert await buttons(dut) == 0


@cocotb.test()
async def each_button_maps_to_its_field(dut):
    """Each button alone shows up as exactly its own bit of gamepad_t."""
    await start(dut)
    for name in BUTTONS:
        await send(dut, controller(name), controller())
        got = await buttons(dut)
        assert got == expected(controller(name)), f"{name}: got {got:012b}"


@cocotb.test()
async def second_controller_is_ignored(dut):
    rng = random.Random(1)
    await start(dut)
    for _ in range(10):
        first = [rng.randint(0, 1) for _ in BUTTONS]
        if first == NO_CONTROLLER:
            continue
        second = [rng.randint(0, 1) for _ in BUTTONS]
        await send(dut, first, second)
        assert await buttons(dut) == expected(first)


@cocotb.test()
async def missing_controller_reads_as_nothing_pressed(dut):
    """An all-ones report means no controller: buttons must read all zero."""
    await start(dut)
    await send(dut, controller("left", "b"), controller())
    assert await buttons(dut) == expected(controller("left", "b"))
    await send(dut, NO_CONTROLLER, controller())
    assert await buttons(dut) == 0


@cocotb.test()
async def buttons_change_only_on_latch(dut):
    """A report in progress must not disturb the outputs until the latch pulse."""
    await start(dut)
    await send(dut, controller("right"), controller())
    await send(dut, controller("a", "start"), controller(), latch=False)
    assert await buttons(dut) == expected(controller("right")), "changed before the latch"
    await send(dut, controller("a", "start"), controller())
    assert await buttons(dut) == expected(controller("a", "start"))


def test_gamepad_rx():
    run("gamepad_rx", ["gamepad_pkg.sv", "gamepad_rx.sv"], "test_gamepad_rx")
