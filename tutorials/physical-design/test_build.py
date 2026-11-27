"""Tests that the page's glossary comes from the shared glossary, and that the build refuses
terms it must not use.

Run from the repo root: .venv/bin/pytest tutorials/physical-design
"""
import copy
import json
from pathlib import Path

import pytest
from playwright.sync_api import sync_playwright

import build

HERE = Path(__file__).resolve().parent
PAGE = HERE.parent / "physical-design.html"
SOURCE = HERE / "page.html"

# the GLOSSARY array evaluated as the page's script would, with the names its entries refer to
# stubbed, and each entry's text fields returned as plain values
EVAL = """(text) => {
  var S = new Proxy({}, { get: function (t, p) { return String(p); } });
  function stackFigure() { return ""; }
  var G = eval("[" + text + "]");
  return G.map(function (g) {
    return { id: g.id, k: g.k, source: g.rx.source, flags: g.rx.flags, def: g.def,
             grid: g.grid === undefined ? null : g.grid, after: g.after === undefined ? null : g.after };
  });
}"""


def glossary_text(html):
    blocks = build.BLOCK.findall(html)
    assert len(blocks) == 1
    return blocks[0]


@pytest.fixture(scope="module")
def evaluate():
    with sync_playwright() as pw:
        browser = pw.chromium.launch()
        page = browser.new_page()
        yield lambda html: page.evaluate(EVAL, glossary_text(html))
        browser.close()


@pytest.fixture(scope="module")
def glossary():
    return build.load_glossary(build.GLOSSARY)


def used_ids():
    return build.USE.findall(glossary_text(SOURCE.read_text(encoding="utf-8")))


def test_the_built_page_has_each_term_it_uses_as_the_glossary_has_it(evaluate, glossary):
    built = evaluate(PAGE.read_text(encoding="utf-8"))
    assert [g["id"] for g in built] == [eid for eid, _ in used_ids()]
    for g in built:
        e = glossary[g["id"]]
        assert e["reviewed"] is True
        assert (g["k"], g["source"], g["flags"], g["def"]) == (e["head"], e["match"]["source"], e["match"]["flags"], e["def"]), g["id"]
        assert (g["grid"], g["after"]) == (e.get("grid"), e.get("after")), g["id"]


def test_the_built_page_is_up_to_date_with_the_glossary(glossary):
    built = glossary_text(PAGE.read_text(encoding="utf-8"))
    assert built == glossary_text(build.glossary_block(SOURCE.read_text(encoding="utf-8"), glossary))


def test_heads_with_a_qualifier_appear_as_written(evaluate, glossary):
    built = {g["id"]: g["k"] for g in evaluate(PAGE.read_text(encoding="utf-8"))}
    qualified = {eid: glossary[eid]["head"] for eid in built if "(" in glossary[eid]["head"]}
    assert {"cut-layout": "cut (layout)", "overflow-placement": "overflow (placement)"}.items() <= qualified.items()
    assert all(built[eid] == head for eid, head in qualified.items())


def test_a_term_that_is_not_reviewed_fails_the_build(glossary):
    changed = copy.deepcopy(glossary)
    changed["slew"]["reviewed"] = False
    with pytest.raises(build.GlossaryError, match=r"'slew'.*not reviewed"):
        build.glossary_block(SOURCE.read_text(encoding="utf-8"), changed)


def test_a_term_that_is_not_in_the_glossary_fails_the_build(glossary):
    changed = dict(glossary)
    del changed["slew"]
    with pytest.raises(build.GlossaryError, match=r"'slew'.*not in glossary.json"):
        build.glossary_block(SOURCE.read_text(encoding="utf-8"), changed)


def test_the_build_script_refuses_an_unreviewed_term(tmp_path, monkeypatch, glossary):
    entries = json.loads((HERE.parent / "glossary" / "glossary.json").read_text(encoding="utf-8"))
    next(e for e in entries if e["id"] == "slew")["reviewed"] = False
    path = tmp_path / "glossary.json"
    path.write_text(json.dumps(entries), encoding="utf-8")
    monkeypatch.setattr(build, "GLOSSARY", str(path))
    monkeypatch.setattr(build, "PAGE", str(tmp_path / "physical-design.html"))   # nothing is written over the real page
    with pytest.raises(SystemExit, match=r"'slew'.*not reviewed"):
        build.main()
    assert not (tmp_path / "physical-design.html").exists()


# ---- what the build refuses ----------------------------------------------------------------------

def write_glossary(tmp_path, entries):
    path = tmp_path / "glossary.json"
    path.write_text(json.dumps(entries, ensure_ascii=False), encoding="utf-8")
    return str(path)


def entry(**fields):
    e = {"id": "term", "head": "term", "match": {"source": r"\bterm\b", "flags": ""}, "def": "A term.", "reviewed": True, "sources": []}
    e.update(fields)
    return e


def test_a_glossary_entry_without_a_field_is_refused(tmp_path):
    e = entry()
    del e["def"]
    with pytest.raises(build.GlossaryError, match=r"'term' has no def"):
        build.load_glossary(write_glossary(tmp_path, [e]))


def test_a_glossary_id_used_twice_is_refused(tmp_path):
    with pytest.raises(build.GlossaryError, match=r"'term' is used twice"):
        build.load_glossary(write_glossary(tmp_path, [entry(), entry(head="other")]))


@pytest.mark.parametrize("flags", ["g", "y", "ig", "x", "ii", "uv"])
def test_a_pattern_with_flags_the_page_cannot_use_is_refused(flags):
    # the page adds g itself, y would anchor every search, and u and v cannot go together
    with pytest.raises(build.GlossaryError, match="flags"):
        build.js_regex({"source": r"\bterm\b", "flags": flags}, "term")


@pytest.mark.parametrize("flags", ["", "i", "imsu", "imsv"])
def test_a_pattern_with_flags_the_page_can_use_is_written(flags):
    assert build.js_regex({"source": r"\bterm\b", "flags": flags}, "term") == r"/\bterm\b/" + flags


@pytest.mark.parametrize("char", ["\n", "\r", " ", " "])
def test_a_pattern_with_a_line_break_is_refused(char):
    with pytest.raises(build.GlossaryError, match="JavaScript literal"):
        build.js_regex({"source": "a" + char + "b", "flags": ""}, "term")


@pytest.mark.parametrize("field", ["id", "k", "rx", "def", "grid", "after"])
def test_a_page_field_that_would_override_the_glossary_is_refused(field, glossary):
    page = SOURCE.read_text(encoding="utf-8").replace('{ id: "slew", ', '{ id: "slew", ' + field + ': "x", ', 1)
    with pytest.raises(build.GlossaryError, match=rf"'slew'.*\b{field}\b"):
        build.glossary_block(page, glossary)


def test_the_build_script_refuses_an_unknown_term_and_writes_nothing(tmp_path, monkeypatch):
    entries = json.loads((HERE.parent / "glossary" / "glossary.json").read_text(encoding="utf-8"))
    monkeypatch.setattr(build, "GLOSSARY", write_glossary(tmp_path, [e for e in entries if e["id"] != "slew"]))
    monkeypatch.setattr(build, "PAGE", str(tmp_path / "physical-design.html"))
    with pytest.raises(SystemExit, match=r"'slew'.*not in glossary.json"):
        build.main()
    assert not (tmp_path / "physical-design.html").exists()
