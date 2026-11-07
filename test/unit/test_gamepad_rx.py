# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for gamepad_rx, driving the Gamepad PMOD protocol from Python.

A report is 24 bits, second controller first; each bit is valid on a rising edge of
pmod_clk, and a pmod_latch pulse ends the report. Button order within a controller,
first to last: b, y, select, start, up, down, left, right, a, x, l, r. The receiver
catches left, right, fire (A, X, L or R), whether a controller is connected, and
select_autoplay. Its counter waits for the first latch after reset, so most tests send
one report to prime it first.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from cocotb_run import run

BUTTONS = ["b", "y", "select", "start", "up", "down", "left", "right", "a", "x", "l", "r"]
NO_CONTROLLER = [1] * 12


def controller(*pressed: str) -> list[int]:
    """One controller's 12 report bits with the given buttons pressed."""
    return [int(name in pressed) for name in BUTTONS]


async def start(dut, prime: bool = True):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.pmod_latch.value = 0
    dut.pmod_clk.value = 0
    dut.pmod_data.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    if prime:
        await send(dut, controller())


async def send(dut, first: list[int], second: list[int] | None = None, half: int = 4) -> dict:
    """Sends one report (controller 2, then controller 1, then the latch pulse) and returns
    the outputs once it has gone through. `half` is half a PMOD clock period in system
    clocks; the real PMOD is much slower, which only matters for the synchronisers."""
    for bit in (second or controller()) + first:
        dut.pmod_data.value = bit
        await ClockCycles(dut.clk, half)
        dut.pmod_clk.value = 1
        await ClockCycles(dut.clk, half)
        dut.pmod_clk.value = 0
    await ClockCycles(dut.clk, half)
    dut.pmod_latch.value = 1
    await ClockCycles(dut.clk, half)
    dut.pmod_latch.value = 0
    await ClockCycles(dut.clk, 4)  # through the synchroniser
    await ReadOnly()
    out = {n: int(getattr(dut, n).value) for n in ("connected", "left", "right", "fire", "select_autoplay")}
    await RisingEdge(dut.clk)
    return out


@cocotb.test()
async def report_under_way_at_reset_is_ignored(dut):
    """The counter waits for a latch: the report that ends with the first latch isn't caught."""
    await start(dut, prime=False)
    out = await send(dut, controller("left"))
    assert out["connected"] == 0, "the first report after reset was caught"
    out = await send(dut, controller("left"))
    assert out["connected"] == 1 and out["left"] == 1


@cocotb.test()
async def each_used_button_is_caught(dut):
    await start(dut)
    out = await send(dut, controller())
    assert (out["left"], out["right"], out["fire"]) == (0, 0, 0), "nothing pressed"
    assert out["connected"] == 1
    assert (await send(dut, controller("left")))["left"] == 1
    assert (await send(dut, controller("right")))["right"] == 1
    for name in ("a", "x", "l", "r"):
        assert (await send(dut, controller(name)))["fire"] == 1, f"{name} is fire"
    for name in ("b", "y", "start", "up", "down"):
        out = await send(dut, controller(name))
        assert (out["left"], out["right"], out["fire"]) == (0, 0, 0), f"{name} does nothing"


@cocotb.test()
async def second_controller_is_ignored(dut):
    await start(dut)
    out = await send(dut, controller(), second=controller("left", "right", "a", "select"))
    assert (out["left"], out["right"], out["fire"], out["select_autoplay"]) == (0, 0, 0, 0)


@cocotb.test()
async def missing_controller_reads_as_not_connected(dut):
    """An all-ones report means no controller; up and down together is what's checked."""
    await start(dut)
    assert (await send(dut, controller("left")))["connected"] == 1
    assert (await send(dut, NO_CONTROLLER))["connected"] == 0
    assert (await send(dut, controller("up", "down", "a")))["connected"] == 0
    assert (await send(dut, controller()))["connected"] == 1


@cocotb.test()
async def select_switches_autoplay_on_and_left_right_or_fire_off(dut):
    await start(dut)
    assert (await send(dut, controller("select")))["select_autoplay"] == 1
    assert (await send(dut, controller()))["select_autoplay"] == 1, "stays on after release"
    assert (await send(dut, controller("select")))["select_autoplay"] == 1, "SELECT again: still on"
    assert (await send(dut, controller("b", "start", "up")))["select_autoplay"] == 1, "other buttons: still on"
    for off in ("left", "right", "a", "x", "l", "r"):
        await send(dut, controller("select"))
        assert (await send(dut, controller(off)))["select_autoplay"] == 0, f"{off} switches it off"
    await send(dut, controller("select"))
    assert (await send(dut, NO_CONTROLLER))["select_autoplay"] == 0, "no controller: off"


def test_gamepad_rx():
    run("gamepad_rx", ["gamepad_pkg.sv", "gamepad_rx.sv"], "test_gamepad_rx")
