# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""Dumps a design's GDS for the physical design tutorial: each cell master's shapes as
rectangles, on the drawing layers that matter, and the top cell's instances of them. (The top
cell's own shapes, the routing and vias, come from the routed DEF instead: the same geometry,
far smaller.) Run with KLayout's Python (it is in LibreLane's container).

Usage: dump.py IN.gds OUT.json
"""
import json
import sys

import klayout.db as db

LAYERS = [  # (name, layer, datatype): sky130 drawing layers, from the bottom of the stack up
    ("nwell", 64, 20), ("diff", 65, 20), ("tap", 65, 44), ("psdm", 94, 20), ("nsdm", 93, 44),
    ("poly", 66, 20), ("licon", 66, 44), ("li1", 67, 20), ("mcon", 67, 44), ("met1", 68, 20),
    ("via", 68, 44), ("met2", 69, 20), ("via2", 69, 44), ("met3", 70, 20), ("via3", 70, 44),
    ("met4", 71, 20)]

ly = db.Layout()
ly.read(sys.argv[1])
top = ly.top_cell()
idx = {name: ly.find_layer(l, d) for name, l, d in LAYERS}


def rects(cell, li):
    """The cell's own shapes on a layer, merged and cut into rectangles."""
    if li is None:
        return []
    reg = db.Region(cell.shapes(li)).merged()
    out = []
    for p in reg.decompose_trapezoids_to_region(db.Polygon.TD_htrapezoids).each():
        b = p.bbox()
        if p.is_box() or p.num_points() == 4 and p.area() == b.area():
            out.append([b.left, b.bottom, b.right, b.top])
        else:
            raise SystemExit(f"non-rectangular shape in {cell.name}")
    return out


masters, minst = [], {}
for inst in top.each_inst():
    c = inst.cell
    if c.name not in minst:
        minst[c.name] = len(masters)
        masters.append({"name": c.name, "layers": {n: rects(c, idx[n]) for n, _, _ in LAYERS if rects(c, idx[n])}})
insts = []
for inst in top.each_inst():
    t = inst.trans
    assert inst.cell.child_instances() == 0, f"{inst.cell.name} is not a leaf cell"
    # rotation in quarter turns (0-3) and whether it is mirrored (about x, before rotating)
    insts.append([minst[inst.cell.name], t.disp.x, t.disp.y, t.angle, 1 if t.is_mirror() else 0])
topcount = {n: top.shapes(idx[n]).size() for n, _, _ in LAYERS if idx[n] is not None and top.shapes(idx[n]).size()}
json.dump({"dbu": ly.dbu, "layers": [n for n, _, _ in LAYERS], "masters": masters, "insts": insts,
           "topcount": topcount}, open(sys.argv[2], "w"), separators=(",", ":"))
print(len(masters), "masters,", len(insts), "instances,",
      sum(len(r) for m in masters for r in m["layers"].values()), "master rects; top shapes", topcount)
