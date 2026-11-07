# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for autoplay: paddle steering towards a paddle quarter that is picked anew,
pseudo-randomly, after every paddle hit (from a 5-bit LFSR, x^5 + x^3 + 1, that steps
every frame)."""

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


def lfsr_states(n: int) -> list[int]:
    """The LFSR's value at each of the first n frames after reset (seed 1)."""
    states, s = [], 1
    for _ in range(n):
        states.append(s)
        s = ((s << 1) & 0x1F) | (((s >> 4) ^ (s >> 2)) & 1)
    return states


@cocotb.test()
async def each_hit_takes_the_quarter_from_the_lfsr(dut):
    """At a hit, the new quarter is the LFSR's low 2 bits in that frame, whatever the ball's
    position, and the LFSR keeps stepping every frame with or without hits."""
    await start(dut)
    states = lfsr_states(60)
    for f in range(60):
        hit = f % 3 == 1 or f % 7 == 0
        dut.ball_x.value = 100 + f
        quarter = await read(dut, "aim_quarter")
        await frame(dut, paddle_hit=hit)
        expected = states[f] & 3 if hit else quarter
        assert await read(dut, "aim_quarter") == expected, f"frame {f}"


@cocotb.test()
async def lfsr_runs_through_all_31_non_zero_states(dut):
    assert sorted(set(lfsr_states(31))) == list(range(1, 32))
    await start(dut)
    seen = set()
    for _ in range(31):
        seen.add(await read(dut, "lfsr"))
        await frame(dut)
    assert seen == set(range(1, 32))


@cocotb.test()
async def every_quarter_gets_picked(dut):
    await start(dut)
    quarters = set()
    for _ in range(40):
        await frame(dut, paddle_hit=True)
        quarters.add(await read(dut, "aim_quarter"))
    assert quarters == {0, 1, 2, 3}


def test_autoplay():
    run("autoplay", ["autoplay.sv"], "test_autoplay")
