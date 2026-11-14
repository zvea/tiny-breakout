# Tiny Breakout on the FabricFox

Tiny Breakout on the FabricFox FPGASIC (rev 2.0, Lattice iCE40UP5K), the FPGA board of Tiny
Tapeout's [FPGA Development Kit](https://store.tinytapeout.com/products/FPGA-Development-Kit-p813805747).
It plugs into the Tiny Tapeout demo board in place of the chip, so the full game runs with the
chip's Pmods: VGA, the SNES gamepad and sound.

The game is the Tiny Tapeout design itself, `tt_um_tiny_breakout` from [src/](../../src),
unchanged, with the chip's pins. The demo board supplies the clock and the reset, as it does
the chip's, so this folder adds only the pins and the bidirectional pins' I/O cells.

**Status:** it builds, meets timing, and passes its pin test. It has not yet been tried on a
board.

## What you need

- The Tiny Tapeout demo board with the FPGA Development Kit's board in place of the chip.
- The chip's Pmods: the TinyVGA Pmod and a VGA monitor, and if you like the SNES Gamepad Pmod
  and the Audio Pmod. [docs/info.md](../../docs/info.md) says which goes where.
- Python 3, for this board's build tools (installed below), and
  [mpremote](https://docs.micropython.org/en/latest/reference/mpremote.html), to copy the
  bitstream to the demo board.
- For the test only: curl and a network connection, to fetch the board's own pin file.

## Setup

From the top of the repo:

```sh
python3 -m venv fpga/fabricfox/.venv
fpga/fabricfox/.venv/bin/pip install -r fpga/fabricfox/tools/requirements.txt
```

The tools are the iCEBreaker build's, in this board's own `.venv`, git-ignored: yosys (with its
yosys-slang front end for the SystemVerilog), nextpnr and icepack, as WebAssembly builds
(YoWASP) from PyPI.

## Build, load, test

```sh
fpga/fabricfox/tools/build.sh    # build/fabricfox.bin, under a minute
fpga/fabricfox/test/run.sh       # pin test, a second
```

`tools/build.sh` takes an optional placement seed. The logs are in `build/`.

The demo board loads bitstreams onto the FPGA board from its own files, as Tiny Tapeout's
[FPGA guide](https://tinytapeout.com/guides/fpga-breakout/) describes: each `.bin` in its
`/bitstreams/` is a project, named after the file. So copy the bitstream there as
`tt_um_tiny_breakout.bin`, a name that can be typed in Python, as the board's REPL needs:

```sh
mpremote fs cp fpga/fabricfox/build/fabricfox.bin :/bitstreams/tt_um_tiny_breakout.bin
```

The game needs a 25.175 MHz project clock (`clock_hz` in [info.yaml](../../info.yaml)), as the
chip does. The demo board sets a project's clock from its `config.ini`, so add a section for
it there:

```ini
[tt_um_tiny_breakout]
clock_frequency = 25.175e6
```

Then, after a reboot, in the demo board's REPL:

```python
tt.shuttle.tt_um_tiny_breakout.enable()
```

The build places and routes against that clock, and fails if the design is slower.

CI ([.github/workflows/fpga.yaml](../../.github/workflows/fpga.yaml)) builds the bitstream on
every push, with the other boards', into the one download `tiny-breakout-fpga-<short commit>`
(see [../README.md](../README.md)), and runs the pin test.

## How it works

| File | What it is |
|---|---|
| [src/fabricfox_top.v](src/fabricfox_top.v) | Top module: the game, and the bidirectional pins' I/O cells (iCE40 primitives) |
| [src/fabricfox.pcf](src/fabricfox.pcf) | Pins |
| [test/run.sh](test/run.sh) | The pin test |
| [tools/build.sh](tools/build.sh), [tools/common.sh](tools/common.sh) | The build, and what it shares with the test |
| [tools/requirements.txt](tools/requirements.txt) | The build's tools, for this board's `.venv` |

**Pins.** The pin file is written here, from the board's own (`fabricfox.pcf` in Tiny Tapeout's
[breakout-pcb](https://github.com/TinyTapeout/breakout-pcb/tree/nextgenv3/ASIC-simulator/ttdbv3-fpga-ICE40UP5k)
repository). The test fetches the board's file at a fixed commit and checks that ours has
exactly the game's pins (clk, rst_n, ui_in, uo_out and uio), each on the board's pin for it.

**Bidirectional pins.** Each uio pin is an iCE40 I/O cell with a tristate output, enabled by
the game's uio_oe, as the chip's pins are. The game drives only uio[7], the Audio Pmod's pin.

**Tiny Tapeout's flow.** Tiny Tapeout's support tools build a bitstream for this board too
(`tt_fpga.py`, whose default target it is), with the same pins and the same I/O cells. This
build works as the other boards' do instead: its tools are pinned versions, where Tiny
Tapeout's GitHub action installs the latest each time; it reads the SystemVerilog with
yosys-slang, as they do; and it goes into the one download with the rest.
