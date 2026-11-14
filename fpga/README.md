# Tiny Breakout on FPGAs

The same design, `tt_um_tiny_breakout` from [src/](../src), unchanged, on three FPGA boards.
Each board's folder has its build, its test and a README:

| Board | Folder | What runs |
|---|---|---|
| FabricFox FPGASIC, of Tiny Tapeout's FPGA Development Kit, on the Tiny Tapeout demo board | [fabricfox](fabricfox) | The full game, with the chip's Pmods: VGA, the SNES gamepad and sound (not yet tried on a board) |
| 1BitSquared iCEBreaker | [icebreaker](icebreaker) | The game, with VGA through a 12-bit VGA Pmod and the snap-off board's buttons; no sound |
| Sipeed Tang Nano 20K | [tang_nano_20k](tang_nano_20k) | The demo, with HDMI picture and sound |

## The download

CI ([.github/workflows/fpga.yaml](../.github/workflows/fpga.yaml)) builds every board's
bitstream on every push, and uploads them together as one artifact,
`tiny-breakout-fpga-<short commit>`. It is made only when every board builds; when one
doesn't, the logs of those that got that far are uploaded instead, as `fpga-logs-<commit>`.

The zip holds one folder, of the same name:

| File | What it is |
|---|---|
| `README.txt` | The commit, and what each file is, with links to each board's README at that commit |
| `tiny-breakout-fabricfox.bin`, `tiny-breakout-icebreaker.bin`, `tiny-breakout-tang-nano-20k.fs` | The bitstreams |
| `logs/` | Each board's synthesis and place-and-route logs: its resources and timing |
| `LICENSE` | Tiny Breakout's licence (Apache-2.0) |
| `LICENSE-hdl-util-hdmi` | The MIT licence of [hdl-util/hdmi](https://github.com/hdl-util/hdmi) (dual MIT and Apache-2.0), whose HDMI transmitter is in the Tang Nano 20K bitstream |

[tools/package.sh](tools/package.sh) makes the folder, from each board's `build/`; it works
the same locally, after each board's `tools/build.sh`:

```sh
fpga/tools/package.sh dist "$(git rev-parse HEAD)" https://github.com/OWNER/REPO
```

[test/package_test.sh](test/package_test.sh) tests it, on a scratch copy of the files it reads:
the files it gathers and their names, README.txt, and that it refuses, leaving nothing behind,
when anything is missing. CI runs it with the boards' tests.
