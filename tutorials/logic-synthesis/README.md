# Logic synthesis tutorial: sources

The tutorial shows how Yosys turned Tiny Breakout's RTL into a netlist in one run of the flow:
`runs/exp_rowtail`, the run the [physical design tutorial](../physical-design/README.md) shows.
Everything it shows comes from that run, or from reruns checked to be identical to it.

| File | What it does |
|---|---|
| [capture/](capture/) | Re-runs the run's synthesis step in LibreLane's container, twice, and checks both reruns against the run (below). |

## Capture

`capture/capture.py` re-runs step `06-yosys-synthesis` with the run's own command (from its
`COMMANDS` file), configuration and liberty file. The sources are commit 8e82a8f's `src/`,
with `src/brick_wall.sv` replaced by the run's version,
[../physical-design/provenance/brick_wall.sv](../physical-design/provenance/brick_wall.sv). The
container sees every file at the path the run used: the rebuilt sources where the run read its
sources, and the rerun's output folder where the run's step folder was.

It makes two captures:

1. **plain**: the step as the run ran it, except that both ABC calls keep their temporary
   files (`-nocleanup`): `input.blif`, `abc.script` and `output.blif`.
2. **dumps**: the same, with the design written after every command of the synthesis
   script. Dumps are Yosys JSON, except while the design still has processes (`always`
   blocks not yet turned into cells): JSON cannot hold those, so these dumps are RTLIL,
   Yosys's own text format. A dump writes a copy of the design, so it cannot change the
   design. The copy is sorted by name. The dump is written inside a log level of its own, so
   the log's numbering stays the same.

Each capture's `manifest.json` lists its inputs with their SHA-256 (sources, configuration,
liberty files, the container image, the Yosys version), the container command, its outputs
and the results of its checks.

### Checks

The plain capture against the run:

- `tt_um_tiny_breakout.nl.v` and `tt_um_tiny_breakout.nl.v.json` are byte-identical.
- The step's other outputs are byte-identical: the ABC script, the SDC file for ABC and the
  reports. Both step folders must hold the same files, apart from the netlists (checked
  above), the two inputs the capture copies in (`config.json`, `extra.json`) and the files
  LibreLane writes around the step (`COMMANDS`, `runtime.txt`, `state_in.json`,
  `state_out.json`, `yosys-synthesis.log`, `yosys-synthesis.process_stats.json`).
- The Yosys log is identical after normalisation (below).
- Both ABC calls kept their three files.

The dump capture against the plain one, and against its own log:

- The netlists are byte-identical to the plain capture's.
- Its log, with the dumps' log lines taken out, is identical to the plain capture's after
  normalisation. A dump's lines are its header, the blank line before it, and for RTLIL the
  line with the file name. Yosys prints that blank line only if the log does not already
  end with one. So where a dump is followed by a line that is not blank, the blank line
  before it is kept if the line before that is not blank and the plain log has a blank line
  there followed by the same line.
- There is one dump per numbered top-level command of the log, in order. Each command's
  header must name it. The script prints a few headers of its own between commands, and
  the hook records them. Only one command may print a second top-level header: `hierarchy`,
  with "Executing AST frontend in derive mode". The manifest lists these. A command that
  prints no header must leave the design unchanged: its dump must be byte-identical to the
  one before.
- Each of the log's statistics printouts has the same cell counts by type as the dump after
  that command.
- The last dump equals `tt_um_tiny_breakout.nl.v.json`, apart from the order of each
  module's attributes, which the copy does not keep. Every other key must be in the same
  order.

If a log or dump cannot be read as expected, the capture records that as a failed check.

### Log normalisation

Logs are compared line by line after three changes, defined in
[capture/logs.py](capture/logs.py). Everything else must match exactly.

1. ABC's temporary folders have random six-character names: `/tmp/yosys-abc-XXXXXX` in the
   run, and `_tmp_yosys-abc-XXXXXX` in the working folder when they are kept. Both become
   `ABC_TEMP_DIR`.
2. The lines `Removing temp directory.` and `Removing global temp directory.` are dropped.
   Yosys prints them only when it removes those folders.
3. In lines from ABC (starting `ABC: `), timings such as `time =     0.42 sec` become
   `time = <time> sec`.

### Outputs

In the output folder:

- `rtl/src/`: the rebuilt sources.
- `plain/` and `dumps/`: each has `yosys-synthesis.log`, `manifest.json`, `step/` (the step's
  outputs), `abc/` (the kept ABC folders, one per call) and `tmp/` (one `yosys-abc-*`
  folder per call, each with the `stdcells.genlib` Yosys wrote for ABC). The plain
  capture's manifest says which ABC folder belongs to which call.
- `dumps/dumps/raw/`: every dump, numbered in command order, and `commands.jsonl`, the
  script's commands and its own headers, in order.
- `dumps/dumps/after/NNN.json` (or `NNN.il`): a link to the dump after numbered command NNN
  of the log.

### Running it

In the project's `.venv`, from the repository root. The capture needs Docker and LibreLane
3.0.14's image,
`ghcr.io/librelane/librelane@sha256:f91b21d75f79871f9ccf37451020b5d2f7b3236881a997ff709c561e8280a30f`
(Yosys 0.62). Each container is capped at 2 GB. The two runs take about 40 seconds in all.
To run a command before each container run, for example one that waits for free memory,
give it with `--gate` or in the `CAPTURE_GATE` environment variable.

```sh
.venv/bin/python tutorials/logic-synthesis/capture/capture.py runs/exp_rowtail OUT_DIR
.venv/bin/python tutorials/logic-synthesis/capture/capture.py --prove-only runs/exp_rowtail OUT_DIR
.venv/bin/pytest tutorials/logic-synthesis/capture          # unit tests, under a second
.venv/bin/pytest tutorials/logic-synthesis/capture --slow   # also the full capture, in a temporary folder
```

`capture.py` prints each check's result. It exits 0 if every check passes and 1 if one
fails. It refuses to write over an earlier capture. `--prove-only` runs the checks again on
the captures in `OUT_DIR` and rewrites their manifests.
