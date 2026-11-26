# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Runs the whole capture in LibreLane's container and checks that every proof passes.

Selected with --slow. Takes about 40 seconds. Set CAPTURE_GATE to run a command before
each container run (see capture.py).
"""

import json
from pathlib import Path

import pytest

import capture


@pytest.mark.slow
def test_capture_passes_every_proof(request, tmp_path):
    run = Path(request.config.getoption("--capture-run"))
    if not (run / "06-yosys-synthesis").is_dir():
        pytest.skip(f"no synthesis step in {run}")
    assert capture.main([str(run), str(tmp_path)]) == 0
    for kind in ("plain", "dumps"):
        m = json.loads((tmp_path / kind / "manifest.json").read_text())
        failed = [p["name"] for p in m["proofs"] if not p["passed"]]
        assert m["passed"] and not failed, f"{kind}: {failed}"
    plain = json.loads((tmp_path / "plain" / "manifest.json").read_text())
    assert len(plain["proofs"]) == 5
    dumps = json.loads((tmp_path / "dumps" / "manifest.json").read_text())
    assert len(dumps["proofs"]) == 6
    # The checks run again on the same outputs and still pass.
    assert capture.main([str(run), str(tmp_path), "--prove-only"]) == 0
