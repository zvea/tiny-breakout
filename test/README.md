# Tests

Three layers, from module to whole game:

| Tests | What they check | Command | Time |
|---|---|---|---|
| [unit/](unit) | Each module on its own, through its ports (cocotb) | `pytest test/unit` | ~70 s (Verilator), ~5.5 min (`SIM=icarus`) |
| [test.py](test.py) | The whole chip through its pins, on the RTL or the gate-level netlist (cocotb, Icarus) | `make -B` in `test/` | ~1.5 min |
| [system/](system) | 12 gameplay scenarios, judged only from the decoded video output | `pytest test/system -n auto` | ~13 min in parallel, ~40 min one after another |

CI ([.github/workflows/test.yaml](../.github/workflows/test.yaml)) lints the design with
Verilator 5 and runs `test.py` and the unit tests on Icarus, both from Ubuntu 24.04's packages
(Icarus 12, where the local setup below has 13.0). Tiny Tapeout's GDS workflow also runs
`test.py` on the gate-level netlist. The
system scenarios run only locally, because they need Verilator 4.x.

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
when the simulator isn't on `PATH`; the system tests and the player always use `.tools/v4`; the
full-chip `make` needs `PATH` set, as shown below. conda-forge's Verilator builds with conda's
own C++ compiler, so it is listed too.

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
SIM=icarus .venv/bin/pytest test/unit      # Icarus, as in CI (which has version 12)
.venv/bin/pytest test/system -n auto       # needs .tools/v4; one worker per scenario
.venv/bin/pytest test/system               # one after another
.venv/bin/pytest test/system -k launch     # one scenario
(cd test && PATH=$PWD/../.venv/bin:$PWD/../.tools/env/bin:$PATH make -B)   # full chip
```

`test.py`'s Makefile lists the sources in `PROJECT_SOURCES`, read from
[info.yaml](../info.yaml). The pytest suites build their own sources.

### Gate-level simulation

Harden the design (`tools/flow.sh harden TAG`, see [tools/README.md](../tools/README.md)), then
copy the netlist from the run and run `test.py` against it:

```sh
cp runs/exp_TAG/final/pnl/tt_um_tiny_breakout.pnl.v test/gate_level_netlist.v
(cd test && make -B GATES=yes)
```

## Waveforms

`test.py` writes `test/tb.fst`. View it with `gtkwave tb.fst tb.gtkw` (pins only) or
`surfer tb.fst`.
