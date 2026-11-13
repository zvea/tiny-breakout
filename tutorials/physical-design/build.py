#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Builds the physical design tutorial: page.html with the data inlined (gzipped, base64), as
../physical-design.html, and the same without the document skeleton for a preview host that
adds its own, as build/physical-design-preview.html at the top of the repo.

The data is data.json (from extract.py) if it is here; otherwise the data already inlined in
../physical-design.html is kept, so changes to the page need neither the run nor extract.py.

Usage: build.py
"""
import base64
import gzip
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
PAGE = os.path.join(HERE, "..", "physical-design.html")
ROOT = subprocess.check_output(["git", "-C", HERE, "rev-parse", "--show-toplevel"], text=True).strip()

page = open(os.path.join(HERE, "page.html")).read()
assert page.count('"/*DATA*/"') == 1
if os.path.exists(os.path.join(HERE, "data.json")):
    data = open(os.path.join(HERE, "data.json"), "rb").read()
    blob = base64.b64encode(gzip.compress(data, 9, mtime=0)).decode()
    source = f"data.json, {len(data):,} bytes"
else:
    blob = re.search(r'var DATA_GZ = "([A-Za-z0-9+/=]+)";', open(PAGE).read())[1]
    source = "the data already in physical-design.html"
full = page.replace('"/*DATA*/"', '"' + blob + '"')
open(PAGE, "w").write(full)

head = re.search(r"<head>(.*?)</head>", full, re.S)[1]
head = re.sub(r'<meta charset="utf-8">\s*|<meta name="viewport"[^>]*>\s*', "", head)
body = re.search(r"<body>(.*?)</body>", full, re.S)[1]
os.makedirs(os.path.join(ROOT, "build"), exist_ok=True)
open(os.path.join(ROOT, "build", "physical-design-preview.html"), "w").write(head.strip() + "\n" + body.strip() + "\n")
print(f"physical-design.html {len(full):,} bytes, from {source}")
