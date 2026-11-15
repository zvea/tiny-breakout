# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""The interactive player (sim/play): each frame it streams says whether the chip is playing by
itself, as the chip sees it (the AUTOPLAY pin, SELECT on the gamepad, or the demo it starts
when a game waits at its start with nothing pressed), so the page can show it.

Builds the player into a scratch directory with sim/play/build.sh, runs it on a free port and
reads its stream. One to two minutes: the demo starts some 1,100 frames into the game, and the
player runs at up to 60 fps. Needs Verilator 4.x, as the player does.
"""

import http.client
import socket
import struct
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent.parent
PLAY = ROOT / "sim" / "play"

LEFT, AUTOPLAY = 1, 8  # /keys bits


@pytest.fixture
def player(tmp_path: Path):
    """The player, built and running; yields its port."""
    out = tmp_path / "obj"
    result = subprocess.run([PLAY / "build.sh", out], capture_output=True, text=True)
    assert result.returncode == 0, result.stdout + result.stderr
    with socket.socket() as s:  # a free port (the player binds the loopback address)
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    server = subprocess.Popen(
        [out / "Vtt_um_tiny_breakout", str(port), PLAY / "index.html"],
        stdout=subprocess.PIPE, text=True,
    )  # fmt: skip
    try:
        assert "http://localhost" in server.stdout.readline()  # listening
        yield port
    finally:
        server.kill()
        server.wait()


class Stream:
    """The player's /stream: each frame's header is [video length][audio samples][state],
    u32 little-endian, then the video and the audio (s16 per sample). State bit 0: autoplay."""

    def __init__(self, port: int):
        self.port = port
        self.conn = http.client.HTTPConnection("127.0.0.1", port, timeout=10)
        self.conn.request("GET", "/stream")
        self.resp = self.conn.getresponse()
        assert self.resp.status == 200

    def autoplay(self) -> bool:
        """The next frame's autoplay bit."""
        header = self.resp.read(12)
        assert len(header) == 12, "the stream ended"
        video, samples, state = struct.unpack("<III", header)
        assert video != 0xFFFFFFFF, "taken over by another viewer"
        # At most a (count, colour) pair per pixel, and a second of sound
        assert video <= 2 * 640 * 480 and samples <= 48000, f"not a frame header: {header!r}"
        body = self.resp.read(video + 2 * samples)
        assert len(body) == video + 2 * samples, "the stream ended mid-frame"
        return bool(state & 1)

    def keys(self, k: int) -> None:
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=10)
        conn.request("GET", f"/keys?k={k}")
        assert conn.getresponse().read() == b"ok"
        conn.close()

    def frames_until(self, on: bool, limit: int) -> int:
        """Frames read until autoplay is `on`, failing after `limit`."""
        for n in range(1, limit + 1):
            if self.autoplay() == on:
                return n
        pytest.fail(f"autoplay not {'on' if on else 'off'} after {limit} frames", pytrace=False)


def test_stream_reports_the_chips_autoplay(player: int):
    s = Stream(player)
    # A new game: its wall is built, then it waits at the start with nothing pressed (the
    # player's gamepad is connected), until the demo starts at about frame 1,100. The chip
    # counts a report's bits from the latch that ends the report before, so it sees the gamepad
    # only in its second report, early in frame 2: the first frame ends with the demo, as with
    # no controller.
    s.autoplay()
    first = [s.autoplay() for _ in range(100)]
    assert not any(first), f"autoplay on at frame {first.index(True) + 2} of a new game"
    s.frames_until(True, 2000)
    # LEFT ends the demo; the AUTOPLAY pin switches autoplay on and off
    s.keys(LEFT)
    s.frames_until(False, 10)
    s.keys(AUTOPLAY)
    s.frames_until(True, 10)
    s.keys(0)
    s.frames_until(False, 10)
