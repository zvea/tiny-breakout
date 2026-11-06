# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for autoplay: paddle steering towards a paddle quarter that changes after
every paddle hit."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from cocotb_run import run


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.frame_tick.value = 0
    dut.paddle_hit.value = 0
    dut.ball_x.value = 0
    dut.paddle_x.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def frame(dut, paddle_hit: bool = False):
    """One frame_tick pulse, optionally reporting a paddle hit."""
    dut.frame_tick.value = 1
    dut.paddle_hit.value = int(paddle_hit)
    await RisingEdge(dut.clk)
    dut.frame_tick.value = 0
    dut.paddle_hit.value = 0
    await RisingEdge(dut.clk)


async def read(dut, name: str) -> int:
    await ReadOnly()
    value = int(getattr(dut, name).value)
    await RisingEdge(dut.clk)
    return value


@cocotb.test()
async def steers_ball_onto_the_quarter_centre(dut):
    """Steer right/left exactly when the ball centre is right/left of the quarter centre."""
    await start(dut)
    for _ in range(4):  # try several quarters
        quarter = await read(dut, "aim_quarter")
        for paddle_x in (64, 200, 512):
            for ball_x in range(paddle_x - 16, paddle_x + 80):
                dut.paddle_x.value = paddle_x
                dut.ball_x.value = ball_x
                await ReadOnly()
                right, left = int(dut.steer_right.value), int(dut.steer_left.value)
                await RisingEdge(dut.clk)
                # compared in 4-px units: ball centre over quarter centre
                ball_q, aim_q = ball_x // 4, paddle_x // 4 + 4 * quarter + 1
                assert (right, left) == (int(ball_q > aim_q), int(ball_q < aim_q)), (
                    f"quarter {quarter}, paddle {paddle_x}, ball {ball_x}"
                )
        await frame(dut, paddle_hit=True)


@cocotb.test()
async def quarter_changes_only_on_paddle_hits(dut):
    await start(dut)
    quarter = await read(dut, "aim_quarter")
    for _ in range(40):
        await frame(dut)
        assert await read(dut, "aim_quarter") == quarter, "quarter changed without a paddle hit"


@cocotb.test()
async def each_hit_moves_the_aim_on_by_1_or_2_quarters(dut):
    """The step depends on bit 2 of the ball's x position at the hit."""
    await start(dut)
    quarter = await read(dut, "aim_quarter")
    for ball_x in (100, 104, 108, 300, 305, 202, 64, 70):
        dut.ball_x.value = ball_x
        await frame(dut, paddle_hit=True)
        quarter = (quarter + 1 + ((ball_x >> 2) & 1)) % 4
        assert await read(dut, "aim_quarter") == quarter, f"ball_x {ball_x}"


@cocotb.test()
async def every_quarter_gets_picked(dut):
    await start(dut)
    quarters = set()
    for ball_x in range(64, 104):
        dut.ball_x.value = ball_x
        await frame(dut, paddle_hit=True)
        quarters.add(await read(dut, "aim_quarter"))
    assert quarters == {0, 1, 2, 3}


def test_autoplay():
    run("autoplay", ["autoplay.sv"], "test_autoplay")
