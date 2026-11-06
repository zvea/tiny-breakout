# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge

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


@cocotb.test()
async def test_gamepad_and_paddle(dut):
    """Holding RIGHT on the gamepad moves the paddle right (checked on the paddle row)."""
    await reset(dut)

    async def paddle_left_edge():
        # wait for the start of line 450 (in the paddle row), find first paddle pixel
        while True:
            await RisingEdge(dut.clk)
            if int(dut.user_project.vc.value) == 450 and int(dut.user_project.hc.value) == 0:
                break
        for x in range(640):
            await RisingEdge(dut.clk)
            # paddle colour is R=2,G=3,B=3; outputs are registered one cycle
            if bit(dut, 5) == 1 and bit(dut, 1) == 1 and bit(dut, 2) == 1 and bit(dut, 4) == 0:
                return x
        return None

    x0 = await paddle_left_edge()
    await send_gamepad(dut, 1 << 4)  # RIGHT
    x1 = await paddle_left_edge()
    x2 = await paddle_left_edge()
    dut._log.info(f"paddle x: {x0} -> {x1} -> {x2}")
    assert x0 is not None and x2 is not None
    assert x2 > x0
