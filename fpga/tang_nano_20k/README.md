# Tiny Breakout on the Tang Nano 20K

Tiny Breakout on a [Sipeed Tang Nano 20K](https://wiki.sipeed.com/hardware/en/tang/tang-nano-20k/nano-20k.html)
(Gowin GW2AR-18), with picture and sound over HDMI. There is no controller yet, so the game
plays its demo.

The game is the Tiny Tapeout design itself, `tt_um_tiny_breakout` from [src/](../../src),
unchanged. This folder adds what the Tiny Tapeout board would supply (a clock and a reset) and
turns the game's TinyVGA and Audio Pmod pins into HDMI.

**Status:** it builds, meets timing, passes its simulation test, and works on a board:
picture and sound.

## What you need

- A Tang Nano 20K, and an HDMI monitor or TV, with speakers for the sound.
- Python 3, for this board's tools (installed below).
- [openFPGALoader](https://github.com/trabucayre/openFPGALoader), to load the bitstream.
- For the test only: Verilator 5 (the project's `.tools/env`, see [test/README.md](../../test/README.md)).

Button S1 resets the game.

## Setup

From the top of the repo:

```sh
git submodule update --init fpga/tang_nano_20k/third_party/hdmi
python3 -m venv fpga/tang_nano_20k/.venv
fpga/tang_nano_20k/.venv/bin/pip install -r fpga/tang_nano_20k/tools/requirements.txt
```

The board has its own `.venv` because it needs a newer yosys than the project's `.venv`, whose
yosys the area tools in [tools/](../../tools) depend on. Both are git-ignored.

## Build, load, test

```sh
fpga/tang_nano_20k/tools/build.sh    # build/tn20k.fs, about 2 minutes
openFPGALoader -b tangnano20k fpga/tang_nano_20k/build/tn20k.fs      # until power-off
openFPGALoader -b tangnano20k -f fpga/tang_nano_20k/build/tn20k.fs   # into flash
fpga/tang_nano_20k/test/run.sh       # simulation test, about 3 minutes
```

`tools/build.sh` takes an optional placement seed. The logs are in `build/`. The tools are all
open source: yosys (with its yosys-slang front end for the SystemVerilog), nextpnr and
apicula's `gowin_pack`, as WebAssembly builds from PyPI.

CI ([.github/workflows/gowin.yaml](../../.github/workflows/gowin.yaml))
does both on every push: it builds the bitstream, uploaded as the artifact
`fpga_tang_nano_20k_bitstream`, and runs the test with Ubuntu's Verilator.

## How it works

The folders follow the top of the repo: `src/` for the design, `test/` for its test, `tools/`
for the scripts.

| File | What it is |
|---|---|
| [src/tn20k_top.v](src/tn20k_top.v) | Top module: the PLL, the clock divider and the HDMI pins' LVDS buffers (Gowin primitives) |
| [src/breakout_hdmi.sv](src/breakout_hdmi.sv) | The game and the HDMI transmitter, joined; nothing specific to an FPGA |
| [src/tn20k.cst](src/tn20k.cst) | Pins |
| [test/](test) | The simulation test |
| [tools/build.sh](tools/build.sh), [tools/common.sh](tools/common.sh) | The build, and what it shares with the test |
| [tools/requirements.txt](tools/requirements.txt) | The build's tools, for this board's `.venv` |
| [third_party/hdmi](third_party/hdmi) | [hdl-util/hdmi](https://github.com/hdl-util/hdmi), a git submodule, with one fix (below) |

**Clocks.** The PLL makes 126 MHz from the board's 27 MHz crystal (27 x 14 / 3), and a divider
makes 25.2 MHz from that. 25.2 MHz is the 60.00 Hz form of 640x480: 0.1% faster than the
25.175 MHz the game is designed for, so the game runs 0.1% fast and its notes are 0.1% sharp.
The 126 MHz clock drives the serialisers: each 10-bit TMDS word goes out in 5 clocks, two bits
per clock.

**Picture.** hdl-util makes its own frame timing, with the same 800x525 frame as the game's
`vga_timing` and the picture at the top left. One register resets both, so their counters
start on the same clock and stay equal. The game's pins are registered, a clock behind its
counter, and hdl-util takes its colour a clock behind its own: they line up. Each 2-bit colour
level is repeated to fill 8 bits: 00, 55, AA, FF.

**Sound.** The game's audio pin is PWM, which the Audio Pmod's filter would average. Here it
becomes 48 kHz samples the way the simulator's player makes them ([sim/play/sim.h](../../sim/play/sim.h)),
so the board sounds like the player: a 3rd-order CIC filter decimating by 525 (at 25.2 MHz, a
48 kHz sample is exactly 525 clocks), then a 50 Hz high-pass standing in for the Pmod's AC
coupling, so the sound has no DC. The samples go to hdl-util as 16-bit audio, the same on both
channels. The board's own speaker amplifier isn't used.

## The fix to hdl-util

yosys's own front end can't read hdl-util (its ports are unpacked arrays), and yosys-slang
rejects two variables that are assigned both with `=` and `<=` in one block. A two-character
fix makes each one's reset assignment match its others, with the same behaviour. It is
proposed upstream ([hdl-util/hdmi#58](https://github.com/hdl-util/hdmi/pull/58)); until it is
merged, the submodule comes from a fork,
[zvea/hdmi](https://github.com/zvea/hdmi/commits/nonblocking-assignments): upstream plus that
one commit.

## The test

[test/run.sh](test/run.sh) simulates `breakout_hdmi` with Verilator and checks:

1. **Lockstep:** hdl-util's frame counter equals the game's on every clock.
2. **Picture:** the pixels hdl-util sends are the game's visible pixels, in order, none
   missing or extra: so the picture is neither shifted nor cropped.
3. **Sound:** the samples sent are the player's: the test runs sim.h's code on the audio pin
   (its CIC filter must match exactly, its high-pass to within rounding). The demo must make
   some sound within the run, or the check would prove nothing.

Verilator can't evaluate one of hdl-util's audio parameters (a real cast to int), so the test
sets `breakout_hdmi`'s `DVI_ONLY`, and hdl-util sends video only (DVI). The picture path is
the same code in both forms. The sound checks are on this design's side, before hdl-util, so
hdl-util's audio packets are tested only on a real screen.

## Limits

- No controller. The game's inputs are tied off, so it plays its demo.
- The picture is 0.1% fast (25.2 MHz, see Clocks).
- HDMI audio needs an HDMI screen: a DVI-only monitor may not show the picture either. For
  one, build with `breakout_hdmi`'s `DVI_ONLY` parameter set: picture only, no sound.
