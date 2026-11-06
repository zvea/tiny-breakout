# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for autoplay: paddle steering towards a randomly chosen paddle quarter.

The random bits are an input, so the tests choose them."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from cocotb_run import run


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.frame_tick.value = 0
    dut.paddle_hit.value = 0
    dut.random.value = 0
    dut.ball_x.value = 0
    dut.paddle_x.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def frame(dut, paddle_hit: bool = False, random: int = 0):
    """One frame_tick pulse, optionally reporting a paddle hit, with the given random bits."""
    dut.frame_tick.value = 1
    dut.paddle_hit.value = int(paddle_hit)
    dut.random.value = random
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
        await frame(dut, paddle_hit=True, random=(quarter + 1) % 4)


@cocotb.test()
async def quarter_changes_only_on_paddle_hits(dut):
    await start(dut)
    quarter = await read(dut, "aim_quarter")
    for r in range(40):
        await frame(dut, random=r % 4)
        assert await read(dut, "aim_quarter") == quarter, "quarter changed without a paddle hit"


@cocotb.test()
async def paddle_hit_picks_the_random_quarter(dut):
    await start(dut)
    for r in (2, 0, 3, 1, 3):
        await frame(dut, paddle_hit=True, random=r)
        assert await read(dut, "aim_quarter") == r


def test_autoplay():
    run("autoplay", ["autoplay.sv"], "test_autoplay")
