![test](../../actions/workflows/test.yaml/badge.svg) ![ice40](../../actions/workflows/ice40.yaml/badge.svg) ![gowin](../../actions/workflows/gowin.yaml/badge.svg) ![gds](../../actions/workflows/gds.yaml/badge.svg) ![docs](../../actions/workflows/docs.yaml/badge.svg)

# Tiny Breakout

A complete VGA brick-breaker game in a single [Tiny Tapeout](https://tinytapeout.com) tile.

![Tiny Breakout, mid-game](docs/img/gameplay.png)

Tiny Breakout consists of some 14,600 transistors in 1,600 standard cells. There is no
processor or frame buffer; the game keeps its state in about 200 flip-flops.

It has been submitted to Tiny Tapeout's SKY26e shuttle (SkyWater's 130 nm process). It also
[runs on FPGAs](#on-an-fpga).

## The game

The rules are in [docs/info.md](docs/info.md). Play with an SNES controller
or plain buttons; SELECT hands the paddle over to autoplay, and with no controller connected
the game plays itself as a demo.

## How it fits in one tile

There is no frame buffer. Each pixel is computed from the game's state as the beam draws it.

- Collisions are found in the picture itself. When the beam draws a ball pixel over a brick or
  the paddle, the ball has hit it. Where the ball overlaps the brick shows which side it came
  from. Autoplay works the same way: it notes which part of the paddle is under the ball
  as the beam goes past, which takes two 2-bit comparisons instead of an adder
  ([autoplay.sv](src/autoplay.sv)).
- The bricks live in a ring of flip-flops that turns with the beam, so the brick being drawn is
  always in the same flip-flop. That saves a 48-way multiplexer and halves the brick wall's
  logic. The five rows behind the one being drawn turn by a bit on every clock, a line being a
  whole number of turns, so they need no enable and use smaller flip-flops
  ([brick_wall.sv](src/brick_wall.sv)).
- The brick walls are computed as the ring fills. The bottom row, computed first, comes from a
  5-bit LFSR, and each row computed after it grows from the one before by an elementary,
  one-dimensional cellular automaton (Wolfram's rule 150 or 182). This gives 21 different brick
  walls in under 1% of the tile.
- The ball's velocity is three bits: left or right, up or down, steep or flat. A bounce just
  sets or flips some of them, where signed velocities would need negations and absolute values.
  Its step never grows: the ball moves two to six times every four frames as it speeds up from
  1x to 3x.
- The sound effects are square waves timed by the video's line clock, so a 7-bit counter is
  enough for a note's pitch. Each of the two voices keeps only which sound it is playing and
  for how many frames, and works out the note and volume from those. The noise for the paddle
  and wall sounds is a hash of the line number and the frame's random number, so it needs no
  generator of its own. The voices share the one audio pin by taking turns every clock, each
  setting its volume by pulse width. The bass is a single flip-flop that divides the tune's
  square wave by two, an octave down ([sound.sv](src/sound.sv)).

[![The hardened tile](docs/img/layout.png)](https://gds-explorer.tinytapeout.com/viewer?file=https://zvea.github.io/tiny-breakout/tinytapeout.oas&pdk=sky130A)

*The hardened tile: click it to explore the layout in 3D.*

## Trying it without hardware

The interactive player runs the design's RTL in Verilator and streams the picture to a browser.
Every clock is simulated, so the game's speed depends on the processor. A fast one, such as an
Apple M4, can simulate the chip in real time. It needs Verilator 4 (see
[test/README.md](test/README.md#setting-up)):

```sh
cd sim/play
./build.sh
./obj_serve/Vtt_um_tiny_breakout    # then open http://localhost:8765/
```

The arrow keys move the paddle, <kbd>Space</kbd> launches the ball (or starts a new game after
game over), <kbd>A</kbd> switches autoplay on and off (an arrow key also switches it off) and
<kbd>R</kbd> resets the chip. The page starts muted; the speaker button or <kbd>M</kbd> turns
the sound on and off. The player always acts as a connected controller, so the demo never
runs there; [tools/movie.sh](tools/movie.sh) records the demo as a movie (see
[tools/README.md](tools/README.md)).

## Hardware

- A Tiny Tapeout chip with this design selected, clocked at 25.175 MHz.
- A [TinyVGA PMOD](https://github.com/mole99/tiny-vga) on the outputs, and a VGA monitor.
- A [Gamepad PMOD](https://github.com/psychogenic/gamepad-pmod) and an SNES-compatible
  controller on the inputs, or active-high buttons on `ui[0]` to `ui[2]` and a switch on
  `ui[3]` for autoplay.
- Optionally, an [Audio Pmod](https://github.com/MichaelBell/tt-audio-pmod) on `uio[7]` for
  sound.

The controls and which pins each Pmod uses are in [docs/info.md](docs/info.md); the pinout, bit
by bit, is in [info.yaml](info.yaml).

## On an FPGA

The same design also runs on two FPGA boards:

- [Tiny Tapeout's iCE40UP5K board](fpga/ice40up5k/README.md): the full game, with VGA, an SNES
  controller and sound.
- [Sipeed Tang Nano 20K](fpga/tang_nano_20k/README.md): the demo, with HDMI picture and sound.

## Licence

[Apache 2.0](LICENSE).
