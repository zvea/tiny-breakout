# Tools

Scripts for measuring and checking the design. They find the repo from their own location,
use the project's `.venv` (for Python, LibreLane and yowasp-yosys), and keep their working
files in `build/` and `runs/`; `flow.sh` also copies the sources into `.exp_src_TAG/` in the
repo root while it runs. All three are git-ignored.

| Script | What it does | Time |
|---|---|---|
| `flow.sh place TAG [SRC_DIR]` | Tiny Tapeout flow up to global placement: TT's utilisation figure | ~4 min |
| `flow.sh harden TAG [SRC_DIR]` | The whole flow: also DRC, LVS, antenna, timing, `warnings.sh`, `lec.sh` and the GDS | ~15 min |
| `flow_avg.sh NAME [SRC_DIR]` | `flow.sh place` for 3 register orderings, and their mean | ~12 min |
| `local_area.sh [REV]` | Local synthesis area of the working tree vs a git revision (5 orderings each) | ~1 min |
| `equiv.sh [REV]` | Formal equivalence of the working tree vs a git revision, for refactors | ~1 min |
| `lec.sh RUN_DIR [SRC_DIR]` | Formal equivalence of the RTL vs a hardened run's final netlist | ~1 min |
| `warnings.sh RUN_DIR [--update]` | A hardened run's warnings: counts, hard failures, kinds of message not in `warnings.ref` | seconds |
| `walls.sh [--png FILE] [SRC_DIR]` | Every wall `wall_pattern.sv` builds after a game's first, with counts; `--png` draws them | ~15 s |
| `movie.sh [-o FILE] [--extra SECONDS] [SRC_DIR]` | A movie of the demo with its sound, from reset into the second level (`build/demo.mp4`; needs Verilator 4 and ffmpeg) | ~11 min |

Notes:

- **Which number counts:** `flow.sh place` gives TT's utilisation. `local_area.sh` is quick but
  only a guide: its differences have been off from the flow's by up to 2x.
- **Noise:** synthesis results shift with the order of register declarations alone (about a
  point of utilisation, or 50-100 µm² locally), so compare means over orderings.
- **Routability:** the only real test is `flow.sh harden` (0 DRC, LVS and antenna errors).
- **Warnings:** the flow passes runs with warnings. `warnings.sh` (run by `flow.sh harden`) fails
  on an inferred latch, a critical disconnected pin, a clock pin over its slew limit or a
  metric missing from `metrics.json` (renamed by a LibreLane upgrade, say), and lists any kind
  of message missing from `warnings.ref`; after checking them, `--update` rewrites
  `warnings.ref` from that run (so kinds the run no longer has go too).
- **RTL vs netlist:** LVS only checks the layout against the netlist. `lec.sh` checks that
  netlist against the RTL, so changes to synthesis or other flow settings can't quietly change
  the logic; `flow.sh harden` runs it and fails if it fails.
- **Setup:** `.venv` as in [test/README.md](../test/README.md#setting-up), and Docker. The flow
  also needs Tiny Tapeout's support tools in `tt/` (git-ignored) and `src/user_config.json`:

  ```sh
  git clone https://github.com/TinyTapeout/tt-support-tools tt
  .venv/bin/pip install -r tt/requirements.txt
  .venv/bin/python tt/tt_tool.py --create-user-config
  ```

  The local scripts need the sky130 PDK, found via `$PDK_ROOT` or ciel's default `~/.ciel`.
  `walls.sh` needs Verilator, from `.tools/env` (as in test/README.md) or `PATH`; its `--png`
  needs Pillow, which is not in `test/requirements.txt` but comes into `.venv` with LibreLane.
  `movie.sh` needs Verilator 4 (like the player), from `.tools/v4` (as in test/README.md) or
  `PATH`, and ffmpeg.
- **Experiments:** `EXTRA_CFG='{"KEY": value}'` overrides flow settings for one run, and
  `GOLD_RENAMES='rename old new'` (several separated by `;`) lets `equiv.sh` pair up renamed
  registers.
- **Trying a new wall layout:** edit `src/wall_pattern.sv` (its header says what brick_wall
  expects of it), then `walls.sh --png build/walls.png` to see every wall it builds, and
  `local_area.sh` for its cost. `.venv/bin/pytest test/unit/test_wall_pattern.py` checks the
  rules any layout must keep (no empty wall), plus the current layout exactly, which a new one
  replaces.
  Then play it: `sim/play/build.sh` and the player.
