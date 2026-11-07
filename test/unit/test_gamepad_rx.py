# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for gamepad_rx, driving the Gamepad PMOD protocol from Python.

A report is 24 bits, second controller first; each bit is valid on a rising edge of
pmod_clk, and a pmod_latch pulse ends the report. Button order within a controller,
first to last: b, y, select, start, up, down, left, right, a, x, l, r.

The first report after reset is never presented, so most tests send one to prime the
receiver first.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge
from cocotb.utils import get_sim_time

from cocotb_run import run

PERIOD_NS = 40
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


async def start(dut, prime: bool = True):
    cocotb.start_soon(Clock(dut.clk, PERIOD_NS, unit="ns").start())
    dut.pmod_latch.value = 0
    dut.pmod_clk.value = 0
    dut.pmod_data.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    if prime:
        await send(dut, controller(), controller(), presented=False)


async def next_report(dut) -> tuple[int, int]:
    """Waits for report_valid; returns the report and the strobe width in clocks."""
    await RisingEdge(dut.report_valid)
    await ReadOnly()
    value = int(dut.report.value)
    t0 = get_sim_time("ns")
    await FallingEdge(dut.report_valid)
    return value, round((get_sim_time("ns") - t0) / PERIOD_NS)


async def send(dut, first: list[int], second: list[int], latch: bool = True,
               presented: bool = True, half: int = 4):
    """Sends one report: controller 2 (`second`) first, then controller 1 (`first`).

    With `latch` and `presented`, returns the report gamepad_rx presents with
    report_valid, which must last as long as the latch pulse. `half` is half a PMOD clock
    period in system clocks; the real PMOD is much slower than the 25 MHz system clock,
    which only matters for the synchronisers.
    """
    for bit in second + first:
        dut.pmod_data.value = bit
        await ClockCycles(dut.clk, half)
        dut.pmod_clk.value = 1
        await ClockCycles(dut.clk, half)
        dut.pmod_clk.value = 0
    if not latch:
        return None
    capture = cocotb.start_soon(next_report(dut)) if presented else None
    await ClockCycles(dut.clk, half)
    dut.pmod_latch.value = 1
    await ClockCycles(dut.clk, half)
    dut.pmod_latch.value = 0
    await ClockCycles(dut.clk, 4)  # through the synchroniser
    if capture is None:
        return None
    value, width = await capture
    assert width == half, f"report_valid lasted {width} clocks, the latch pulse {half}"
    return value


async def count_strobes(dut, counter: list[int]):
    while True:
        await RisingEdge(dut.report_valid)
        counter[0] += 1


@cocotb.test()
async def no_report_before_the_first_latch(dut):
    await start(dut, prime=False)
    strobes = [0]
    cocotb.start_soon(count_strobes(dut, strobes))
    await ClockCycles(dut.clk, 20)
    await send(dut, controller("a"), controller(), latch=False)
    assert strobes[0] == 0, "report_valid without a latch pulse"


@cocotb.test()
async def first_report_after_reset_is_not_presented(dut):
    await start(dut, prime=False)
    strobes = [0]
    cocotb.start_soon(count_strobes(dut, strobes))
    await send(dut, controller("a"), controller(), presented=False)
    assert strobes[0] == 0, "the first report after reset was presented"
    assert await send(dut, controller("b"), controller()) == expected(controller("b"))


@cocotb.test()
async def each_button_maps_to_its_field(dut):
    """Each button alone shows up as exactly its own bit of gamepad_t."""
    await start(dut)
    for name in BUTTONS:
        got = await send(dut, controller(name), controller())
        assert got == expected(controller(name)), f"{name}: got {got:012b}"


@cocotb.test()
async def second_controller_is_ignored(dut):
    rng = random.Random(1)
    await start(dut)
    for _ in range(10):
        first = [rng.randint(0, 1) for _ in BUTTONS]
        second = [rng.randint(0, 1) for _ in BUTTONS]
        up_and_down = first[BUTTONS.index("up")] and first[BUTTONS.index("down")]
        assert await send(dut, first, second) == (0 if up_and_down else expected(first))


@cocotb.test()
async def missing_controller_reads_as_nothing_pressed(dut):
    """An all-ones report means no controller: the report must read all zero. Up and down
    together (impossible on a d-pad) is what the receiver checks."""
    await start(dut)
    assert await send(dut, controller("left", "b"), controller()) == expected(controller("left", "b"))
    assert int(dut.connected.value) == 1, "a controller is connected"
    assert await send(dut, NO_CONTROLLER, controller()) == 0
    assert int(dut.connected.value) == 0, "no controller"
    assert await send(dut, controller("up", "down", "a"), controller()) == 0
    assert int(dut.connected.value) == 0, "up and down together: no controller"


@cocotb.test()
async def one_strobe_per_report(dut):
    await start(dut)
    strobes = [0]
    cocotb.start_soon(count_strobes(dut, strobes))
    for n in range(1, 4):
        await send(dut, controller("start"), controller())
        assert strobes[0] == n


def test_gamepad_rx():
    run("gamepad_rx", ["gamepad_pkg.sv", "gamepad_rx.sv"], "test_gamepad_rx")
