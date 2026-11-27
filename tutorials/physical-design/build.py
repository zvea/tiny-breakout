#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Builds the physical design tutorial: page.html with the data inlined (gzipped, base64), as
../physical-design.html, and the same without the document skeleton for a preview host that
adds its own, as build/physical-design-preview.html at the top of the repo.

The data is data.json (from extract.py) if it is here; otherwise the data already inlined in
../physical-design.html is kept, so changes to the page need neither the run nor extract.py.

The glossary's terms come from the shared glossary, ../glossary/glossary.json. The page's
GLOSSARY names each term it uses by id, with the page's own fields; the build adds the term's
header, pattern and definition. It refuses a term that is not in the glossary or not reviewed.

Usage: build.py
"""
import base64
import gzip
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(HERE, "..", "physical-design.html")
GLOSSARY = os.path.join(HERE, "..", "glossary", "glossary.json")

# the page's GLOSSARY: one entry per line, { id: "...", <the page's own fields> }
BLOCK = re.compile(r"^  var GLOSSARY = \[\n(.*?)\];$", re.S | re.M)
USE = re.compile(r'    \{ id: "([^"]+)"(?:, (.*))? \}')
# the fields the build writes from glossary.json, which the page must not give itself
SHARED = ("id", "k", "rx", "def", "grid", "after")


class GlossaryError(Exception):
    pass


def load_glossary(path):
    """The shared glossary's entries, by id."""
    entries = json.load(open(path, encoding="utf-8"))
    by_id = {}
    for e in entries:
        missing = [f for f in ("id", "head", "match", "def", "reviewed", "sources") if f not in e]
        if missing:
            raise GlossaryError(f"glossary entry {e.get('id', e)!r} has no {', '.join(missing)}")
        if e["id"] in by_id:
            raise GlossaryError(f"glossary id {e['id']!r} is used twice")
        by_id[e["id"]] = e
    return by_id


def js_string(s):
    # JSON strings are JavaScript strings; "</" is escaped so no text can end the script
    return json.dumps(s, ensure_ascii=False).replace("</", "<\\/")


def js_regex(match, eid):
    source, flags = match["source"], match["flags"]
    if not source or re.search("[\n\r\u2028\u2029]", source) or re.search(r"(?<!\\)(\\\\)*/", source):
        raise GlossaryError(f"glossary entry {eid!r} has a pattern that cannot be written as a JavaScript literal: {match}")
    # the page adds g itself when it searches, and y would anchor every search
    if not re.fullmatch(r"[imsuv]*", flags) or len(set(flags)) != len(flags) or {"u", "v"} <= set(flags):
        raise GlossaryError(f"glossary entry {eid!r} has pattern flags {flags!r}; only i, m, s and one of u or v, each once, can be used")
    return f"/{source}/{flags}"


def glossary_block(page, glossary):
    """The page with each entry of its GLOSSARY filled in from the shared glossary (by id)."""
    blocks = BLOCK.findall(page)
    if len(blocks) != 1:
        raise GlossaryError(f"expected one GLOSSARY block in page.html, found {len(blocks)}")
    lines, seen = [], set()
    for line in blocks[0].rstrip("\n").split(",\n"):
        m = USE.fullmatch(line)
        if not m:
            raise GlossaryError(f"page.html: a GLOSSARY entry is not one line of the form {{ id: \"...\", ... }}: {line.strip()}")
        eid, own = m[1], m[2]
        if eid in seen:
            raise GlossaryError(f"page.html uses glossary id {eid!r} twice")
        seen.add(eid)
        e = glossary.get(eid)
        if e is None:
            raise GlossaryError(f"page.html uses glossary id {eid!r}, which is not in glossary.json")
        if e["reviewed"] is not True:
            raise GlossaryError(f"page.html uses glossary id {eid!r}, which is not reviewed (reviewed: false in glossary.json)")
        fields = [f"id: {js_string(eid)}", f"k: {js_string(e['head'])}", f"rx: {js_regex(e['match'], eid)}"]
        if own:
            clash = sorted(set(re.findall(r"(?:^|, )([A-Za-z_$][\w$]*): ", own)) & set(SHARED))
            if clash:
                raise GlossaryError(f"page.html gives glossary id {eid!r} its own {', '.join(clash)}, which come from glossary.json")
            fields.append(own)
        fields.append(f"def: {js_string(e['def'])}")
        if "grid" in e:
            fields.append("grid: " + json.dumps(e["grid"], ensure_ascii=False).replace("</", "<\\/"))
        if "after" in e:
            fields.append(f"after: {js_string(e['after'])}")
        lines.append("    { " + ", ".join(fields) + " }")
    block = "  var GLOSSARY = [\n" + ",\n".join(lines) + "];"
    return BLOCK.sub(lambda _: block, page)


def main():
    root = subprocess.check_output(["git", "-C", HERE, "rev-parse", "--show-toplevel"], text=True).strip()
    page = open(os.path.join(HERE, "page.html"), encoding="utf-8").read()
    assert page.count('"/*DATA*/"') == 1
    try:
        page = glossary_block(page, load_glossary(GLOSSARY))
    except GlossaryError as e:
        sys.exit(f"build.py: {e}")
    if os.path.exists(os.path.join(HERE, "data.json")):
        data = open(os.path.join(HERE, "data.json"), "rb").read()
        blob = base64.b64encode(gzip.compress(data, 9, mtime=0)).decode()
        source = f"data.json, {len(data):,} bytes"
    else:
        blob = re.search(r'var DATA_GZ = "([A-Za-z0-9+/=]+)";', open(PAGE, encoding="utf-8").read())[1]
        source = "the data already in physical-design.html"
    full = page.replace('"/*DATA*/"', '"' + blob + '"')
    open(PAGE, "w", encoding="utf-8").write(full)

    head = re.search(r"<head>(.*?)</head>", full, re.S)[1]
    head = re.sub(r'<meta charset="utf-8">\s*|<meta name="viewport"[^>]*>\s*', "", head)
    body = re.search(r"<body>(.*?)</body>", full, re.S)[1]
    os.makedirs(os.path.join(root, "build"), exist_ok=True)
    open(os.path.join(root, "build", "physical-design-preview.html"), "w", encoding="utf-8").write(head.strip() + "\n" + body.strip() + "\n")
    print(f"physical-design.html {len(full):,} bytes, from {source}")


if __name__ == "__main__":
    main()
