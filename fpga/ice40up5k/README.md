# Tiny Breakout on Tiny Tapeout's iCE40UP5K FPGA board

Tiny Breakout on Tiny Tapeout's FPGA breakout board: an iCE40UP5K that plugs into the Tiny
Tapeout demo board in place of the chip, so the design runs with the same Pmods (VGA, gamepad,
audio) before, or without, the silicon.

This build is Tiny Tapeout's own: its flow ([tt-support-tools](https://github.com/TinyTapeout/tt-support-tools)'
`tt_fpga.py`), its wrapper around `tt_um_tiny_breakout` and its pins for the board. So unlike
[../tang_nano_20k](../tang_nano_20k), this folder has no `src/`: the design is the top-level
[src/](../../src), unchanged, and Tiny Tapeout supplies the rest.

## CI

[.github/workflows/fpga_ice40up5k.yaml](../../.github/workflows/fpga_ice40up5k.yaml) builds
the bitstream on every push, with Tiny Tapeout's GitHub action, and uploads it as the artifact
`fpga_bitstream`. It places and routes against the board's clock, `clock_hz` in
[info.yaml](../../info.yaml) (25.175 MHz), and fails if the design is slower than that.

The action installs the latest tools each time (a nightly oss-cad-suite, and tt-support-tools
from its main branch), so two builds of the same commit can differ a little.

## Building locally

[tools/build.sh](tools/build.sh) runs the same two steps as the action, against the same
clock and with the same placement seed (10, or the one given):

```sh
fpga/ice40up5k/tools/build.sh
```

It needs:

- Tiny Tapeout's support tools in `tt/`, set up as in [tools/README.md](../../tools/README.md)
  (Setup), with the project's `.venv`.
- yosys, nextpnr-ice40 and icepack on `PATH`, as the action has them: for example from
  [oss-cad-suite](https://github.com/YosysHQ/oss-cad-suite-build).

The flow writes to the top-level `build/`: `tt_um_tiny_breakout.bin` is the bitstream, and
`02-nextpnr.log` has the timing.

To load the bitstream onto the board, see Tiny Tapeout's documentation for the FPGA breakout
board.
