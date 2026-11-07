# Tools

Scripts for measuring and checking the design. They find the repo from their own location,
use the project's `.venv` (for LibreLane and yowasp-yosys), and keep their working files in
`build/` (git-ignored) and `runs/`.

| Script | What it does | Time |
|---|---|---|
| `flow.sh place TAG [SRC_DIR]` | Tiny Tapeout flow up to global placement: TT's utilisation figure | ~4 min |
| `flow.sh harden TAG [SRC_DIR]` | The whole flow: also DRC, LVS, antenna, timing and the GDS | ~15 min |
| `flow_avg.sh NAME [SRC_DIR]` | `flow.sh place` for 3 register orderings, and their mean | ~12 min |
| `local_area.sh [REV]` | Local synthesis area of the working tree vs a git revision (5 orderings each) | ~1 min |
| `equiv.sh [REV]` | Formal equivalence of the working tree vs a git revision, for refactors | ~1 min |

Notes:

- **Which number counts:** `flow.sh place` gives TT's utilisation. `local_area.sh` is quick but
  only a guide: its differences have been off from the flow's by up to 2x.
- **Noise:** synthesis results shift with the order of register declarations alone (about a
  point of utilisation, or 50-100 µm² locally), so compare means over orderings.
- **Routability:** the only real test is `flow.sh harden` (0 DRC, LVS and antenna errors).
- **Setup:** the flow needs `src/user_config.json` (`./tt/tt_tool.py --create-user-config`)
  and Docker. The local scripts need the sky130 PDK, found via `$PDK_ROOT` or ciel's default
  `~/.ciel`.
- **Experiments:** `EXTRA_CFG='{"KEY": value}'` overrides flow settings for one run, and
  `GOLD_RENAMES='rename old new;'` lets `equiv.sh` pair up renamed registers.
