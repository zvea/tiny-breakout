# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for score: a 3-digit counter shown as 4 seven-segment digits (the last a
fixed 0) in 16-px slots at x 512..575, y 3..18.

The number is read off the pixels: the middle of each segment of each digit is probed and
the lit segments are decoded, so these tests check the drawing as well as the counting.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from cocotb_run import run

FIRST_X, FIRST_Y = 512, 3  # the slots' top left: the digits are centred in the 24-line band
# Middle of each segment (x, y) within a 16 x 16 slot, in the order a, b, c, d, e, f, g
SEGMENT_MIDDLES = [(7, 2), (10, 5), (10, 12), (7, 14), (4, 12), (4, 5), (7, 8)]
DIGIT_SEGMENTS = {  # lit segments, as a string of a..g
    0: "abcdef", 1: "bc", 2: "abdeg", 3: "abcdg", 4: "bcfg",
    5: "acdfg", 6: "acdefg", 7: "abc", 8: "abcdefg", 9: "abcdfg",
}
SEGMENTS_DIGIT = {"".join(sorted(v)): k for k, v in DIGIT_SEGMENTS.items()}


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.clear.value = 0
    dut.add.value = 0
    dut.h_pos.value = 0
    dut.v_pos.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def lit(dut, x: int, y: int) -> int:
    dut.h_pos.value = x
    dut.v_pos.value = y
    await ReadOnly()
    value = int(dut.score_px.value)
    await RisingEdge(dut.clk)
    return value


async def shown(dut) -> int:
    """The number on the display, read off the segments."""
    number = 0
    for slot in range(4):
        segments = ""
        for name, (x, y) in zip("abcdefg", SEGMENT_MIDDLES):
            if await lit(dut, FIRST_X + 16 * slot + x, FIRST_Y + y):
                segments += name
        assert segments in SEGMENTS_DIGIT, f"slot {slot} shows segments '{segments}': not a digit"
        number = number * 10 + SEGMENTS_DIGIT[segments]
    return number


async def add(dut, points: int):
    dut.add.value = 1
    await ClockCycles(dut.clk, points)
    dut.add.value = 0
    await RisingEdge(dut.clk)


@cocotb.test()
async def zero_after_reset(dut):
    await start(dut)
    assert await shown(dut) == 0


@cocotb.test()
async def counts_in_tens_with_carries(dut):
    await start(dut)
    total = 0
    for step in [1, 8, 1, 1, 89, 1, 9, 790, 99, 1]:  # through 9->10, 99->100, up to 999
        await add(dut, step)
        total = min(total + step, 999)
        assert await shown(dut) == total * 10, f"after {total} points"


@cocotb.test()
async def every_digit_is_drawn_right(dut):
    """Each digit's segments, in the ones place (which reads x10, so slot 2)."""
    await start(dut)
    for d in range(10):
        segments = ""
        for name, (x, y) in zip("abcdefg", SEGMENT_MIDDLES):
            if await lit(dut, FIRST_X + 32 + x, FIRST_Y + y):
                segments += name
        assert segments == DIGIT_SEGMENTS[d], f"digit {d} shows '{segments}'"
        await add(dut, 1)


@cocotb.test()
async def clear_goes_back_to_zero(dut):
    await start(dut)
    await add(dut, 123)
    assert await shown(dut) == 1230
    dut.clear.value = 1
    await RisingEdge(dut.clk)
    dut.clear.value = 0
    await RisingEdge(dut.clk)
    assert await shown(dut) == 0


@cocotb.test()
async def stops_at_9990_until_cleared(dut):
    await start(dut)
    await add(dut, 999)
    assert await shown(dut) == 9990
    await add(dut, 250)
    assert await shown(dut) == 9990, "went past 9990"
    dut.clear.value = 1
    await RisingEdge(dut.clk)
    dut.clear.value = 0
    await RisingEdge(dut.clk)
    await add(dut, 5)
    assert await shown(dut) == 50, "did not count again after clear"


@cocotb.test()
async def nothing_lit_outside_the_digits(dut):
    await start(dut)
    await add(dut, 888)  # all segments lit
    for x, y in [(511, 11), (576, 11), (520, 19), (520, 4), (512 + 3, 11), (512 + 12, 11),
                 (300, 11)]:
        assert await lit(dut, x, y) == 0, f"({x}, {y}) is lit"


def test_score():
    run("score", ["score.sv"], "test_score")
