# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for autoplay: paddle steering towards one of the paddle's four angle zones,
picked anew after every paddle hit from the `random` bits (the game's LFSR, tested in
test_lfsr), for each of the paddle's widths."""

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
    dut.paddle_c.value = 320
    dut.paddle_w16.value = 4
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


def zone_middle(zone: int, w16: int) -> int:
    """Where in a zone autoplay aims the ball's centre, in px from the paddle's centre: the
    outer zones are the last 16 px at each end, the inner ones the rest of each half."""
    outer, inner = 8 * w16 - 8, (8 * w16 - 16) // 2
    return [-outer, -inner, inner, outer][zone]


@cocotb.test()
async def steers_ball_onto_the_middle_of_the_zone(dut):
    """Steer right/left exactly when the ball's centre is right/left of the middle of the
    chosen zone (to the 4-px unit the paddle moves in), for every width and zone."""
    await start(dut)
    tested = set()
    for next_zone in (2, 3, 0, None):  # every zone, starting from 1 after reset
        zone = await read(dut, "aim_zone")
        for w16 in (6, 5, 4, 3):  # 96, 80, 64 and 48 px
            tested.add((zone, w16))
            for paddle_c in (112, 320, 528):
                for ball_x in range(paddle_c - 60, paddle_c + 60):
                    dut.paddle_w16.value = w16
                    dut.paddle_c.value = paddle_c
                    dut.ball_x.value = ball_x
                    await ReadOnly()
                    right, left = int(dut.steer_right.value), int(dut.steer_left.value)
                    await RisingEdge(dut.clk)
                    ball4 = ball_x // 4
                    aim4 = (paddle_c + zone_middle(zone, w16) - 4) // 4  # the ball's left edge there
                    assert (right, left) == (int(ball4 > aim4), int(ball4 < aim4)), (
                        f"zone {zone}, width {16 * w16}, paddle centre {paddle_c}, ball {ball_x}"
                    )
        if next_zone is not None:
            await frame(dut, paddle_hit=True, random=next_zone)
    assert len(tested) == 16


@cocotb.test()
async def zone_changes_only_on_paddle_hits(dut):
    await start(dut)
    zone = await read(dut, "aim_zone")
    for f in range(40):
        await frame(dut, random=f % 4)
        assert await read(dut, "aim_zone") == zone, "zone changed without a paddle hit"


@cocotb.test()
async def each_hit_takes_the_zone_from_random(dut):
    """At a hit, the new zone is `random` in that frame, whatever the ball's position."""
    await start(dut)
    for f in range(60):
        hit = f % 3 == 1 or f % 7 == 0
        value = (f * 7 + 3) % 4
        dut.ball_x.value = 100 + f
        zone = await read(dut, "aim_zone")
        await frame(dut, paddle_hit=hit, random=value)
        expected = value if hit else zone
        assert await read(dut, "aim_zone") == expected, f"frame {f}"


def test_autoplay():
    run("autoplay", ["autoplay.sv"], "test_autoplay")
