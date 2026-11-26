# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Tests for the pure parts of capture.py. The container runs are in test_capture_slow.py."""

import pytest

import capture

COMMANDS = ("yosys -y /nix/store/x/pyosys/synthesize.py -- --config-in /r/06-s/config.json "
            "--extra-in /r/06-s/extra.json --output /r/06-s/top.nl.v\n")


def test_parse_commands():
    script, args = capture.parse_commands(COMMANDS)
    assert script == "/nix/store/x/pyosys/synthesize.py"
    assert args == ["--config-in", "/r/06-s/config.json", "--extra-in", "/r/06-s/extra.json",
                    "--output", "/r/06-s/top.nl.v"]


@pytest.mark.parametrize("text", [
    "openroad -exit x.tcl\n",
    "yosys -y a.py\n",
    COMMANDS + COMMANDS,
])
def test_parse_commands_refuses_other_shapes(text):
    with pytest.raises(ValueError):
        capture.parse_commands(text)


def test_docker_argv():
    argv = capture.docker_argv(
        image="img@sha256:ab", user="1000:1000", workdir="/w",
        mounts=[("/host/a", "/c/a", "ro"), ("/host/b", "/c/b", "rw")],
        env={"HOME": "/tmp", "X": "1"}, command=["yosys", "-V"])
    assert argv == [
        "docker", "run", "--rm", "--memory=2g", "--user", "1000:1000",
        "-v", "/host/a:/c/a:ro", "-v", "/host/b:/c/b:rw",
        "-e", "HOME=/tmp", "-e", "X=1", "-w", "/w", "img@sha256:ab", "yosys", "-V"]


def test_mounts_put_the_capture_where_the_run_step_was():
    m = capture.mounts(run="/runs/r", step="06-s", out="/out/plain", rtl="/out/rtl/src",
                       design_dir="/proj/.src", pdk_root="/pdk/v1", hook_dir="/code/capture")
    assert m == [
        ("/runs/r", "/runs/r", "ro"),
        ("/out/plain/step", "/runs/r/06-s", "rw"),
        ("/out/rtl/src", "/proj/.src", "ro"),
        ("/pdk/v1", "/pdk/v1", "ro"),
        ("/code/capture", "/code/capture", "ro"),
        ("/out/plain", "/out/plain", "rw"),
        ("/out/plain/tmp", "/tmp", "rw"),
    ]


LOG = """\

134. Executing ABC pass (technology mapping using ABC).

134.1. Extracting gate netlist of module `\\top' to `<abc-temp-dir>/input.blif'..

148. Executing ABC pass (technology mapping using ABC).

148.1. Extracting gate netlist of module `\\top' to `_tmp_yosys-abc-Rt5Uv6/input.blif'..
"""


def test_abc_call_dirs_names_the_shown_one_and_the_other_by_elimination():
    dirs = ["_tmp_yosys-abc-Mn2Op3", "_tmp_yosys-abc-Rt5Uv6"]
    assert capture.abc_call_dirs(LOG, dirs) == {134: "_tmp_yosys-abc-Mn2Op3",
                                                148: "_tmp_yosys-abc-Rt5Uv6"}


def test_abc_call_dirs_needs_one_folder_per_call():
    with pytest.raises(ValueError, match="2 ABC calls, 1 kept folders"):
        capture.abc_call_dirs(LOG, ["_tmp_yosys-abc-Rt5Uv6"])


def test_yosys_version_from_the_log_banner():
    text = (" |  yosys -- Yosys Open SYnthesis Suite  |\n"
            " Yosys 1.23 (git sha1 0abc123, cc 4.5)\n\n1. Executing X pass.\n")
    assert capture.yosys_version(text) == "Yosys 1.23 (git sha1 0abc123, cc 4.5)"


def test_abc_call_dirs_with_two_unnamed_calls():
    log = LOG.replace("_tmp_yosys-abc-Rt5Uv6/", "<abc-temp-dir>/")
    with pytest.raises(ValueError, match=r"ABC calls \[134, 148\] do not name their folders"):
        capture.abc_call_dirs(log, ["_tmp_yosys-abc-Mn2Op3", "_tmp_yosys-abc-Rt5Uv6"])


RUN_STEP = ["AREA_1.abc", "COMMANDS", "config.json", "extra.json", "reports/stat.rpt",
            "runtime.txt", "state_in.json", "state_out.json", "synthesis.abc.sdc", "top.nl.v",
            "top.nl.v.json", "yosys-synthesis.log", "yosys-synthesis.process_stats.json"]
CAPTURE_STEP = ["AREA_1.abc", "config.json", "extra.json", "reports/stat.rpt",
                "synthesis.abc.sdc", "top.nl.v", "top.nl.v.json"]


def test_other_outputs_leave_out_librelane_files_inputs_and_netlists():
    assert capture.other_outputs(RUN_STEP, CAPTURE_STEP, "top") == (
        ["AREA_1.abc", "reports/stat.rpt", "synthesis.abc.sdc"], [], [])


def test_other_outputs_list_missing_and_extra_files():
    files = [f for f in CAPTURE_STEP if f != "reports/stat.rpt"] + ["reports/new.rpt"]
    assert capture.other_outputs(RUN_STEP, files, "top") == (
        ["AREA_1.abc", "synthesis.abc.sdc"], ["reports/stat.rpt"], ["reports/new.rpt"])


def test_gate_command_from_the_option_then_the_environment():
    assert capture.gate_command("wait.sh 1", {"CAPTURE_GATE": "other"}) == ["wait.sh", "1"]
    assert capture.gate_command(None, {"CAPTURE_GATE": "env X=2 wait.sh 1"}) == [
        "env", "X=2", "wait.sh", "1"]
    assert capture.gate_command(None, {}) is None


def test_place_dumps_links_each_kept_dump_and_can_run_again(tmp_path):
    raw = tmp_path / "raw"
    raw.mkdir()
    (raw / "0001.il").write_text("a")
    (raw / "0002.json").write_text("b")
    (raw / "0003.json").write_text("b")
    kept = [(14, "0001.il"), (16, "0003.json")]
    paths = capture.place_dumps(raw, tmp_path / "after", kept)
    assert paths == {14: tmp_path / "after" / "014.il", 16: tmp_path / "after" / "016.json"}
    assert (tmp_path / "after" / "016.json").samefile(raw / "0003.json")
    assert (raw / "0002.json").exists()  # dumps that are not kept stay in raw
    assert capture.place_dumps(raw, tmp_path / "after", kept) == paths


def test_place_dumps_refuses_a_different_file_in_the_way(tmp_path):
    raw = tmp_path / "raw"
    raw.mkdir()
    (raw / "0001.json").write_text("a")
    (tmp_path / "after").mkdir()
    (tmp_path / "after" / "014.json").write_text("a")
    with pytest.raises(ValueError, match="014.json is not a link to raw/0001.json"):
        capture.place_dumps(raw, tmp_path / "after", [(14, "0001.json")])
