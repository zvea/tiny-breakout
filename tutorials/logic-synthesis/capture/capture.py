#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Re-runs a run's Yosys synthesis step in LibreLane's container, twice, and checks both
reruns against the run.

Usage: capture.py [--gate COMMAND] [--prove-only] RUN_DIR OUT_DIR

- OUT_DIR/plain: the step as the run ran it, keeping ABC's temporary files.
- OUT_DIR/dumps: the same, with the design written after every command of the script: as
  JSON, or as RTLIL while the design has processes.

Each writes a manifest.json with its inputs, commands and check results. Exits 0 if every
check passes, 1 if one fails. --prove-only runs the checks again on existing captures.

The gate command, from --gate or the CAPTURE_GATE environment variable, runs before each
container run, for example to wait for free memory. Without one, containers start at once.
"""

import argparse
import filecmp
import hashlib
import io
import json
import os
import re
import shlex
import shutil
import subprocess
import sys
import tarfile
import time
from pathlib import Path

import logs
import proofs

HERE = Path(__file__).resolve().parent
IMAGE = ("ghcr.io/librelane/librelane"
         "@sha256:f91b21d75f79871f9ccf37451020b5d2f7b3236881a997ff709c561e8280a30f")
RTL_COMMIT = "8e82a8f"
# The run's version of this file differs from the commit's in comments only. Its line numbers
# are the ones in the run's JSON netlist.
RTL_REPLACEMENT = "tutorials/physical-design/provenance/brick_wall.sv"


def parse_commands(text):
    """The script and its arguments from a synthesis step's COMMANDS file.

    The file must hold one command: yosys -y SCRIPT -- ARGUMENTS.
    """
    lines = [line for line in text.splitlines() if line.strip()]
    if len(lines) != 1:
        raise ValueError(f"expected one command, found {len(lines)}")
    words = shlex.split(lines[0])
    if words[:2] != ["yosys", "-y"] or len(words) < 4 or words[3] != "--":
        raise ValueError(f"not a 'yosys -y SCRIPT -- ...' command: {lines[0]}")
    return words[2], words[4:]


def docker_argv(image, user, workdir, mounts, env, command):
    """A docker run command line, with the container's memory capped at 2 GB."""
    argv = ["docker", "run", "--rm", "--memory=2g", "--user", user]
    for host, container, mode in mounts:
        argv += ["-v", f"{host}:{container}:{mode}"]
    for key, value in env.items():
        argv += ["-e", f"{key}={value}"]
    return argv + ["-w", workdir, image, *command]


def mounts(run, step, out, rtl, design_dir, pdk_root, hook_dir):
    """The container's mounts for one capture.

    The capture's step folder is mounted where the run's step folder was, so every path the
    step uses is the run's own. The rebuilt sources go where the run read them from.
    """
    return [
        (run, run, "ro"),
        (f"{out}/step", f"{run}/{step}", "rw"),
        (rtl, design_dir, "ro"),
        (pdk_root, pdk_root, "ro"),
        (hook_dir, hook_dir, "ro"),
        (out, out, "rw"),
        # ABC's own temporary folder goes under /tmp; this keeps it
        (f"{out}/tmp", "/tmp", "rw"),
    ]


def abc_call_dirs(log_text, dirs):
    """Which kept ABC folder belongs to which ABC call (by top-level header number).

    The log names a call's folder when the call shows it. At most one call may leave its
    folder unnamed; it gets the one folder left.
    """
    calls = [n for n, title in logs.find_headers(log_text)
             if title.startswith("Executing ABC pass")]
    if len(calls) != len(dirs):
        raise ValueError(f"{len(calls)} ABC calls, {len(dirs)} kept folders")
    found = {}
    for n in calls:
        named = [d for d in dirs if re.search(rf"^{n}\.1\. .*`{re.escape(d)}/", log_text, re.M)]
        if named:
            found[n] = named[0]
    left = [d for d in dirs if d not in found.values()]
    unnamed = [n for n in calls if n not in found]
    if len(unnamed) > 1:
        raise ValueError(f"ABC calls {unnamed} do not name their folders")
    if unnamed:
        found[unnamed[0]] = left[0]
    return dict(sorted(found.items()))


# Files LibreLane writes around the step, which the step's command does not write.
LIBRELANE_FILES = {"COMMANDS", "runtime.txt", "state_in.json", "state_out.json",
                   "yosys-synthesis.log", "yosys-synthesis.process_stats.json"}
# The step's inputs, which the capture copies in.
STEP_INPUTS = {"config.json", "extra.json"}


def other_outputs(run_files, capture_files, top):
    """The step outputs to compare, besides the netlists and the log.

    Takes the files in the run's and the capture's step folders, as relative paths. Returns
    (files in both, files only the run has, files only the capture has), each sorted.
    """
    skip = STEP_INPUTS | {f"{top}.nl.v", f"{top}.nl.v.json"}
    run = set(run_files) - LIBRELANE_FILES - skip
    cap = set(capture_files) - skip
    return sorted(run & cap), sorted(run - cap), sorted(cap - run)


def gate_command(option, environ):
    """The gate command as a word list: from the option, else CAPTURE_GATE, else None."""
    text = option or environ.get("CAPTURE_GATE")
    return shlex.split(text) if text else None


def place_dumps(raw, after, kept):
    """Links each kept dump as after/NNN.json (or .il), for the header number NNN.

    Leaves every dump in raw. Links already there are kept. Raises ValueError if another
    file is in the way. Returns {header number: path}.
    """
    after.mkdir(exist_ok=True)
    paths = {}
    for n, name in kept:
        path = after / f"{n:03d}{Path(name).suffix}"
        if path.exists():
            if not path.samefile(raw / name):
                raise ValueError(f"{path.name} is not a link to raw/{name}")
        else:
            os.link(raw / name, path)
        paths[n] = path
    return paths


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def hashes(root, paths):
    """{path relative to root: sha256} for the given files."""
    return {str(Path(p).relative_to(root)): sha256(p) for p in sorted(paths)}


def build_rtl(repo, dest):
    """Writes the commit's src/ to dest/src, with the run's version of one file put back."""
    tar = subprocess.run(["git", "-C", repo, "archive", RTL_COMMIT, "src"],
                         check=True, capture_output=True).stdout
    with tarfile.open(fileobj=io.BytesIO(tar)) as t:
        t.extractall(dest, filter="data")
    replacement = Path(repo) / RTL_REPLACEMENT
    shutil.copyfile(replacement, dest / "src" / replacement.name)
    return dest / "src"


def run_container(argv, log_path, gate):
    """Runs the gate command if there is one, then one container, with its output in log_path."""
    if gate:
        subprocess.run(gate, check=True)
    start = time.monotonic()
    with open(log_path, "wb") as log:
        code = subprocess.run(argv, stdout=log, stderr=subprocess.STDOUT).returncode
    return code, round(time.monotonic() - start, 1)


def inspect_image():
    """The image's id and tags, from the local image store."""
    info = json.loads(subprocess.run(["docker", "image", "inspect", IMAGE], check=True,
                                     capture_output=True, text=True).stdout)[0]
    return {"reference": IMAGE, "id": info["Id"], "tags": info["RepoTags"]}


def yosys_version(log_text):
    """The version line Yosys printed at the top of its log."""
    return next(line.strip() for line in log_text.splitlines() if line.startswith(" Yosys "))


class Capture:
    """One rerun of the step: its folders, inputs and container command."""

    def __init__(self, kind, run, step, out, rtl, user):
        self.kind, self.run, self.step = kind, Path(run), step
        self.dir = Path(out) / kind
        self.run_step = self.run / step
        self.config = json.loads((self.run_step / "config.json").read_text())
        self.extra = json.loads((self.run_step / "extra.json").read_text())
        self.script, self.args = parse_commands((self.run_step / "COMMANDS").read_text())
        self.top = self.config["DESIGN_NAME"]
        self.log = self.dir / "yosys-synthesis.log"
        self.dump_dir = self.dir / "dumps" if kind == "dumps" else None
        env = {"HOME": "/tmp", "CAPTURE_LIBRELANE_SCRIPT": self.script}
        if self.dump_dir:
            env["CAPTURE_DUMP_DIR"] = str(self.dump_dir / "raw")
        self.argv = docker_argv(
            IMAGE, user, str(self.dir / "abc"),
            mounts(str(self.run), step, str(self.dir), str(rtl), self.config["DESIGN_DIR"],
                   self.config["PDK_ROOT"], str(HERE)),
            env, ["yosys", "-y", str(HERE / "yosys_hook.py"), "--", *self.args])

    def prepare(self):
        """Makes the folders and copies in the step's inputs, which sit in its folder."""
        for sub in ["step", "abc", "tmp"] + (["dumps/raw"] if self.dump_dir else []):
            (self.dir / sub).mkdir(parents=True)
        for name in ["config.json", "extra.json"]:
            shutil.copyfile(self.run_step / name, self.dir / "step" / name)

    def netlist(self, suffix=""):
        return self.dir / "step" / f"{self.top}.nl.v{suffix}"


def prove_plain(c):
    """Checks a plain capture against the run."""
    results = [
        proofs.identical("nl.v identical to the run's", c.netlist(),
                         c.run_step / c.netlist().name),
        proofs.identical("nl.v.json identical to the run's", c.netlist(".json"),
                         c.run_step / c.netlist(".json").name),
        proofs.logs_equal("log equal to the run's", c.run_step / "yosys-synthesis.log", c.log),
    ]
    # The step's other outputs: the ABC script, the SDC for ABC, and the reports.
    step = c.dir / "step"
    both, missing, extra = other_outputs(_files(c.run_step), _files(step), c.top)
    differ = [f for f in both if not filecmp.cmp(step / f, c.run_step / f, shallow=False)]
    problems = ([f"differ: {differ}"] if differ else []) + (
        [f"only in the run: {missing}"] if missing else []) + (
        [f"only in the capture: {extra}"] if extra else [])
    results.append({"name": "other step outputs identical to the run's", "passed": not problems,
                    "detail": "; ".join(problems) if problems else
                    f"{len(both)} files byte-identical: {', '.join(both)}"})
    kept = abc_kept(c)
    missing = [f"{n}/{f}" for n, d in kept.items() for f in ("input.blif", "abc.script",
                                                             "output.blif")
               if not (c.dir / "abc" / d / f).is_file()]
    results.append({"name": "ABC's temporary files kept", "passed": not missing,
                    "detail": f"missing: {missing}" if missing else
                    "; ".join(f"call {n}: abc/{d}" for n, d in kept.items())})
    return results


def _files(folder):
    """The files under folder, as sorted relative paths."""
    return sorted(str(p.relative_to(folder)) for p in folder.rglob("*") if p.is_file())


def abc_kept(c):
    dirs = sorted(p.name for p in (c.dir / "abc").iterdir() if p.name.startswith("_tmp_yosys-abc-"))
    return abc_call_dirs(c.log.read_text(encoding="utf-8"), dirs)


def prove_dumps(c, plain):
    """Checks a dump capture against the plain one, and its dumps against the log.

    Every dump stays in dumps/raw. The one after each numbered command is linked as
    dumps/after/NNN.json (or NNN.il).
    """
    results = [
        proofs.identical("nl.v identical to the plain capture's", c.netlist(), plain.netlist()),
        proofs.identical("nl.v.json identical to the plain capture's", c.netlist(".json"),
                         plain.netlist(".json")),
        proofs.logs_equal("log equal to the plain capture's, without the dump markers",
                          plain.log, c.log, strip_dumps_from_b=True),
    ]
    text = c.log.read_text(encoding="utf-8")
    raw = c.dump_dir / "raw"
    records = [json.loads(line) for line in (raw / "commands.jsonl").read_text().splitlines()]
    a = proofs.assign_dumps(logs.events(text), records)
    problems = list(a.problems)
    for name, previous in a.unchanged:
        if previous is None or not proofs.identical("", raw / name, raw / previous)["passed"]:
            problems.append(f"dump {name} (a command without a header) differs from {previous}")
    plain_numbers = [n for n, _ in logs.top_level_headers(plain.log.read_text(encoding="utf-8"))]
    covered = sorted([n for n, _ in a.kept] + a.script_headers + [n for n, _ in a.inner_headers])
    if covered != plain_numbers:
        problems.append("the dumps' headers are not the plain log's headers 1 to "
                        f"{len(plain_numbers)}")
    commands = sum("command" in r for r in records)
    unchanged = [next(r["command"][0] for r in records if r.get("dump") == name)
                 for name, _ in a.unchanged]
    results.append({
        "name": "one dump per numbered command, in order", "passed": not problems,
        "detail": "; ".join(problems) if problems else
        (f"{len(plain_numbers)} numbered headers; {commands} commands; {len(a.kept)} dumps "
         f"kept, one per command with a header; {len(a.unchanged)} commands without a header "
         f"left the design unchanged ({', '.join(unchanged)}); headers printed by the script "
         f"between commands: {a.script_headers}; printed inside another command: "
         + ", ".join(f"{h} (in {o})" for h, o in a.inner_headers))})
    if problems:
        return results
    kept = place_dumps(raw, c.dump_dir / "after", a.kept)
    results.append(proofs.statistics_agree(plain.log.read_text(encoding="utf-8"), kept, c.top))
    last = max(kept)
    results.append(proofs.json_equal(f"last dump ({last}) equal to nl.v.json", kept[last],
                                    c.netlist(".json")))
    return results


def manifest(c, rtl, repo, image, code, seconds, results):
    run_inputs = [c.run_step / n for n in ("COMMANDS", "config.json", "extra.json")]
    libs = c.extra["libs_synth"] + c.extra["blackbox_models"]
    outputs = [p for p in sorted(c.dir.rglob("*")) if p.is_file() and p.name != "manifest.json"]
    return {
        "capture": c.kind,
        "inputs": {
            "run_step": str(c.run_step),
            "run_files": {str(p): sha256(p) for p in run_inputs},
            "rtl": {
                "made_from": f"git archive {RTL_COMMIT} src, with src/brick_wall.sv replaced "
                             f"by {RTL_REPLACEMENT}",
                "commit": subprocess.run(["git", "-C", repo, "rev-parse", RTL_COMMIT],
                                         check=True, capture_output=True,
                                         text=True).stdout.strip(),
                "mounted_at": c.config["DESIGN_DIR"],
                "sha256": hashes(rtl, [p for p in rtl.iterdir() if p.is_file()]),
            },
            "liberty": {lib: sha256(lib) for lib in libs},
            "image": image,
            "yosys_version": yosys_version(c.log.read_text(encoding="utf-8")),
            "librelane_script": c.script,
            "capture_code": hashes(HERE, [HERE / "yosys_hook.py", HERE / "capture.py",
                                          HERE / "logs.py", HERE / "proofs.py",
                                          HERE / "dumps.py"]),
        },
        "commands": [c.argv],
        "exit_code": code,
        "seconds": seconds,
        "outputs": hashes(c.dir, outputs),
        "proofs": results,
        "passed": all(r["passed"] for r in results),
    }


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    parser.add_argument("run", help="the run's folder, such as runs/exp_rowtail")
    parser.add_argument("out", help="the folder to write the captures to")
    parser.add_argument("--gate", help="a command to run before each container run "
                        "(default: $CAPTURE_GATE; none if unset)")
    parser.add_argument("--prove-only", action="store_true",
                        help="run the checks again on the captures already in OUT_DIR")
    args = parser.parse_args(argv)
    run, out = Path(args.run).resolve(), Path(args.out).resolve()
    step = next(p.name for p in sorted(run.iterdir()) if p.name.endswith("-yosys-synthesis"))
    repo = subprocess.run(["git", "-C", HERE, "rev-parse", "--show-toplevel"], check=True,
                          capture_output=True, text=True).stdout.strip()
    user = f"{os.getuid()}:{os.getgid()}"
    gate = gate_command(args.gate, os.environ)
    if args.prove_only:
        rtl = out / "rtl" / "src"
    else:
        for kind in ("rtl", "plain", "dumps"):
            if (out / kind).exists():
                sys.exit(f"{out / kind} exists; remove it first")
        out.mkdir(parents=True, exist_ok=True)
        rtl = build_rtl(repo, out / "rtl")
    plain = Capture("plain", run, step, out, rtl, user)
    image = inspect_image()
    dumps = Capture("dumps", run, step, out, rtl, user)
    passed = True
    for c in (plain, dumps):
        if args.prove_only:
            old = json.loads((c.dir / "manifest.json").read_text())
            code, seconds = old["exit_code"], old["seconds"]
        else:
            c.prepare()
            print(f"{c.kind}: running the step", flush=True)
            code, seconds = run_container(c.argv, c.log, gate)
        if code != 0:
            results = [{"name": "container run", "passed": False,
                        "detail": f"exit code {code}; see {c.log}"}]
        elif c is plain:
            results = proofs.guarded(prove_plain, c)
        else:
            results = proofs.guarded(prove_dumps, c, plain)
        m = manifest(c, rtl, repo, image, code, seconds, results)
        (c.dir / "manifest.json").write_text(json.dumps(m, indent=1) + "\n")
        print(f"{c.kind}:")
        for r in results:
            print(f"  {'pass' if r['passed'] else 'FAIL'}: {r['name']}: "
                  + r["detail"].split("\n")[0])
        passed = passed and m["passed"]
        if not passed:
            break
    return 0 if passed else 1


if __name__ == "__main__":
    sys.exit(main())
