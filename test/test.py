# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Tiny Tapeout full-chip tests (tb.v), on the RTL or the gate-level netlist (GATES=yes).

They use only the chip's pins, as internal signal names don't survive synthesis.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, RisingEdge, Timer
from cocotb.utils import get_sim_time

# Pins, by bit number. uo_out is the TinyVGA PMOD (src/tiny_vga_out.sv): each colour's high
# bit in the low nibble, its low bit in the high nibble, and the sync pulses (active low).
R1, G1, B1, VSYNC, R0, G0, B0, HSYNC = range(8)
# ui_in (src/tt_um_tiny_breakout.sv): the direct buttons and autoplay, then the Gamepad PMOD
LEFT, RIGHT, FIRE, AUTOPLAY, PAD_LATCH, PAD_CLK, PAD_DATA = range(7)
PAD_PINS = (1 << PAD_LATCH) | (1 << PAD_CLK) | (1 << PAD_DATA)
# uio: the Audio Pmod's input is the only output
AUDIO = 7

# A gamepad report's buttons, as send_gamepad takes them: bit 11 is sent first
PAD_LEFT = 1 << 5

# Colours as 6 bits {r, g, b}, 2 bits per channel, as in src/colour_pkg.sv
BLACK = 0b00_00_00
WHITE = 0b11_11_11  # the ball, the spare-ball markers and the score
PALE_CYAN = 0b10_11_11  # the paddle
GREY = 0b01_01_01  # the walls
NAVY = 0b00_00_01  # the field
RED = 0b11_00_00  # the top row of bricks
VIOLET = 0b10_00_11  # the bottom row

# Video timing (src/vga_timing.sv): 640x480 of 800 clocks x 525 lines
CLOCK_NS = 40  # ~25 MHz pixel clock
LINE = 800  # clocks
FRAME = 525  # lines
VSYNC_LINE = 490  # the vsync pulse's first line
WIDTH = 640


async def reset(dut):
    clock = Clock(dut.clk, CLOCK_NS, unit="ns")
    cocotb.start_soon(clock.start())
    dut.ena.value = 1
    dut.ui_in.value = 0
    dut.uio_in.value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 10)
    dut.rst_n.value = 1


def bit(dut, n):
    return (int(dut.uo_out.value) >> n) & 1


def colour(dut):
    """The pixel colour on uo_out, as 6 bits {r, g, b} (see the colours above)."""
    pins = int(dut.uo_out.value)
    rgb = 0
    for n in (R1, R0, G1, G0, B1, B0):
        rgb = (rgb << 1) | ((pins >> n) & 1)
    return rgb


def now_ns():
    return get_sim_time(unit="ns")


async def vsync_start(dut):
    """Wait for the next vsync pulse to begin, and return its time, for pixel()."""
    await FallingEdge(dut.vsync_n)
    return now_ns()


async def pixel(dut, vsync_ns, x, y):
    """The colour of pixel (x, y) in the frame after the vsync pulse that began at vsync_ns.

    uo_out is registered: it shows the pixel at the beam, and the sync pulses with it, for the
    clock after the beam is there. So vsync falls as pixel (0, 490) shows, and pixel (x, y) of
    the next frame shows (525 - 490 + y) * 800 + x clocks later, for a clock. One wait gets
    there, and reads half a clock in, clear of the clock's edges and so of the gate-level
    netlist's output delays. The calls of a frame must go in scan order.
    """
    clocks = (FRAME - VSYNC_LINE + y) * LINE + x
    await Timer(vsync_ns + clocks * CLOCK_NS + CLOCK_NS // 2 - now_ns(), unit="ns")
    return colour(dut)


async def line_colours(dut, vsync_ns, y):
    """The colours of line y's pixels, as pixel() reads them: a wait per pixel."""
    return [await pixel(dut, vsync_ns, x, y) for x in range(WIDTH)]


def run_of(colours, rgb):
    """The first x and the width of the pixels of colour rgb on a line: (None, 0) if none.

    They must be one run, with no other colour among them.
    """
    xs = [x for x, c in enumerate(colours) if c == rgb]
    if not xs:
        return None, 0
    assert xs[-1] - xs[0] + 1 == len(xs), f"colour {rgb:06b} is not one run: x = {xs}"
    return xs[0], len(xs)


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
    base = int(dut.ui_in.value) & ~PAD_PINS
    for b in bits:
        dut.ui_in.value = base | (b << PAD_DATA)
        await ClockCycles(dut.clk, 10)
        dut.ui_in.value = base | (b << PAD_DATA) | (1 << PAD_CLK)
        await ClockCycles(dut.clk, 10)
    dut.ui_in.value = base
    await ClockCycles(dut.clk, 10)
    dut.ui_in.value = base | (1 << PAD_LATCH)
    await ClockCycles(dut.clk, 10)
    dut.ui_in.value = base
    await ClockCycles(dut.clk, 10)


async def paddle_and_ball(dut):
    """The paddle and the resting ball in the next frame, each as (first x, width).

    The paddle is the pale cyan on line 451 (it is at y 448..455); the ball is the white on
    line 444, the middle of the 8x8 box it rests in (y 440..447), where its circle is 8 px wide.
    """
    vsync = await vsync_start(dut)
    ball = run_of(await line_colours(dut, vsync, 444), WHITE)
    paddle = run_of(await line_colours(dut, vsync, 451), PALE_CYAN)
    return paddle, ball


@cocotb.test()
async def test_gamepad_and_paddle(dut):
    """Holding LEFT on the gamepad moves the paddle left, a 4-px step every two frames.

    The paddle is 96 px wide on the first wall, and the ball rests on its middle: the demo,
    which a connected controller keeps from starting, would launch it and steer the paddle.
    """
    await reset(dut)
    # The first report after reset is ignored (it may be incomplete); the second shows a
    # controller before the first frame update, so the demo never starts. The real PMOD
    # reports on every change, and at least once a second in Tiny Tapeout's configuration.
    await send_gamepad(dut, PAD_LEFT)
    await send_gamepad(dut, PAD_LEFT)
    # At the base speed the paddle moves every other frame: compare frames two apart
    (x1, w1), (ball1, ball_w1) = await paddle_and_ball(dut)
    await vsync_start(dut)
    (x2, w2), (ball2, ball_w2) = await paddle_and_ball(dut)
    dut._log.info(f"paddle x: {x1} -> {x2}, widths {w1}, {w2}; ball x: {ball1} -> {ball2}")
    assert x1 is not None and x2 is not None, "no paddle on line 451"
    assert w1 == w2 == 96, f"paddle {w1} and {w2} px wide"
    assert x1 - x2 == 4, f"paddle moved from x {x1} to {x2} in two frames"
    # The ball's box is 8 px wide, centred on the paddle's middle (x + 48)
    assert (ball1, ball_w1) == (x1 + 44, 8), f"ball at x {ball1}, {ball_w1} px wide; paddle at {x1}"
    assert (ball2, ball_w2) == (x2 + 44, 8), f"ball at x {ball2}, {ball_w2} px wide; paddle at {x2}"


def check_uio(dut):
    """uio[7] is the only output (audio, for the Audio Pmod); the other uio pins are unused."""
    assert int(dut.uio_oe.value) == 1 << AUDIO, f"uio_oe = {int(dut.uio_oe.value):#04x}"
    assert int(dut.uio_out.value) & ~(1 << AUDIO) == 0, f"uio_out = {int(dut.uio_out.value):#04x}"


@cocotb.test()
async def test_sound(dut):
    """Silent after reset; a new game makes a sound on uio[7], whatever its tune.

    Holding a direct button through the first frame update (line 480) ends the demo at the
    second, a frame later, which starts a new game, and its sound. The pin carries two voices
    on alternate clocks, each high on at most 7 of every 8 of its clocks (volume 7 of 7), so at
    most 7/8 of the clocks are high. Over 160 lines, a whole period of any note down to G3,
    a sound of any tune is high on some of them and changes often. (The unit and system tests
    check which notes it plays.)
    """
    await reset(dut)
    for _ in range(800):  # a line: nothing plays yet
        await RisingEdge(dut.clk)
        check_uio(dut)
        assert (int(dut.uio_out.value) >> AUDIO) & 1 == 0, "audio after reset"
    dut.ui_in.value = 1 << LEFT
    # To line 469 of the next frame in one wait (cheaper than a Python step every clock),
    # then to the end of its vsync pulse, line 492: 12 lines into the new game
    await Timer((420_000 + 468 * 800) * 40, unit="ns")
    while bit(dut, VSYNC) == 1:
        await RisingEdge(dut.clk)
    while bit(dut, VSYNC) == 0:
        await RisingEdge(dut.clk)
    clocks = 160 * 800
    high = changes = 0
    prev = 0
    for _ in range(clocks):
        await RisingEdge(dut.clk)
        check_uio(dut)
        audio = (int(dut.uio_out.value) >> AUDIO) & 1
        high += audio
        changes += audio != prev
        prev = audio
    dut._log.info(f"audio high on {high} of {clocks} clocks, {changes} changes")
    assert clocks // 16 < high <= clocks * 7 // 8, f"audio high on {high} of {clocks} clocks"
    assert changes > 1000, f"audio changed {changes} times in {clocks} clocks"
