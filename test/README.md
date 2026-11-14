# Tests

Three layers, from module to whole game, and formal proofs against reference models:

| Tests | What they check | Command | Time |
|---|---|---|---|
| [unit/](unit) | Each module on its own, through its ports (cocotb) | `pytest test/unit` | ~70 s (Verilator), ~5.5 min (`SIM=icarus`) |
| [test.py](test.py) | The whole chip through its pins, on the RTL or the gate-level netlist (cocotb, Icarus) | `make -B` in `test/` | ~4 min |
| [system/](system), cheap tier | Short gameplay scenarios (the controls, the demo, lost balls, a game's opening and more), judged only from the decoded video output and the audio pin | `pytest test/system -n auto` | ~3 min in parallel (the longest scenarios ~2.2 min, plus ~1 min for a first build) |
| [system/](system), milestone tier | A long game, from a new game to the third brick wall and a restart, and balls lost at speed, judged the same way | `pytest test/system -n auto -m milestone` | ~25 min |
| [formal/](formal) | That a module behaves exactly as its reference model in [reference/](reference), on every clock after reset, in the chip (yosys, k-induction) | `test/formal/prove.sh` | ~2 min |

The system scenarios come in two tiers. The cheap one runs by default and is meant to run all
the time. The milestone tier is one long game that simulates each expensive stretch of play
once (autoplay clearing a brick wall, the pause, the later levels) and carries every check that
needs it, and, beside it, lost_at_speed, which needs autoplay to speed up every ball it loses;
run it at milestones, such as before a harden, with `-m milestone` alone or
`--milestone` for both tiers. The game is deterministic, so the opening scenario plays exactly
the first frames of the long game. The table at the end of [scenarios.cpp](system/scenarios.cpp)
lists the scenarios and their tiers, and each scenario's comment lists what its parts check; a
failure names its part and frame.

CI ([.github/workflows/test.yaml](../.github/workflows/test.yaml)) lints the design with
Ubuntu 24.04's Verilator 5 and runs `test.py` and the unit tests on Icarus 13.0, Tiny Tapeout's
own build, which its GDS workflow also uses to run `test.py` on the gate-level netlist, and
runs the formal proofs. The system scenarios run only locally, because they need
Verilator 4.x. Three workflows build FPGA bitstreams, each uploaded as an artifact:
[ice40](../.github/workflows/ice40.yaml), for Tiny Tapeout's iCE40UP5K FPGA board, placed
and routed against the board's 25.175 MHz clock, so a change that makes the design slower
than that fails it ([fpga/ice40up5k](../fpga/ice40up5k));
[gowin](../.github/workflows/gowin.yaml), for the Sipeed Tang Nano 20K, which also runs that
board's simulation test ([fpga/tang_nano_20k](../fpga/tang_nano_20k)); and
[icebreaker](../.github/workflows/icebreaker.yaml), for the 1BitSquared iCEBreaker, which
also places and routes against its 25.125 MHz clock and runs its simulation test
([fpga/icebreaker](../fpga/icebreaker)).

## Reference models and formal proofs

The design's modules are written for size, and the tricks that make them small also make them
hard to read. [reference/](reference) holds reference models of the same behaviour written to
be read: no tricks, structured by what the game does, never built for the chip. For each one,
a proof in [formal/](formal) shows that the chip's module has exactly the reference's outputs on
every clock after a reset, for any inputs the game can give it.

- [reference/ref_wall.sv](reference/ref_wall.sv): the wall as rows of bricks, cleared by row and
  column. [formal/wall_equiv.sv](formal/wall_equiv.sv) proves [src/brick_wall.sv](../src/brick_wall.sv),
  the turning ring, equal to it; its invariant states which brick each of the ring's flip-flops
  holds, for every beam position.

The reference uses the chip's own [wall_pattern](../src/wall_pattern.sv), the layout of the walls:
a change to the layouts is a change of design, meant for both, and the pattern is too small to be
worth a reference of its own. Only the wall has one: it is the module whose tricks make it hard to
read, and the likeliest one to change for area.

Each proof has two parts. The first proves the module equal to its reference, assuming only
what the rest of the chip guarantees on the module's ports (for the wall: a new wall only at the
frame update, inputs that change only then, a full wall after a reset, a patterned one only when
the wall is empty). The second, [formal/wall_contract.sv](formal/wall_contract.sv), proves on the
whole chip, for any inputs on its pins, that it does guarantee exactly that. Together they hold
for every clock after a reset: a proof by induction is a proof for all time, not a simulation of
some of it. Changing a module's tricks without changing its behaviour keeps its proof passing;
changing its behaviour means changing the reference to match, which is the place to see what
changed.

To add a proof, add `test/formal/NAME.sv` with a top module `NAME`: a `// sources:` line lists the
files it reads (`chip` for the whole design), and `(* connect = "INSTANCE.SIGNAL" *)` on a wire
drives it from a signal inside an instance, as yosys has no hierarchical references.
`test/formal/prove.sh` runs every proof there, or the ones named.

## Setting up

Commands run from the repository root.

**Python** (CI uses 3.11): a virtual environment in `.venv` with the test packages and, for
hardening and [tools/](../tools), LibreLane and yowasp-yosys:

```sh
python3 -m venv .venv
.venv/bin/pip install -r test/requirements.txt librelane==3.0.14 yowasp-yosys==0.62.0.0.post1088
```

**Simulators**: two [micromamba](https://mamba.readthedocs.io/en/latest/installation/micromamba-installation.html)
environments from conda-forge, under `.tools/` (git-ignored). The unit tests use `.tools/env`
when the simulator isn't on `PATH`; the system tests and the player use `.tools/v4` when it is
there, else the Verilator on `PATH`; the full-chip `make` needs `PATH` set, as shown below.
conda-forge's Verilator builds with conda's own C++ compiler, so it is listed too.

```sh
# Verilator 5 and Icarus Verilog: unit tests and lint
micromamba create -p .tools/env -c conda-forge verilator=5.054 iverilog=13.0 gxx_impl_linux-64 make
# Verilator 4: system scenarios and the interactive player (sim/play/sim.h relies on its internals)
micromamba create -p .tools/v4 -c conda-forge verilator=4.228 gxx_impl_linux-64 make
```

**On macOS (Apple Silicon)** conda-forge has no Verilator 4, so build 4.228 from source and put
it on `PATH`; `sim/play/build.sh` picks clang-friendly flags there (tested with the player on an
M4, where it runs in real time). macOS's `bison` is too old, and its `FlexLexer.h` does not match
Homebrew's `flex`, hence the extra paths:

```sh
brew install autoconf bison flex
git clone https://github.com/verilator/verilator ~/github/verilator
cd ~/github/verilator && git checkout v4.228
export PATH="$(brew --prefix bison)/bin:$(brew --prefix flex)/bin:$PATH"
export CPPFLAGS="-I$(brew --prefix flex)/include" CXXFLAGS="-I$(brew --prefix flex)/include"
export LDFLAGS="-L$(brew --prefix flex)/lib"
autoconf && ./configure --prefix="$HOME/opt/verilator-4.228" && make -j8 && make install
# then, in the project: cd sim/play && PATH="$HOME/opt/verilator-4.228/bin:$PATH" ./build.sh
```

## Running

```sh
.venv/bin/pytest test/unit                 # Verilator 5
SIM=icarus .venv/bin/pytest test/unit      # Icarus, as in CI
.venv/bin/pytest test/system -n auto       # cheap tier; needs Verilator 4; one worker per scenario
.venv/bin/pytest test/system -n auto -m milestone  # the milestone tier alone
.venv/bin/pytest test/system -n auto --milestone   # both tiers
.venv/bin/pytest test/system               # cheap tier, one after another
.venv/bin/pytest test/system -k controls   # one scenario
(cd test && PATH=$PWD/../.venv/bin:$PWD/../.tools/env/bin:$PATH make -B)   # full chip
```

`test.py`'s Makefile lists the sources in `PROJECT_SOURCES`, read from
[info.yaml](../info.yaml), and the system tests read the same list. Each unit test names the
sources its module needs.

### Gate-level simulation

Harden the design (`tools/flow.sh harden TAG`, see [tools/README.md](../tools/README.md)), then
copy the netlist from the run and run `test.py` against it. The Makefile takes the cell models
from `$PDK_ROOT/sky130A`, so `PDK_ROOT` must be the directory that holds `sky130A`; under ciel
that is `~/.ciel/ciel/sky130/versions/HASH`, not `~/.ciel` itself.

```sh
cp runs/exp_TAG/final/pnl/tt_um_tiny_breakout.pnl.v test/gate_level_netlist.v
export PDK_ROOT=$HOME/.ciel/ciel/sky130/versions/HASH
(cd test && PATH=$PWD/../.venv/bin:$PWD/../.tools/env/bin:$PATH make -B GATES=yes)
```

## Waveforms

`test.py` writes `test/tb.fst`. View it from `test/` (where `tb.gtkw` is) with
`gtkwave tb.fst tb.gtkw` (pins only) or `surfer tb.fst`.
