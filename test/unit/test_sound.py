# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for sound: which sound each event starts on which voice, the notes it plays and
how its volume falls, that the tones have the pitch their notes say, how the noise changes,
and that the output interleaves the two voices.

A frame here is one frame_tick; a line is one clock with h_pos at 0, so a whole line costs two
clocks rather than 800.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from cocotb_run import run

A_NONE, A_BRICK, A_PADDLE, A_LOST, A_OVER, A_CLEAR, A_START = range(7)
B_NONE, B_THUMP, B_RUMBLE, B_CHORD = range(4)
SCALE = [30, 27, 24, 20, 18, 15, 13, 12]  # half-periods in lines: C5 D5 E5 G5 A5 C6 D6 E6
EVENTS = ["new_game", "paused", "lost", "last", "brick", "paddle", "wall"]


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    for name in EVENTS + ["frame_tick", "fast", "brick_row", "pause_step", "frame_phase", "v_pos",
                          "random"]:
        getattr(dut, name).value = 0
    dut.h_pos.value = 1
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def frame(dut, *events: str, row: int | None = None, fast: bool | None = None):
    """One frame_tick with these events. The brick row and `fast` stay as they are unless
    given, as in the game, where they hold until the next brick hit."""
    if row is not None:
        dut.brick_row.value = row
    if fast is not None:
        dut.fast.value = int(fast)
    for name in EVENTS:
        getattr(dut, name).value = int(name in events)
    dut.frame_tick.value = 1
    await RisingEdge(dut.clk)
    dut.frame_tick.value = 0
    for name in EVENTS:
        getattr(dut, name).value = 0
    await RisingEdge(dut.clk)


async def read(dut, *names: str) -> list[int]:
    await ReadOnly()
    values = [int(getattr(dut, n).value) for n in names]
    await RisingEdge(dut.clk)
    return values


async def toggles(dut, signal: str, lines: int) -> int:
    """How often `signal` flips over this many lines."""
    count, prev = 0, None
    for _ in range(lines):
        dut.h_pos.value = 0
        await RisingEdge(dut.clk)
        dut.h_pos.value = 1
        await RisingEdge(dut.clk)
        await ReadOnly()
        v = int(getattr(dut, signal).value)
        count += prev is not None and v != prev
        prev = v
        await RisingEdge(dut.clk)
    return count


@cocotb.test()
async def silent_without_events(dut):
    await start(dut)
    for _ in range(10):
        await frame(dut)
        assert await read(dut, "a_kind", "b_kind", "audio") == [A_NONE, B_NONE, 0]


@cocotb.test()
async def a_brick_plays_its_rows_note_an_octave_down_fading_over_5_frames(dut):
    """Red (row 0) highest; a fast ball two scale steps up."""
    await start(dut)
    for row in range(6):
        for fast in (False, True):
            await frame(dut, "brick", row=row, fast=fast)
            step = min(7, 5 - row + (2 if fast else 0))
            vols = []
            for _ in range(6):
                kind, note, vol = await read(dut, "a_kind", "a_note", "a_vol")
                if kind == A_BRICK and vol > 0:  # it ends a frame after the last step
                    assert note == 2 * SCALE[step], f"row {row}, fast {fast}: N {note}"
                    vols.append(vol)
                await frame(dut)
            assert vols == [5, 4, 3, 2, 1], f"row {row}: volumes {vols}"
            assert (await read(dut, "a_kind"))[0] == A_NONE


@cocotb.test()
async def the_tone_has_the_pitch_of_its_note(dut):
    """A note of N flips the square wave every N lines."""
    await start(dut)
    await frame(dut, "brick", row=0)  # red: C6, an octave down C5, N = 30
    flips = await toggles(dut, "a_square", 600)
    assert flips in (19, 20, 21), f"{flips} flips in 600 lines (expected 20 for N = 30)"


@cocotb.test()
async def a_lost_ball_sighs_and_the_last_one_plays_game_over(dut):
    """Nothing else interrupts either on voice A; the sigh is E-flat, D, then C."""
    await start(dut)
    await frame(dut, "lost")
    notes = []
    for f in range(32):
        kind, note = await read(dut, "a_kind", "a_note")
        assert kind == A_LOST, f"frame {f}: kind {kind}"
        notes.append(note)
        await frame(dut, "brick", "paddle")  # ignored
    assert notes[0] == 25 and notes[10] == 27 and notes[20] == 30
    await frame(dut)  # it ends a frame after the last step
    assert (await read(dut, "a_kind"))[0] == A_NONE
    await frame(dut, "lost", "last")
    assert (await read(dut, "a_kind", "a_note")) == [A_OVER, 40]


@cocotb.test()
async def a_new_game_plays_chords_on_both_voices(dut):
    await start(dut)
    await frame(dut, "new_game")
    assert await read(dut, "a_kind", "a_note", "b_kind", "b_note") == [A_START, 30, B_CHORD, 20]
    for f in range(1, 32):  # both voices throughout: C5 with G5 for 8 frames, C6 with E6 for 24
        await frame(dut)
        a_kind, a_note, a_vol, b_kind, b_note, b_vol = await read(
            dut, "a_kind", "a_note", "a_vol", "b_kind", "b_note", "b_vol")
        assert (a_kind, b_kind) == (A_START, B_CHORD), f"frame {f}: kinds {a_kind}, {b_kind}"
        assert (a_note, b_note) == ((30, 20) if f < 8 else (15, 12)), f"frame {f}"
        assert a_vol > 0 and b_vol > 0, f"frame {f}: volumes {a_vol}, {b_vol}"
    await frame(dut)  # the frame they end: both silent
    assert await read(dut, "a_vol", "b_vol") == [0, 0]
    for _ in range(2):
        await frame(dut)
    assert await read(dut, "a_kind", "b_kind") == [A_NONE, B_NONE]


@cocotb.test()
async def walls_and_the_paddle_thump_on_voice_b_without_cutting_voice_a(dut):
    await start(dut)
    await frame(dut, "brick", row=2)
    await frame(dut, "wall")
    assert await read(dut, "a_kind", "b_kind", "b_vol") == [A_BRICK, B_RUMBLE, 3]
    await frame(dut, "paddle")
    assert await read(dut, "a_kind", "b_kind") == [A_PADDLE, B_THUMP]


@cocotb.test()
async def the_cleared_wall_fanfare_follows_the_pause_timer(dut):
    """C, E, G for two pause steps each, then a held high C."""
    await start(dut)
    for step, note in [(0, 30), (2, 24), (4, 20), (6, 15), (15, 15)]:
        dut.pause_step.value = step
        await frame(dut, "paused")
        assert await read(dut, "a_kind", "a_note") == [A_CLEAR, note], f"pause step {step}"
    await frame(dut)
    assert (await read(dut, "a_kind"))[0] == A_NONE


@cocotb.test()
async def the_noise_changes_every_line_for_the_thump_and_every_8_lines_for_the_rumble(dut):
    """About half the lines (or 8-line blocks) change it, half are 1, and it differs from
    frame to frame with the random number."""
    await start(dut)
    for event, step in (("paddle", 1), ("wall", 8)):
        await frame(dut, event)
        heard = {}
        for random in (1, 6):
            dut.random.value = random
            values = []
            for line in range(525):
                dut.v_pos.value = line
                values += await read(dut, "noise")
            changes = [v for v in range(1, 525) if values[v] != values[v - 1]]
            assert all(v % step == 0 for v in changes), f"{event}: changes off the {step}-line grid"
            blocks = len(range(0, 525, step))
            assert 0.35 * blocks < len(changes) < 0.65 * blocks, f"{event}: {len(changes)} changes"
            assert 0.4 * 525 < sum(values) < 0.6 * 525, f"{event}: {sum(values)} lines of 1"
            heard[random] = values
        differ = sum(a != b for a, b in zip(heard[1], heard[6]))
        assert differ > 0.3 * 525, f"{event}: frames differ in only {differ} lines"


@cocotb.test()
async def the_output_takes_the_voices_in_turn(dut):
    """Voice A on odd clocks of h_pos, voice B on even ones: here only B (a wall) sounds."""
    await start(dut)
    dut.random.value = 0b1000  # the noise is 1 on line 0
    await frame(dut, "wall")
    heard = {0: 0, 1: 0}
    for h in range(2, 400):
        dut.h_pos.value = h
        await RisingEdge(dut.clk)
        await ReadOnly()
        heard[h & 1] += int(dut.audio.value)  # registered at this edge, from this h_pos
        await RisingEdge(dut.clk)
    assert heard[1] == 0 and heard[0] > 0, heard


def test_sound():
    run("sound", ["sound.sv"], "test_sound")
