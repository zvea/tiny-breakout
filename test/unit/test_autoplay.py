# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for autoplay: paddle steering towards one of the paddle's four angle zones,
picked anew after every paddle hit from the `random` bits (the game's LFSR, tested in
test_lfsr), for each of the paddle's widths. Autoplay reads where the ball is over the paddle
off the beam, so the tests drive the beam's signals as the top module works them out."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from cocotb_run import run


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.frame_tick.value = 0
    dut.paddle_hit.value = 0
    dut.random.value = 0
    dut.in_ball_x.value = 0
    dut.ball_dx.value = 0
    dut.paddle_zone.value = 0
    dut.over_paddle.value = 0
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


def beam(h: int, paddle_c: int, w16: int) -> tuple[int, int]:
    """The paddle zone under beam position h, and whether h is over the paddle, as the top
    module works them out: from the beam's offset from the centre, folded to a distance in
    8-px cells."""
    dx = (h - paddle_c) % 1024
    right = dx < 512
    d8 = (dx >> 3) if right else (~dx & 1023) >> 3
    outer = d8 >= w16 - 2
    zone = (3 if outer else 2) if right else (0 if outer else 1)
    return zone, int(d8 < w16)


async def sweep_ball(dut, ball_x: int, paddle_c: int, w16: int):
    """The beam crosses one line's worth of the ball's columns (and a pixel either side)."""
    for h in range(ball_x - 1, ball_x + 9):
        zone, over = beam(h, paddle_c, w16)
        inside = ball_x <= h < ball_x + 8
        dut.in_ball_x.value = int(inside)
        dut.ball_dx.value = (h - ball_x) % 8
        dut.paddle_zone.value = zone
        dut.over_paddle.value = over
        await RisingEdge(dut.clk)
    dut.in_ball_x.value = 0


def zone_span(zone: int, w16: int) -> tuple[int, int]:
    """The first and last px of a zone, from the paddle's centre: the outer zones are the last
    16 px at each end, the inner ones the rest of each half."""
    half = 8 * w16
    return [(-half, -half + 15), (-half + 16, -1), (0, half - 17), (half - 16, half - 1)][zone]


@cocotb.test()
async def steers_ball_inside_the_zone(dut):
    """After the beam has crossed the ball's columns, steer right/left exactly when the ball's
    last pixel to touch the paddle (ball x + 5, which decides the zone) is right/left of the
    chosen zone less 2 px at each side, where it stops; over the outer zones also with the
    ball's whole bottom row (ball x + 2 .. ball x + 5) at least 2 px on the paddle. The paddle
    moves 4 px a step, so where it stops must be at least 4 px wide. For every width and
    zone."""
    await start(dut)
    tested = set()
    for next_zone in (2, 3, 0, None):  # every zone, starting from 1 after reset
        zone = await read(dut, "aim_zone")
        for w16 in (6, 5, 4, 3):  # 96, 80, 64 and 48 px
            tested.add((zone, w16))
            first, last = zone_span(zone, w16)
            lo, hi = first + 2, last - 2
            if zone == 0:
                lo = max(lo, -8 * w16 + 2 + 3)  # ball x + 2 is 2 px in from the left end
            assert hi - lo + 1 >= 4, f"zone {zone}, width {16 * w16}: {hi - lo + 1} px to stop in"
            for paddle_c in (112, 320, 528):
                for ball_x in range(paddle_c - 60, paddle_c + 60):
                    await sweep_ball(dut, ball_x, paddle_c, w16)
                    await ReadOnly()
                    right, left = int(dut.steer_right.value), int(dut.steer_left.value)
                    await RisingEdge(dut.clk)
                    d = ball_x + 5 - paddle_c
                    assert (right, left) == (int(d > hi), int(d < lo)), (
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
        await sweep_ball(dut, 100 + f, 320, 4)
        zone = await read(dut, "aim_zone")
        await frame(dut, paddle_hit=hit, random=value)
        expected = value if hit else zone
        assert await read(dut, "aim_zone") == expected, f"frame {f}"


def test_autoplay():
    run("autoplay", ["autoplay.sv"], "test_autoplay")
