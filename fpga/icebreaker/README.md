# Tiny Breakout on the iCEBreaker

Tiny Breakout on a [1BitSquared iCEBreaker](https://1bitsquared.com/collections/fpga/products/icebreaker)
(Lattice iCE40UP5K), with the picture on a VGA monitor through MuseLab's
[PMOD-VGA v1.1](https://github.com/wuxx/icesugar/blob/master/schematic/pmod-vga-v1.1.pdf), and
the snap-off board's three buttons as the controller. There is no sound.

The game is the Tiny Tapeout design itself, `tt_um_tiny_breakout` from [src/](../../src),
unchanged. This folder adds what the Tiny Tapeout board would supply (a clock and a reset) and
maps the game's pins onto the iCEBreaker's.

**Status:** it builds, meets timing, passes its simulation test, and works on a board, with
MuseLab's PMOD-VGA v1.1.

## What you need

- An iCEBreaker with its snap-off board attached (or plugged into PMOD2), MuseLab's PMOD-VGA
  v1.1 (or Digilent's Pmod VGA, untested, with the pins changed: see
  [The VGA Pmod](#the-vga-pmod)) and a VGA monitor.
- Python 3, for this board's build tools (installed below).
- A programmer for the bitstream: `iceprog`, from [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build),
  or [openFPGALoader](https://github.com/trabucayre/openFPGALoader).
- For the test only: Verilator 5 (the project's `.tools/env`, see [test/README.md](../../test/README.md)).

## Setup

From the top of the repo:

```sh
python3 -m venv fpga/icebreaker/.venv
fpga/icebreaker/.venv/bin/pip install -r fpga/icebreaker/tools/requirements.txt
```

The board has its own `.venv`, as the Tang Nano 20K's does, because its yosys is newer than the
project's `.venv` one, whose yosys the area tools in [tools/](../../tools) depend on. Both are
git-ignored.

## Build, load, test

```sh
fpga/icebreaker/tools/build.sh                  # build/icebreaker.bin, under a minute
iceprog fpga/icebreaker/build/icebreaker.bin    # into flash
fpga/icebreaker/test/run.sh                     # simulation test, about a minute
```

The programmer writes the board's flash, which the FPGA loads at power-on. Loading the FPGA
directly (`iceprog -S`) needs solder jumpers on the board changed (J15, J16 and J18 in its
schematic), so on a stock board flash is the only way.

With openFPGALoader instead of iceprog, the board's name is `ice40_generic`:

```sh
openFPGALoader -b ice40_generic fpga/icebreaker/build/icebreaker.bin
```

`tools/build.sh` takes an optional placement seed. The logs are in `build/`. The build tools
are open source and from PyPI: yosys (with its yosys-slang front end for the SystemVerilog),
nextpnr and icepack, as WebAssembly builds (YoWASP), so they run the same on Linux and macOS.
The programmers talk to the board over USB, so they are native programs.

On Linux, the programmers need access to the board's USB interface (an FTDI FT2232H, USB ID
0403:6010), for example with a udev rule. On macOS, if the board isn't found, Apple's own FTDI
serial driver may have claimed it: close anything that has its serial port open.

CI ([.github/workflows/fpga.yaml](../../.github/workflows/fpga.yaml)) does both on every push:
it builds the bitstream, with the other boards', into the one download
`tiny-breakout-fpga-<short commit>` (see [../README.md](../README.md)), and runs the test with
Ubuntu's Verilator.

## Playing

Plug the VGA Pmod into PMOD1A and PMOD1B, chips up, with its VGA connector pointing away from
the board, and the VGA cable into the monitor. The game starts in its demo: it plays itself
until a button is pressed, then a new game starts.

Hold the board with the snap-off board nearest you:

| Button | Does |
|---|---|
| Button 3 (left) | Paddle left |
| Button 1 (right) | Paddle right |
| Button 2 (middle) | Fire: launches the ball, or starts a new game after game over |
| User button (main board) | Reset: back to the demo |

The buttons are assigned in [src/icebreaker.pcf](src/icebreaker.pcf): to hold the board
another way, swap the pin numbers there.

## How it works

The folders follow the top of the repo: `src/` for the design, `test/` for its test, `tools/`
for the scripts.

| File | What it is |
|---|---|
| [src/icebreaker_top.v](src/icebreaker_top.v) | Top module: the PLL (an iCE40 primitive) |
| [src/breakout_vga.sv](src/breakout_vga.sv) | The game, its reset, and its pins mapped onto a 12-bit VGA Pmod; nothing specific to an FPGA |
| [src/icebreaker.pcf](src/icebreaker.pcf) | Pins |
| [test/](test) | The simulation test |
| [tools/build.sh](tools/build.sh), [tools/common.sh](tools/common.sh) | The build, and what it shares with the test |
| [tools/requirements.txt](tools/requirements.txt) | The build's tools, for this board's `.venv` |

**Clock.** The PLL makes 25.125 MHz from the board's 12 MHz oscillator (12 x 67 / 32): the
nearest it comes to the 25.175 MHz the game is designed for, 0.2% slow. So the picture is
59.82 Hz instead of 59.94 Hz, which monitors accept, and the game runs 0.2% slow.

**Reset.** The game is held in reset until the PLL has locked and 256 clocks have passed, and
while the user button is pressed.

**Picture.** The game makes 2 bits per colour, for the TinyVGA Pmod. The VGA Pmod takes 4, so
each 2-bit level is repeated: 00, 01, 10 and 11 become 0000, 0101, 1010 and 1111, evenly spaced
from black to full brightness. The sync pins are the game's own.

**Buttons.** The snap-off board's buttons go straight to the game's left, right and fire
inputs (ui_in[0..2]), as plain buttons do on the Tiny Tapeout board; the game registers them.
The Gamepad Pmod's inputs are tied low, so the game sees no controller, which is what starts
the demo.

## The VGA Pmod

[src/icebreaker.pcf](src/icebreaker.pcf) is for MuseLab's PMOD-VGA v1.1, plugged in chips up:

| | Pins 1-4 | Pins 7-10 |
|---|---|---|
| PMOD1A | B0..B3 | R0..R3 |
| PMOD1B | HS, VS (pins 1 and 2) | G0..G3 |

Bit 0 is the least significant. This is how MuseLab's own example drives the module
([vga_pong](https://github.com/wuxx/icesugar/tree/master/src/basic/verilog/vga_pong), for
their iCESugar board, where PMOD2 takes the connector PMOD1A takes here, and PMOD3 the one
PMOD1B takes). MuseLab numbers each connector's second row 12 down to 7, so their pin 12 is
pin 7 here. The module's schematic has each connector's rows the other way round, with R0..R3
and G0..G3 on its pins 1-4, which is Digilent's layout (below): pins wired from the schematic
put the sync on the module's green inputs, and the monitor finds no signal.

Digilent's Pmod VGA has the same signals on the same two connectors, with each connector's rows
the other way from MuseLab's: R0..R3 on PMOD1A's pins 1-4 and B0..B3 on 7-10, G0..G3 on
PMOD1B's pins 1-4, and HS and VS on its pins 7 and 8. That is how other designs drive it, for
example [Xosera](https://github.com/XarkLabs/Xosera) on the iCEBreaker; this design hasn't been
tried with it. For it, the pin file's numbers become:

| Signal | FPGA pins | Pmod pins |
|---|---|---|
| vga_r[0..3] | 4, 2, 47, 45 | PMOD1A 1-4 |
| vga_b[0..3] | 3, 48, 46, 44 | PMOD1A 7-10 |
| vga_g[0..3] | 43, 38, 34, 31 | PMOD1B 1-4 |
| vga_hs_n, vga_vs_n | 42, 36 | PMOD1B 7, 8 |

## The test

[test/run.sh](test/run.sh) simulates `breakout_vga` with Verilator and checks:

1. **Reset:** the game stays in reset until the PLL's lock and 256 clocks after it, and the
   reset button, pressed once mid-frame, resets it at once.
2. **Picture:** on every clock, each colour channel on the pins is the game's 2-bit level
   repeated, taken from the game before its pins, so a swapped channel or reversed level shows;
   and the sync pins follow 640x480's timing, as the standard gives it.
3. **Buttons:** right ends the demo and moves the paddle right, left moves it back, and fire
   launches the ball.

The test covers `breakout_vga`. The build checks that the PLL's settings are legal and that
the pins exist; whether each pin goes to the right place is checked on a board.

## Limits

- No sound: the Audio Pmod would need PMOD2, which the snap-off board uses.
- No SNES controller: the Gamepad Pmod would need a Pmod port, and all three are taken
  (PMOD1A and PMOD1B by the VGA Pmod, PMOD2 by the snap-off board).
- The game runs 0.2% slow (25.125 MHz, see Clock).
