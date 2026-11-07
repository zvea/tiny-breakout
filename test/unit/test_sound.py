# SPDX-FileCopyrightText: © 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Unit tests for sound: a square-wave beep per event, its tone a bit of the beam's line
counter, lasting whole frames; higher-ranked events replace lower-ranked beeps; silent when
muted."""

import cocotb
from cocotb.clock import Clock
from cocotb.triggers import ClockCycles, ReadOnly, RisingEdge

from cocotb_run import run

# event: (v_pos bit that is the tone, length in frames), highest rank first
BEEPS = {"lost": (6, 7), "brick": (3, 2), "paddle": (5, 2), "wall": (4, 1)}
EVENTS = list(BEEPS)


async def start(dut):
    cocotb.start_soon(Clock(dut.clk, 40, unit="ns").start())
    dut.frame_tick.value = 0
    dut.mute.value = 0
    dut.v_pos.value = 0
    for e in EVENTS:
        getattr(dut, e).value = 0
    dut.rst_n.value = 0
    await ClockCycles(dut.clk, 3)
    dut.rst_n.value = 1
    await RisingEdge(dut.clk)


async def frame(dut, *events: str, mute: bool = False):
    """One frame_tick pulse with these events."""
    dut.frame_tick.value = 1
    dut.mute.value = int(mute)
    for e in EVENTS:
        getattr(dut, e).value = int(e in events)
    await RisingEdge(dut.clk)
    dut.frame_tick.value = 0
    for e in EVENTS:
        getattr(dut, e).value = 0
    await RisingEdge(dut.clk)


async def heard(dut) -> list[int]:
    """The audio pin for v_pos 0..127, one line value per clock (registered: one clock late)."""
    out = []
    for v in range(128):
        dut.v_pos.value = v
        await RisingEdge(dut.clk)
        await ReadOnly()
        out.append(int(dut.audio.value))
        await RisingEdge(dut.clk)
    return out


def tone(bit: int) -> list[int]:
    return [(v >> bit) & 1 for v in range(128)]


SILENCE = [0] * 128


@cocotb.test()
async def silent_without_events(dut):
    await start(dut)
    for _ in range(3):
        assert await heard(dut) == SILENCE
        await frame(dut)


@cocotb.test()
async def each_event_beeps_its_tone_for_its_length(dut):
    await start(dut)
    for event, (bit, frames) in BEEPS.items():
        await frame(dut, event)
        for f in range(frames):
            assert await heard(dut) == tone(bit), f"{event}: frame {f} of {frames}"
            await frame(dut)
        assert await heard(dut) == SILENCE, f"{event}: still sounding after {frames} frames"


@cocotb.test()
async def higher_rank_replaces_a_beep_lower_rank_does_not(dut):
    await start(dut)
    for i, low in enumerate(EVENTS):
        for high in EVENTS[:i]:  # strictly higher rank
            await frame(dut, low)
            await frame(dut, high)
            assert await heard(dut) == tone(BEEPS[high][0]), f"{high} should replace {low}"
            for _ in range(8):  # let it finish
                await frame(dut)
            if low == "wall":  # the wall never interrupts
                await frame(dut, high)
                await frame(dut, low)
                assert await heard(dut) == tone(BEEPS[high][0]), f"wall interrupted {high}"
                for _ in range(8):
                    await frame(dut)


@cocotb.test()
async def simultaneous_events_play_the_highest_rank(dut):
    await start(dut)
    await frame(dut, *EVENTS)
    assert await heard(dut) == tone(BEEPS["lost"][0])


@cocotb.test()
async def mute_silences_and_ignores_events(dut):
    await start(dut)
    await frame(dut, "lost")
    assert await heard(dut) != SILENCE
    await frame(dut, mute=True)
    assert await heard(dut) == SILENCE
    await frame(dut, "brick", mute=True)
    assert await heard(dut) == SILENCE


def test_sound():
    run("sound", ["sound.sv"], "test_sound")
