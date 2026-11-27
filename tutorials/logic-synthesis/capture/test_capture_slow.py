# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Runs the whole capture in LibreLane's container and checks that every proof passes, and
that --rtlil leaves every JSON dump and record unchanged.

Selected with --slow. Takes about 40 seconds for the first test and two minutes for the
second. Set CAPTURE_GATE to run a command before each container run (see capture.py).
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


@pytest.mark.slow
def test_rtlil_dumps_leave_every_json_dump_and_record_unchanged(request, tmp_path):
    # Also checks, on a real Yosys log, the shape of the RTLIL lines strip_dumps takes out.
    run = Path(request.config.getoption("--capture-run"))
    if not (run / "06-yosys-synthesis").is_dir():
        pytest.skip(f"no synthesis step in {run}")
    default, rtlil = tmp_path / "default", tmp_path / "rtlil"
    assert capture.main([str(run), str(default)]) == 0
    assert capture.main([str(run), str(rtlil), "--rtlil"]) == 0
    assert capture.main([str(run), str(rtlil), "--prove-only"]) == 0
    a, b = default / "dumps" / "dumps" / "raw", rtlil / "dumps" / "dumps" / "raw"
    jsons = sorted(p.name for p in a.glob("*.json"))
    assert jsons and jsons == sorted(p.name for p in b.glob("*.json"))
    for name in jsons:
        assert (a / name).read_bytes() == (b / name).read_bytes(), name
    records_a = [json.loads(line) for line in (a / "commands.jsonl").read_text().splitlines()]
    records_b = [json.loads(line) for line in (b / "commands.jsonl").read_text().splitlines()]
    assert sum("also" in r for r in records_b) == len(jsons)
    assert records_a == [{k: v for k, v in r.items() if k != "also"} for r in records_b]
    assert sorted(p.name for p in b.glob("*.il")) == sorted(
        Path(r["dump"]).stem + ".il" for r in records_b if "dump" in r)
