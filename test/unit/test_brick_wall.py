# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for brick_wall: 8 x 6 bricks of 64 x 16 px at x 64..575, y 64..159, refilled
with the full wall or with a pattern grown from a seed row.

The wall only works with a beam that scans the screen in order, so vga_timing drives it
(brick_wall_tb.sv). The tests jump the beam forward with timers rather than clock by
clock, and act a quarter period before each rising edge, never on an edge: inputs set
there are taken at the next edge, with the beam where it was read.
"""

import random

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, RisingEdge, Timer

from cocotb_run import UNIT_DIR, run
from test_wall_pattern import aliens

COLS, ROWS = 8, 6
ALL = [(r, c) for r in range(ROWS) for c in range(COLS)]  # in the order the beam meets them
H_TOTAL, V_TOTAL = 800, 525
PERIOD_NS = 40


def centre(r: int, c: int) -> tuple[int, int]:
    return 64 * (1 + c) + 32, 16 * (4 + r) + 8


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, PERIOD_NS, unit="ns").start())
    dut.refill.value = 0
    dut.full_wall.value = 1
    dut.level.value = 0
    dut.random.value = 1
    dut.clear.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(PERIOD_NS * 3 // 4, unit="ns")  # the test's phase: a quarter period before the edge


async def goto(dut, x: int, y: int):
    """Waits (mid-cycle) until the beam is next at (x, y)."""
    now = int(dut.v_pos.value) * H_TOTAL + int(dut.h_pos.value)
    clocks = (y * H_TOTAL + x - now) % (H_TOTAL * V_TOTAL)
    if clocks:
        await Timer(clocks * PERIOD_NS, unit="ns")
    assert (int(dut.h_pos.value), int(dut.v_pos.value)) == (x, y)


async def next_frame(dut):
    """Waits until the next frame starts (a whole frame if one is just starting)."""
    now = int(dut.v_pos.value) * H_TOTAL + int(dut.h_pos.value)
    await Timer((H_TOTAL * V_TOTAL - now) * PERIOD_NS, unit="ns")


async def probe(dut, x: int, y: int) -> dict[str, int]:
    """Waits for the beam to reach (x, y) and reads the outputs there."""
    await goto(dut, x, y)
    return {n: int(getattr(dut, n).value) for n in ("brick_px", "brick_row", "over_columns", "empty")}


async def pulse(dut, name: str, x: int, y: int):
    """One-clock pulse on `clear` or `refill` with the beam at (x, y)."""
    await goto(dut, x, y)
    getattr(dut, name).value = 1
    await Timer(PERIOD_NS, unit="ns")  # across exactly one rising edge
    getattr(dut, name).value = 0


async def standing(dut) -> set[tuple[int, int]]:
    """The bricks drawn in the next frame."""
    await next_frame(dut)
    return {(r, c) for r, c in ALL if (await probe(dut, *centre(r, c)))["brick_px"]}


# While the wall fills (the frame after reset or refill), no brick shows, not even the bottom
# row, which is full by the time the beam gets there: the bricks stay hidden to line 160.
FILLING: set = set()


@cocotb.test()
async def filling_frame_then_full_wall(dut):
    await start(dut)  # the beam starts the frame after reset
    for r, c in ALL:
        expected = int((r, c) in FILLING)
        assert (await probe(dut, *centre(r, c)))["brick_px"] == expected, f"brick {r},{c} while filling"
    await next_frame(dut)
    for r, c in ALL:
        out = await probe(dut, *centre(r, c))
        assert out["brick_px"] == 1, f"brick {r},{c} missing"
        assert out["brick_row"] == r, f"brick {r},{c} reports row {out['brick_row']}"
    assert (await probe(dut, 0, 200))["empty"] == 0


@cocotb.test()
async def gaps_and_surroundings_are_not_bricks(dut):
    await start(dut)
    await next_frame(dut)  # past the filling frame
    for r in range(ROWS):  # in scan order: top gap row, corner row, then the centre row
        y = centre(r, 0)[1]
        for gy in (y - 8, y - 7):  # 2-px gap on the top edge
            for c in range(COLS):
                assert (await probe(dut, centre(r, c)[0], gy))["brick_px"] == 0, f"top gap of {r},{c}"
        for c in range(COLS):
            assert (await probe(dut, centre(r, c)[0] - 30, y - 6))["brick_px"] == 1, f"corner of {r},{c}"
        for c in range(COLS):
            x = centre(r, c)[0]
            for gx in (x - 32, x - 31):  # 2-px gap on the left edge
                assert (await probe(dut, gx, y))["brick_px"] == 0, f"left gap of {r},{c}"
    for x, y in [(300, 40), (300, 63), (32, 100), (600, 100), (300, 160), (300, 400)]:
        assert (await probe(dut, x, y))["brick_px"] == 0, f"({x}, {y}) is outside the wall"


@cocotb.test()
async def clear_removes_only_the_brick_under_the_beam(dut):
    rng = random.Random(2)
    await start(dut)
    await next_frame(dut)
    model = set(ALL)
    for frame in range(3):
        hits = sorted(rng.sample(sorted(model), 6))  # several per frame, in scan order
        await next_frame(dut)
        for r, c in hits:
            await pulse(dut, "clear", *centre(r, c))
        await pulse(dut, "clear", 300, 300)  # beam outside the wall: nothing to clear
        model -= set(hits)
        got = await standing(dut)
        assert got == model, f"after clearing {hits}: still standing {sorted(got - model)}, also gone {sorted(model - got)}"


@cocotb.test()
async def empty_below_the_wall_after_the_last_brick_then_refill(dut):
    await start(dut)
    await next_frame(dut)
    await next_frame(dut)
    for r, c in ALL:  # every brick, in one frame
        await pulse(dut, "clear", *centre(r, c))
    assert (await probe(dut, 0, 200))["empty"] == 0, "the bricks were drawn this frame"
    await next_frame(dut)
    for x, y in [(0, 200), (0, 480), (799, 524)]:  # holds until the next frame starts
        assert (await probe(dut, x, y))["empty"] == 1, f"not empty at y {y}"
    assert await standing(dut) == set()
    await pulse(dut, "refill", 0, 480)
    assert await standing(dut) == FILLING, "the wall shows no brick while it fills"
    assert (await probe(dut, 0, 200))["empty"] == 0, "a filling wall is not empty"
    assert await standing(dut) == set(ALL)


def pattern(value: int) -> set[tuple[int, int]]:
    """The wall the current layout builds from `random` = value (test_wall_pattern has the
    model), as standing (row, column)."""
    rows = aliens(value)
    return {(r, c) for r in range(ROWS) for c in range(COLS) if rows[r] >> c & 1}


async def refill_with(dut, full_wall: int, value: int):
    dut.full_wall.value = full_wall
    dut.level.value = 0 if full_wall else 1
    dut.random.value = value
    await pulse(dut, "refill", 0, 480)
    await next_frame(dut)  # past the filling frame


async def clear_all(dut):
    await next_frame(dut)
    for r, c in ALL:
        await pulse(dut, "clear", *centre(r, c))


@cocotb.test()
async def later_walls_come_from_wall_pattern(dut):
    """The ring puts wall_pattern's rows in place: each in its own row, and its columns in
    order, which a slip by one column (the ring's bit offset) would break, as these walls are
    not the same shifted; each row is grown from the one before. Three walls, of both rules;
    test_wall_pattern checks every wall itself."""
    await start(dut)
    await next_frame(dut)
    for value in (6, 9, 22):
        await clear_all(dut)
        await refill_with(dut, 0, value)
        got = await standing(dut)
        assert got == pattern(value), f"random {value}: extra {sorted(got - pattern(value))}, missing {sorted(pattern(value) - got)}"


@cocotb.test()
async def the_full_wall_whatever_is_left_or_random(dut):
    """A new game gets the full wall, whatever `random` is and however many bricks are left."""
    await start(dut)
    await next_frame(dut)
    await next_frame(dut)
    for r, c in ALL[::5]:
        await pulse(dut, "clear", *centre(r, c))
    await refill_with(dut, 1, 6)
    assert await standing(dut) == set(ALL)


@cocotb.test()
async def over_columns_spans_the_wall_width(dut):
    await start(dut)
    for y in (10, 100, 300):
        for x in (0, 63, 64, 300, 575, 576, 639):
            expected = int(64 <= x <= 575)
            assert (await probe(dut, x, y))["over_columns"] == expected, f"x={x}, y={y}"


def test_brick_wall():
    run("brick_wall_tb", ["vga_timing.sv", "wall_pattern.sv", "brick_wall.sv",
                          str(UNIT_DIR / "brick_wall_tb.sv")],
        "test_brick_wall")


async def reset_at(dut, x: int, y: int):
    """Resets the wall (and the beam) for 3 clocks from the beam at (x, y); returns in the test's
    phase with the beam at the start of the frame after reset."""
    await goto(dut, x, y)
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)
    await Timer(PERIOD_NS * 3 // 4, unit="ns")


async def assert_filling_frame(dut, what: str):
    """No brick shows in the frame now under way (the wall is filling)."""
    for r, c in ALL:
        assert (await probe(dut, *centre(r, c)))["brick_px"] == 0, f"brick {r},{c} {what}"


@cocotb.test()
async def reset_mid_step_and_mid_wall(dut):
    """A reset during a row turn's steps (on a brick row's first line, x 64 + 8 x phase .., with
    the phase different each time) or in the middle of the wall: the next frame fills, showing
    nothing, then the full wall is back, whatever was cleared."""
    await start(dut)
    await next_frame(dut)
    for x, y in [(67, 80), (99, 128), (300, 112)]:  # steps at phase 0 and 4; mid-wall
        await next_frame(dut)
        for r, c in ALL[1::3]:
            await pulse(dut, "clear", *centre(r, c))
        await reset_at(dut, x, y)
        await assert_filling_frame(dut, f"while filling after a reset at ({x}, {y})")
        assert await standing(dut) == set(ALL), f"after a reset at ({x}, {y})"


@cocotb.test()
async def an_uneven_wall_stays_put(dut):
    """A partly cleared, uneven wall (pattern walls are mirror images, which would hide a
    column reversal) is drawn the same for 7 frames: more than the 5 frames the row turns'
    phase takes to come round."""
    rng = random.Random(7)
    await start(dut)
    await next_frame(dut)
    await next_frame(dut)
    hits = sorted(rng.sample(ALL, 13))
    for r, c in hits:
        await pulse(dut, "clear", *centre(r, c))
    model = set(ALL) - set(hits)
    for frame in range(7):
        got = await standing(dut)
        assert got == model, f"frame {frame}: extra {sorted(got - model)}, missing {sorted(model - got)}"


@cocotb.test()
async def refills_at_other_lines(dut):
    """A refill at the start of a frame fills that frame, one below the wall fills the next, and
    one during the fill after reset changes nothing: each time no brick shows while it fills,
    then the new wall."""
    await start(dut)
    await pulse(dut, "refill", 0, 100)  # in the fill after reset
    assert await standing(dut) == set(ALL), "after a refill during the fill after reset"
    await clear_all(dut)
    dut.full_wall.value = 0
    dut.level.value = 1
    dut.random.value = 9
    await next_frame(dut)
    await pulse(dut, "refill", 0, 0)  # at the start of a frame: it fills this one
    await assert_filling_frame(dut, "while filling after a refill at line 0")
    assert await standing(dut) == pattern(9), "after a refill at line 0"
    await clear_all(dut)
    dut.random.value = 22
    await pulse(dut, "refill", 0, 200)  # below the wall: it fills the next frame
    assert await standing(dut) == set(), "the frame after a refill at line 200 is filling"
    assert await standing(dut) == pattern(22), "after a refill at line 200"
