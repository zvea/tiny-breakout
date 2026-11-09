# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for sound: which sound each event starts on which voice, the notes it plays and
how its volume falls, that the tones have the pitch their notes say, how the noise changes,
and that the output interleaves the two voices, each at its volume.

A frame here is one frame_tick; a line is one clock with h_pos at 0, so a whole line costs two
clocks rather than 800.
"""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, FallingEdge, ReadOnly, RisingEdge

from cocotb_run import run

# In the order of sound.sv's enums a_kind_t and b_kind_t: change these with them
A_NONE, A_BRICK, A_PADDLE, A_LOST, A_OVER, A_CLEAR, A_START = range(7)
B_NONE, B_THUMP, B_RUMBLE, B_BASS = range(4)
SCALE = [60, 54, 48, 40, 36, 30, 27, 24]  # half-periods in lines: C4 D4 E4 G4 A4 C5 D5 E5
EVENTS = ["new_game", "paused", "lost", "last", "brick", "paddle", "wall"]


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    for name in EVENTS + ["frame_tick", "fast", "brick_row", "pause_step", "v_pos", "random"]:
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


async def half_periods(dut, signal: str, lines: int) -> list[int]:
    """The lines from each flip of `signal` to the next, over this many lines: only whole
    half-periods, as the lines before the first flip may be the end of one."""
    flips, prev = [], None
    for line in range(lines):
        dut.h_pos.value = 0
        await RisingEdge(dut.clk)
        dut.h_pos.value = 1
        await RisingEdge(dut.clk)
        await ReadOnly()
        v = int(getattr(dut, signal).value)
        if prev is not None and v != prev:
            flips.append(line)
        prev = v
        await RisingEdge(dut.clk)
    return [b - a for a, b in zip(flips, flips[1:])]


@cocotb.test()
async def silent_without_events(dut):
    await start(dut)
    for _ in range(10):
        await frame(dut)
        assert await read(dut, "a_kind", "b_kind", "audio") == [A_NONE, B_NONE, 0]


@cocotb.test()
async def a_brick_plays_its_rows_note_an_octave_down_fading_over_5_frames(dut):
    """Red (row 0) highest; a fast ball two scale steps up. All within 15 cents of their notes."""
    await start(dut)
    for row in range(6):
        for fast in (False, True):
            await frame(dut, "brick", row=row, fast=fast)
            step = min(7, 5 - row + (2 if fast else 0))
            vols = []
            for _ in range(6):
                kind, note, vol = await read(dut, "a_kind", "a_note", "a_vol")
                if kind == A_BRICK and vol > 0:  # it ends a frame after the last step
                    assert note == SCALE[step], f"row {row}, fast {fast}: N {note}"
                    vols.append(vol)
                await frame(dut)
            assert vols == [5, 4, 3, 2, 1], f"row {row}: volumes {vols}"
            assert (await read(dut, "a_kind"))[0] == A_NONE


@cocotb.test()
async def the_tone_has_the_pitch_of_its_note(dut):
    """A note of N flips the square wave every N lines, exactly. Not N = 30, the note when
    nothing plays, so that a counter ignoring the note would fail."""
    await start(dut)
    await frame(dut, "brick", row=5, fast=True)  # scale step 2: E5, an octave down E4, N = 48
    periods = await half_periods(dut, "a_square", 480)
    assert len(periods) >= 8 and set(periods) == {48}, f"half-periods {periods} (expected 48)"


@cocotb.test()
async def the_bass_is_voice_a_an_octave_down(dut):
    """Voice B's square wave in the new game's call has exactly twice voice A's half-period:
    G3 (80 lines) under G4 (N = 40) for the first 8 frames, and C5 (30 lines) under C6 (N = 15)
    from frame 24."""
    await start(dut)
    await frame(dut, "new_game")
    periods = await half_periods(dut, "a_sub", 400)
    assert len(periods) >= 3 and set(periods) == {80}, f"G3: half-periods {periods} (expected 80)"
    for _ in range(24):
        await frame(dut)
    periods = await half_periods(dut, "a_sub", 360)
    assert len(periods) >= 10 and set(periods) == {30}, f"C5: half-periods {periods} (expected 30)"


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
async def the_trombone_falls_g_f_sharp_f_then_wobbles_on_e_and_ends(dut):
    """G4, F#4, F4 (N = 40, 42, 45) for 8 frames each, then E4 (48) wobbling flat, to 49 and
    50 and back, for 32 frames, its volume falling a step every 16 frames from 6; silent on
    frame 56, the frame it ends, and gone the frame after."""
    await start(dut)
    await frame(dut, "lost", "last")
    wobble = [48, 48, 49, 49, 50, 50, 49, 49]
    for f, note in enumerate([40] * 8 + [42] * 8 + [45] * 8 + wobble * 4):
        heard = await read(dut, "a_kind", "a_note", "a_vol")
        assert heard == [A_OVER, note, 6 - f // 16], f"frame {f}: kind, note, volume {heard}"
        await frame(dut)
    heard = await read(dut, "a_kind", "a_vol")
    assert heard == [A_OVER, 0], f"frame 56: kind, volume {heard}"
    await frame(dut)
    heard = await read(dut, "a_kind")
    assert heard == [A_NONE], f"frame 57: kind {heard}"


@cocotb.test()
async def a_new_game_cuts_the_sigh_and_the_trombone_short_a_brick_or_the_paddle_doesnt(dut):
    """A brick or the paddle leaves a lost ball's sigh or the trombone playing on, without
    restarting it; a new game replaces either with its call, from the start."""
    await start(dut)
    for sound, events, kind in (("sigh", ["lost"], A_LOST), ("trombone", ["lost", "last"], A_OVER)):
        await frame(dut, *events)
        await frame(dut, "brick")
        await frame(dut, "paddle")
        heard = await read(dut, "a_kind", "a_t")
        assert heard == [kind, 2], f"the {sound} after a brick and the paddle: kind, a_t {heard}"
        await frame(dut, "new_game")
        heard = await read(dut, "a_kind", "a_t", "a_note")
        assert heard == [A_START, 0, 40], f"the {sound} after a new game: kind, a_t, note {heard}"


@cocotb.test()
async def a_new_game_plays_its_call_on_both_voices(dut):
    """G4, D5, G5 for 8 frames each, then C6 for 24, with voice B's bass at the same volume."""
    await start(dut)
    await frame(dut, "new_game")
    assert await read(dut, "a_kind", "a_note", "b_kind") == [A_START, 40, B_BASS]
    for f in range(1, 48):
        await frame(dut)
        a_kind, a_note, a_vol, b_kind, b_vol = await read(
            dut, "a_kind", "a_note", "a_vol", "b_kind", "b_vol")
        assert (a_kind, b_kind) == (A_START, B_BASS), f"frame {f}: kinds {a_kind}, {b_kind}"
        assert a_note == [40, 27, 20, 15][min(f // 8, 3)], f"frame {f}: note {a_note}"
        assert a_vol > 0 and b_vol == a_vol, f"frame {f}: volumes {a_vol}, {b_vol}"
    await frame(dut)  # the frame they end: both silent
    assert await read(dut, "a_vol", "b_vol") == [0, 0]
    for _ in range(2):
        await frame(dut)
    assert await read(dut, "a_kind", "b_kind") == [A_NONE, B_NONE]


@cocotb.test()
async def a_wall_rumbles_under_a_brick_and_the_paddle_takes_both_voices(dut):
    """A wall starts the rumble on voice B and leaves voice A's brick playing; the paddle
    replaces both, with the thock on voice A and the thump, from volume 4, on voice B."""
    await start(dut)
    await frame(dut, "brick", row=2)
    await frame(dut, "wall")
    assert await read(dut, "a_kind", "b_kind", "b_vol") == [A_BRICK, B_RUMBLE, 3]
    await frame(dut, "paddle")
    assert await read(dut, "a_kind", "b_kind", "b_vol") == [A_PADDLE, B_THUMP, 4]


@cocotb.test()
async def the_cleared_wall_fanfare_follows_the_pause_timer(dut):
    """C, E, G for two pause steps each, then a held high C, over voice B's bass at the same
    volume; both end with the pause."""
    await start(dut)
    for step, note in [(0, 30), (2, 24), (4, 20), (6, 15), (15, 15)]:
        dut.pause_step.value = step
        await frame(dut, "paused")
        a_kind, a_note, a_vol, b_kind, b_vol = await read(
            dut, "a_kind", "a_note", "a_vol", "b_kind", "b_vol")
        assert (a_kind, a_note) == (A_CLEAR, note), f"pause step {step}"
        assert b_kind == B_BASS and b_vol == a_vol > 0, f"pause step {step}: bass {b_kind}, {b_vol}"
    await frame(dut)
    assert (await read(dut, "a_kind", "b_vol")) == [A_NONE, 0]
    await frame(dut)
    assert (await read(dut, "b_kind"))[0] == B_NONE


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


@cocotb.test()
async def each_voice_is_high_for_the_first_volume_steps_of_8(dut):
    """The PWM at the output: on voice A's clocks (odd h) the output follows its square wave,
    high for the first a_vol of every 8 steps of h[3:1] while the square is 1 and low while
    it is 0; on voice B's (even h), the same for b_vol against its noise, held at 1 here."""
    await start(dut)
    dut.random.value = 0b1000  # with v_pos at 0, the noise is 1
    await frame(dut, "brick", "wall", row=0, fast=True)  # N = 24 (E6 an octave down)
    for a_vol, b_vol in [(5, 3), (4, 2), (3, 1), (2, 0), (1, 0)]:  # the brick and the rumble fade
        squares = set()
        for _ in range(30):  # a flip every 24 lines: both halves of the square wave
            heard = []
            for h in range(16):  # one PWM period, the voices taking turns
                dut.h_pos.value = h  # h 0 steps the line's counters
                await RisingEdge(dut.clk)
                await ReadOnly()
                heard.append(int(dut.audio.value))  # registered at this edge, from this h
                if h == 1:
                    square = int(dut.a_square.value)
                await FallingEdge(dut.clk)
            squares.add(square)
            assert heard[1::2] == [square & (s < a_vol) for s in range(8)], \
                f"voice A at volume {a_vol}, square {square}: {heard[1::2]}"
            assert heard[0::2] == [int(s < b_vol) for s in range(8)], \
                f"voice B at volume {b_vol}: {heard[0::2]}"
        assert squares == {0, 1}, f"volume {a_vol}: the square wave stayed at {squares}"
        await frame(dut)


def test_sound():
    run("sound", ["sound.sv"], "test_sound")
