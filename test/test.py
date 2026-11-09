# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Tiny Tapeout full-chip tests (tb.v), on the RTL or the gate-level netlist (GATES=yes).

They use only the chip's pins, as internal signal names don't survive synthesis.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

HSYNC = 7
VSYNC = 3


async def reset(dut):
    clock = Clock(dut.clk, 40, unit="ns")  # ~25 MHz pixel clock
    cocotb.start_soon(clock.start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1


def bit(dut, n):
    return (int(dut.uo_out.value) >> n) & 1


@cocotb.test()
async def test_vga_timing(dut):
    """hsync: 96-cycle low pulse every 800 cycles."""
    await reset(dut)
    # find a falling edge of hsync
    while bit(dut, HSYNC) == 1:
        await RisingEdge(dut.clk)
    low = 0
    while bit(dut, HSYNC) == 0:
        low += 1
        await RisingEdge(dut.clk)
    period = low
    while bit(dut, HSYNC) == 1:
        period += 1
        await RisingEdge(dut.clk)
    dut._log.info(f"hsync low={low} period={period}")
    assert low == 96
    assert period == 800


async def send_gamepad(dut, buttons12):
    """Emulate one Gamepad PMOD report: 24 bits (2nd controller first), then latch."""
    bits = [0] * 12 + [(buttons12 >> (11 - i)) & 1 for i in range(12)]
    base = int(dut.ui_in.value) & 0x8F
    for b in bits:
        dut.ui_in.value = base | (b << 6)
        await ClockCycles(dut.clk, 10)
        dut.ui_in.value = base | (b << 6) | (1 << 5)
        await ClockCycles(dut.clk, 10)
    dut.ui_in.value = base
    await ClockCycles(dut.clk, 10)
    dut.ui_in.value = base | (1 << 4)
    await ClockCycles(dut.clk, 10)
    dut.ui_in.value = base
    await ClockCycles(dut.clk, 10)


async def paddle_left_edge(dut):
    """x of the paddle's first pixel on line 451 (paddle at y 448..455) in the next frame.

    Found from the sync pulses: vsync ends at line 492 and the k-th hsync pulse after that
    starts on line 491 + k at h 656, so the 484th is on line 450, and pixel x of line 451
    comes 144 + x clocks later (both outputs are registered alike).
    """
    while bit(dut, VSYNC) == 1:
        await RisingEdge(dut.clk)
    while bit(dut, VSYNC) == 0:
        await RisingEdge(dut.clk)
    pulses, prev = 0, bit(dut, HSYNC)
    while pulses < 484:
        await RisingEdge(dut.clk)
        cur = bit(dut, HSYNC)
        pulses += prev == 1 and cur == 0
        prev = cur
    for d in range(1, 144 + 640):
        await RisingEdge(dut.clk)
        # paddle colour is R=2, G=3, B=3
        if d >= 144 and bit(dut, 5) == 1 and bit(dut, 1) == 1 and bit(dut, 2) == 1 and bit(dut, 4) == 0:
            return d - 144
    return None


@cocotb.test()
async def test_gamepad_and_paddle(dut):
    """Holding LEFT on the gamepad moves the paddle left (autoplay would steer it right)."""
    await reset(dut)
    # The first report after reset is ignored (it may be incomplete); the second shows a
    # controller before the first frame update, so the demo never starts. The real PMOD
    # reports on every change, and at least once a second in Tiny Tapeout's configuration.
    await send_gamepad(dut, 1 << 5)  # LEFT
    await send_gamepad(dut, 1 << 5)
    # At the base speed the paddle moves every other frame: compare frames two apart
    x1 = await paddle_left_edge(dut)
    await paddle_left_edge(dut)
    x2 = await paddle_left_edge(dut)
    dut._log.info(f"paddle x: {x1} -> {x2}")
    assert x1 is not None and x2 is not None
    assert x2 < x1


def check_uio(dut):
    """uio[7] is the only output (audio, for the Audio Pmod); the other uio pins are unused."""
    assert int(dut.uio_oe.value) == 0x80, f"uio_oe = {int(dut.uio_oe.value):#04x}"
    assert int(dut.uio_out.value) & 0x7F == 0, f"uio_out = {int(dut.uio_out.value):#04x}"


@cocotb.test()
async def test_sound(dut):
    """Silent after reset; a new game plays a chord on uio[7].

    Holding a direct button through the first frame update (line 480) ends the demo at the
    second, a frame later, which starts a new game: a chord on both voices at volume 6 of 7,
    square waves with periods of 60 and 40 lines. Each voice has every other clock, high on 6
    of every 8 while its wave is 1, and over 40 lines the waves are 1 for 10..30 and 20
    lines: 9/32 to 15/32 of the clocks are high.
    """
    await reset(dut)
    for _ in range(800):  # a line: nothing plays yet
        await RisingEdge(dut.clk)
        check_uio(dut)
        assert int(dut.uio_out.value) >> 7 == 0, "audio after reset"
    dut.ui_in.value = 1  # LEFT
    # To line 469 of the next frame in one wait (cheaper than a Python step every clock),
    # then to the end of its vsync pulse, line 492: 12 lines into the new game
    await Timer((420_000 + 468 * 800) * 40, unit="ns")
    while bit(dut, VSYNC) == 1:
        await RisingEdge(dut.clk)
    while bit(dut, VSYNC) == 0:
        await RisingEdge(dut.clk)
    clocks = 40 * 800
    high = changes = 0
    prev = 0
    for _ in range(clocks):
        await RisingEdge(dut.clk)
        check_uio(dut)
        audio = int(dut.uio_out.value) >> 7
        high += audio
        changes += audio != prev
        prev = audio
    dut._log.info(f"audio high on {high} of {clocks} clocks, {changes} changes")
    assert 0.25 * clocks < high < 0.5 * clocks, f"audio high on {high} of {clocks} clocks"
    assert changes > 1000, f"audio changed {changes} times in {clocks} clocks"
