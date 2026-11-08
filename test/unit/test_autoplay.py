# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for autoplay: paddle steering towards a paddle quarter that is picked anew
after every paddle hit, from the `random` bits (the game's LFSR, tested in test_lfsr)."""

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
    """One frame_tick pulse, optionally reporting a paddle hit, with `random` as given."""
    dut.random.value = random
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
    tested = set()
    for next_quarter in (2, 3, 0, None):  # every quarter, starting from 1 after reset
        quarter = await read(dut, "aim_quarter")
        tested.add(quarter)
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
        if next_quarter is not None:
            await frame(dut, paddle_hit=True, random=next_quarter)
    assert tested == {0, 1, 2, 3}


@cocotb.test()
async def quarter_changes_only_on_paddle_hits(dut):
    await start(dut)
    quarter = await read(dut, "aim_quarter")
    for f in range(40):
        await frame(dut, random=f % 4)
        assert await read(dut, "aim_quarter") == quarter, "quarter changed without a paddle hit"


@cocotb.test()
async def each_hit_takes_the_quarter_from_random(dut):
    """At a hit, the new quarter is `random` in that frame, whatever the ball's position."""
    await start(dut)
    for f in range(60):
        hit = f % 3 == 1 or f % 7 == 0
        value = (f * 7 + 3) % 4
        dut.ball_x.value = 100 + f
        quarter = await read(dut, "aim_quarter")
        await frame(dut, paddle_hit=hit, random=value)
        expected = value if hit else quarter
        assert await read(dut, "aim_quarter") == expected, f"frame {f}"


def test_autoplay():
    run("autoplay", ["autoplay.sv"], "test_autoplay")
