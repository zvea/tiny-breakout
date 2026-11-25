"""Tests that the built page's Tiny Explorer link opens this run's GDS and project metadata.

The link pins the commit that added the files, as a page cannot name its own commit. These
tests catch a link left behind when the files change, for example after regenerating the
tutorial from a new run.

Run from the repo root: .venv/bin/pytest tutorials/physical-design
"""
import html
import re
import subprocess
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

import pytest

HERE = Path(__file__).resolve().parent
PAGE = HERE.parent / "physical-design.html"
VIEWER = "https://zvea.github.io/tiny_explorer/viewer.html"
RAW = re.compile(r"https://raw\.githubusercontent\.com/zvea/tiny-breakout/([0-9a-f]{40})/(.+)")
FILES = {"file": "tt_um_tiny_breakout.gds", "metadata": "tt_um_tiny_breakout.json"}


def git(*args):
    return subprocess.run(["git", "-C", str(HERE), *args], capture_output=True, text=True)


def link_params():
    """The query parameters of the page's one Tiny Explorer link."""
    links = re.findall(re.escape(VIEWER) + r'\?[^"\\\s<>]+', PAGE.read_text(encoding="utf-8"))
    assert len(links) == 1, f"expected one Tiny Explorer link, found {len(links)}"
    query = parse_qs(urlsplit(html.unescape(links[0])).query)
    assert all(len(v) == 1 for v in query.values()), f"a parameter given twice: {query}"
    return {k: v[0] for k, v in query.items()}


def test_the_link_names_the_pdk():
    assert link_params().get("pdk") == "sky130A"


@pytest.mark.parametrize("param", FILES)
def test_the_link_opens_the_committed_file_at_a_commit_in_this_history(param):
    url = link_params().get(param)
    assert url, f"no {param} parameter"
    m = RAW.fullmatch(url)
    assert m, f"{param} is not a commit-pinned raw URL of the repo: {url}"
    commit, path = m.groups()
    local = HERE / "provenance" / FILES[param]
    root = Path(git("rev-parse", "--show-toplevel").stdout.strip())
    assert path == local.relative_to(root).as_posix()
    assert git("merge-base", "--is-ancestor", commit, "HEAD").returncode == 0, \
        f"{commit} is not in this branch's history"
    pinned = git("rev-parse", f"{commit}:{path}").stdout.strip()
    assert pinned == git("hash-object", str(local)).stdout.strip(), \
        f"{path} differs from the copy at {commit[:7]}; point the link at the commit that changed it"


def test_both_files_come_from_the_same_commit():
    p = link_params()
    assert RAW.fullmatch(p["file"])[1] == RAW.fullmatch(p["metadata"])[1]
