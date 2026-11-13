#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 Alexei Zverovitch
# SPDX-License-Identifier: Apache-2.0
"""The data for the physical design tutorial, from one harden run: the die, the core and its
rows, and the cells each step adds, read from the step's DEF.

Usage: extract.py RUN_DIR GPL_DIR SPLIT_DIR OUT.json
GPL_DIR holds the global placement's intermediate states (gpl/capture.sh): frames/*.def and
work/*/ (their logs). SPLIT_DIR holds the layouts just before the legalisation that ends the
repair, clock tree and hold steps (split/run_repro.sh): out/<step>/before_legalise.def.
"""
import base64
import os
import glob
import json
import re
import struct
import sys

RUN, GPL, SPLIT, OUT = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
HERE = os.path.dirname(os.path.abspath(__file__))
ORIENTS = ["N", "S", "FN", "FS"]
Q = 10  # positions are stored in units of 10 DBU (0.01 um), to fit 16 bits
DEF = "tt_um_tiny_breakout.def"


def step_def(suffix):
    """The DEF written by the step whose directory ends in -SUFFIX."""
    hits = [d for d in glob.glob(f"{RUN}/[0-9]*-{suffix}") if re.search(rf"/\d+-{suffix}$", d)]
    assert len(hits) == 1, (suffix, hits)
    return f"{hits[0]}/{DEF}"


def lef_sizes(paths):
    """Macro name -> (width, height) in microns."""
    sizes = {}
    for p in paths:
        name = None
        for line in open(p):
            t = line.split()
            if t[:1] == ["MACRO"]:
                name = t[1]
            elif name and t[:1] == ["SIZE"]:
                sizes[name] = (float(t[1]), float(t[3]))
                name = None
    return sizes


def read_def(path):
    """Die area, rows and placed components of a DEF."""
    die, rows, comps = None, [], {}
    in_comps = False
    for line in open(path):
        if line.startswith("DIEAREA"):
            n = list(map(int, re.findall(r"-?\d+", line)))
            die = n[:4]
        elif line.startswith("ROW "):
            t = line.split()
            rows.append({"x": int(t[3]), "y": int(t[4]), "orient": t[5], "n": int(t[7]),
                         "step": int(t[11])})
        elif line.startswith("COMPONENTS"):
            in_comps = True
        elif line.startswith("END COMPONENTS"):
            in_comps = False
        elif in_comps:
            m = re.match(r"\s*- (\S+) (\S+) .*?\+ (PLACED|FIXED|FIRM) \( (-?\d+) (-?\d+) \) (\S+)", line)
            if m:
                comps[m[1]] = (m[2], m[3], int(m[4]), int(m[5]), m[6])
    return die, rows, comps


def read_pdn(path):
    """The power grid: met1 follow-pin rails, met4 stripes and the via stacks joining them."""
    rails, stripes, vias = [], [], set()
    net, in_special = None, False
    for line in open(path):
        if line.startswith("SPECIALNETS"):
            in_special = True
            continue
        if line.startswith("END SPECIALNETS"):
            break
        if not in_special:
            continue
        m = re.match(r"\s*- (\S+)", line)
        if m:
            net = m[1]
        m = re.search(r"(met\d) (\d+) \+ SHAPE (FOLLOWPIN|STRIPE) \( (\d+) (\d+) \) \( (\d+|\*) (\d+|\*) \)", line)
        if m:
            layer, w, shape = m[1], int(m[2]), m[3]
            x0, y0 = int(m[4]), int(m[5])
            x1 = x0 if m[6] == "*" else int(m[6])
            y1 = y0 if m[7] == "*" else int(m[7])
            if shape == "FOLLOWPIN":
                rails.append([net, y0, x0, x1, w])
            else:
                stripes.append([net, layer, x0, y0, y1, w])
            continue
        m = re.search(r"met\d 0 \+ SHAPE STRIPE \( (\d+) (\d+) \) via", line)
        if m:
            vias.add((net, int(m[1]), int(m[2])))
    return {"rails": sorted(rails, key=lambda r: r[1]), "stripes": sorted(stripes, key=lambda s: s[2]),
            "vias": sorted([list(v) for v in vias], key=lambda v: (v[1], v[2]))}


def read_pins(path):
    """Signal pins: name, direction, layer and absolute rectangle."""
    pins = []
    text = open(path).read()
    block = text[text.index("\nPINS "):text.index("END PINS")]
    for item in block.split("\n    - ")[1:]:
        item = " ".join(item.split())
        if "+ SPECIAL" in item:
            continue
        name = item.split()[0]
        d = re.search(r"DIRECTION (\w+)", item)[1]
        layer, a, b, c, e = re.search(r"LAYER (\S+) \( (-?\d+) (-?\d+) \) \( (-?\d+) (-?\d+) \)", item).groups()
        x, y = map(int, re.search(r"(?:PLACED|FIXED) \( (-?\d+) (-?\d+) \)", item).groups())
        pins.append([name, d[0], layer, x + int(a), y + int(b), x + int(c), y + int(e)])
    return sorted(pins, key=lambda p: p[3])


def cell_class(master):
    """What the picture colours a netlist cell as: flip-flop or logic."""
    short = master.replace("sky130_fd_sc_hd__", "")
    return "ff" if re.match(r"e?df|dl", short) else "logic"


def added_class(master, step):
    """What a cell added after synthesis is, by the step that added it."""
    if step == "rsz":
        return "tie" if "conb" in master else "buf"
    return {"cts": "clock", "hold": "hold", "ant": "diode"}[step]


def read_wires(path):
    """Routed signal wires and vias: per net, segments (layer, x0, y0, x1, y1) and vias
    (name, x, y). RECT patches become a segment along their longer side."""
    text = open(path).read()
    block = text[text.index("\nNETS "):text.index("END NETS")]
    out = {}
    for item in block.split(" ;"):
        m = re.match(r"\s*- (\S+)", item)
        if not m or "ROUTED" not in item:
            continue
        segs, vias = [], []
        for part in re.split(r"\+ ROUTED|\bNEW\b", item)[1:]:
            t = part.split()
            layer, pts, i = t[0], [], 1
            while i < len(t) and t[i] in ("TAPER", "TAPERRULE", "STYLE", "MASK"):   # modifiers
                i += 1 if t[i] == "TAPER" else 2
            while i < len(t) and t[i] == "(":
                j = t.index(")", i)
                pts.append(t[i + 1:j]); i = j + 1   # x y, and an optional extension
            x, y = int(pts[0][0]), int(pts[0][1])
            if len(pts) == 2:
                x1 = x if pts[1][0] == "*" else int(pts[1][0])
                y1 = y if pts[1][1] == "*" else int(pts[1][1])
                segs.append((layer, x, y, x1, y1))
                x, y = x1, y1                       # a via after a segment sits at its end
            if i < len(t) and t[i] == "RECT":
                a, b, c, d = (int(v) for v in t[i + 2:i + 6])
                if c - a >= d - b:
                    segs.append((layer, x + a, y + (b + d) // 2, x + c, y + (b + d) // 2))
                else:
                    segs.append((layer, x + (a + c) // 2, y + b, x + (a + c) // 2, y + d))
            elif i < len(t) and t[i] not in ("+", ";"):
                vias.append((t[i], x, y))
        out[m[1]] = (segs, vias)
    return out


def read_paths(path):
    """Timing paths from an OpenSTA report_checks report: start, end, the data path's pins (with
    arrival times) after the launch clock, the clock arrival at the launch and capture flip-flops,
    the capture side's adjustments, required time and slack."""
    paths = []
    for block in open(path).read().split("Startpoint: ")[1:]:
        start = block.split()[0]
        end = re.search(r"Endpoint: (\S+)", block)[1]
        kinds = (re.search(r"^\S+ \(([^)]*)\)", block)[1], re.search(r"Endpoint: \S+ \(([^)]*)\)", block)[1])
        launch, capture = block.split("data arrival time", 1)
        pins, clk_at = [], None
        for line in launch.split("\n"):
            m = re.search(r"(-?[\d.]+)\s+(-?[\d.]+)\s+([\^v])\s+(\S+)(?: \((\S+)\))?\s*$", line)
            if m:
                pins.append({"pin": m[4], "cell": m[5], "time": float(m[2]), "delay": float(m[1]), "edge": m[3]})
        # the data path starts at the launch flip-flop's clock pin
        k = next(i for i, q in enumerate(pins) if q["pin"].endswith("/CLK")) if "flip-flop" in kinds[0] else 0
        clk_at = pins[k]["time"] if k else 0.0
        cap = {}
        for key, pat in (("period", r"([\d.]+)\s+clock clk \(rise edge\)"), ("uncertainty", r"(-?[\d.]+)\s+[\d.]+\s+clock uncertainty"),
                         ("crpr", r"(-?[\d.]+)\s+[\d.]+\s+clock reconvergence pessimism"),
                         ("libtime", r"(-?[\d.]+)\s+[\d.]+\s+library (?:setup|hold) time"),
                         ("required", r"([\d.]+)\s+data required time"), ("slack", r"(-?[\d.]+)\s+slack")):
            mm = re.search(pat, capture)
            if mm:
                cap[key] = float(mm[1])
        cc = [float(x) for x, pin in re.findall(r"([\d.]+) [\^v] (\S+/CLK) ", capture)]
        cap["clock"] = cc[-1] if cc else None
        paths.append({"start": start, "end": end, "kinds": kinds, "launch": clk_at, "pins": pins[k:], **cap})
    return paths


def read_nets(path, keep):
    """Nets whose names match KEEP: name -> [(instance or 'PIN', pin)]."""
    text = open(path).read()
    block = text[text.index("\nNETS "):text.index("END NETS")]
    nets = {}
    for item in block.split(";"):
        m = re.match(r"\s*- (\S+)(.*)", item, re.S)
        if m and re.match(keep, m[1]):
            nets[m[1]] = re.findall(r"\( (\S+) (\S+) \)", m[2])
    return nets


def read_guides(path):
    """Global routing guides: net -> [(x0, y0, x1, y1, layer)]."""
    guides, net, lines = {}, None, open(path).read().split("\n")
    for line in lines:
        t = line.split()
        if len(t) == 1 and t[0] not in "()":
            net = t[0]
            guides[net] = []
        elif len(t) == 5:
            guides[net].append((int(t[0]), int(t[1]), int(t[2]), int(t[3]), t[4]))
    return guides


def split_def(step_suffix):
    hits = glob.glob(f"{SPLIT}/out/[0-9]*-{step_suffix}/before_legalise.def")
    assert len(hits) == 1, (step_suffix, hits)
    return hits[0]


def step_log(suffix):
    hits = [d for d in glob.glob(f"{RUN}/[0-9]*-{suffix}") if re.search(rf"/\d+-{suffix}$", d)]
    assert len(hits) == 1, (suffix, hits)
    return open(glob.glob(f"{hits[0]}/*.log")[0]).read()


def pack(xy):
    """Positions (DBU) as base64 of little-endian uint16 in units of Q."""
    return base64.b64encode(struct.pack(f"<{len(xy)}H", *[round(v / Q) for v in xy])).decode()


def gpl_frames(core, names, sizes, masters):
    """The global placement's states in run order: initial placement after 0..5 conjugate-
    gradient iterations; Nesterov placement stopped at falling overflow targets, first those the
    first descent reaches (above the routability check), then the routability snapshot every
    round rewinds to, then those only the final pass reaches. With 0 iterations nothing is
    written back; the log says every cell starts at the core centre."""
    ip = sorted(glob.glob(f"{GPL}/frames/ip*.def"), key=lambda p: int(re.search(r"ip(\d+)", p)[1]))
    ov = sorted(glob.glob(f"{GPL}/frames/ov*.def"), key=lambda p: -int(re.search(r"ov(\d+)", p)[1]))
    first = [p for p in ov if int(re.search(r"ov(\d+)", p)[1]) >= 30]
    ov = first + [f"{GPL}/frames/snap.def"] + [p for p in ov if p not in first]
    log0 = open(glob.glob(f"{GPL}/work/ip0/*.log")[0]).read()
    assert re.search(r"Core center = %d\b" % len(names), log0), "cells don't start at the core centre"
    cx, cy = (core[0] + core[2]) / 2, (core[1] + core[3]) / 2
    frames = []
    for path in ip + ov:
        tag = re.search(r"/(\w+)\.def$", path)[1]
        log = open(glob.glob(f"{GPL}/work/{tag}/*.log")[0]).read()
        _, _, comps = read_def(path)
        xy = []
        for n in names:
            if tag == "ip0":
                w, h = sizes[masters[n]]
                xy += [cx - w * 500, cy - h * 500]
            else:
                xy += [comps[n][2], comps[n][3]]
        f = {"tag": tag, "xy": pack(xy)}
        if tag.startswith("ip"):
            f["ip"] = int(tag[2:])
        else:
            it, of, hp = re.findall(r"^\s+(\d+) \|\s+([\d.]+) \|\s+([\d.e+]+)", log, re.M)[-1]
            f.update(iter=int(it), overflow=float(of), hpwl=round(float(hp)),
                     rounds=len(re.findall(r"GPL-0040", log)))
            if tag == "snap":
                f["rewind"] = int(re.search(r"snapshot saved at iter = (\d+)", log)[1])
        frames.append(f)
    return frames


def main():
    cfg = json.load(open(f"{RUN}/resolved.json"))
    sizes = lef_sizes(cfg["CELL_LEFS"])

    die, rows, _ = read_def(step_def("openroad-floorplan"))
    x0, y0 = rows[0]["x"], rows[0]["y"]
    site_w = rows[0]["step"]
    row_h = rows[1]["y"] - rows[0]["y"]
    assert all(r["x"] == x0 and r["n"] == rows[0]["n"] for r in rows)
    core = [x0, y0, x0 + rows[0]["n"] * site_w, rows[-1]["y"] + row_h]

    # Cells in site and row units, their masters in one table
    types = []

    def type_index(macro):
        if macro not in types:
            types.append(macro)
        return types.index(macro)

    _, _, tap = read_def(step_def("openroad-tapendcapinsertion"))
    cells = []
    for name, (macro, status, x, y, orient) in sorted(tap.items()):
        if name.startswith("TAP_"):
            kind = "tap"
        elif name.startswith("PHY_EDGE"):
            kind = "endcap"
        else:
            continue
        w = round(sizes[macro][0] * 1000 / site_w)
        cells.append([kind, type_index(macro), (x - x0) // site_w, (y - y0) // row_h, w,
                      orient, name])

    # The netlist's cells, in name order, as global placement finds them
    _, _, gp = read_def(step_def("openroad-globalplacement"))
    names = sorted(n for n in gp if not n.startswith(("TAP_", "PHY_")))
    masters = {n: gp[n][0] for n in names}
    netlist = {
        "names": names,
        "type": [type_index(masters[n]) for n in names],
        "w": [round(sizes[masters[n]][0] * 1000 / Q) for n in names],
        "cls": [cell_class(masters[n]) for n in names],
    }
    gpl = gpl_frames(core, names, sizes, masters)
    last = struct.unpack(f"<{2 * len(names)}H", base64.b64decode(gpl[-1]["xy"]))
    assert all(abs(last[2 * i] * Q - gp[n][2]) < Q and abs(last[2 * i + 1] * Q - gp[n][3]) < Q
               for i, n in enumerate(names)), "the last frame isn't the run's placement"

    # Every cell from global placement on: the netlist's, then each step's additions. Each
    # stage is a snapshot of all of them: the layout just before a step's closing legalisation
    # (the "B" stages, from split/) and the step's own result.
    phys = lambda d: {n: v for n, v in d.items() if not n.startswith(("TAP_", "PHY_"))}
    stages = [
        ("rszB", phys(read_def(split_def("openroad-repairdesignpostgpl"))[2])),
        ("dpl", phys(read_def(step_def("openroad-detailedplacement"))[2])),
        ("ctsB", phys(read_def(split_def("openroad-cts"))[2])),
        ("cts", phys(read_def(step_def("openroad-cts"))[2])),
        ("holdB", phys(read_def(split_def("openroad-resizertimingpostcts"))[2])),
        ("hold", phys(read_def(step_def("openroad-resizertimingpostcts"))[2])),
        ("ant", phys(read_def(glob.glob(f"{RUN}/*-openroad-repairantennas/*-openroad-diodeinsertion/{DEF}")[0])[2])),
    ]
    assert phys(read_def(step_def("openroad-repairdesignpostgpl"))[2]) == stages[1][1], \
        "detailed placement changed the repaired layout"
    union, cls, seen = list(names), list(netlist["cls"]), set(names)
    for step, st in (("rsz", stages[0][1]), ("cts", stages[2][1]), ("hold", stages[4][1]), ("ant", stages[6][1])):
        new = sorted(n for n in st if n not in seen)
        union += new
        cls += [added_class(st[n][0], step) for n in new]
        seen.update(new)
    # existing cells stay put until a legalisation moves them
    for (_, before), (_, after) in ((stages[1], stages[2]), (stages[3], stages[4])):
        assert all(after[n][2:4] == before[n][2:4] for n in before if n in after), "a B stage moved cells"
    assert all(stages[0][1][n][2:4] == gp[n][2:4] for n in names if n in stages[0][1]), "repair moved cells"
    kf = {}
    for sid, st in stages:
        xy, orient, typ = [], [], []
        for n in union:
            if n in st:
                xy += [st[n][2], st[n][3]]
                orient.append(ORIENTS.index(st[n][4]))
                typ.append(type_index(st[n][0]))
            else:
                xy += [0xFFFF * Q, 0xFFFF * Q]
                orient.append(255)
                typ.append(255)
        kf[sid] = {"xy": pack(xy), "orient": base64.b64encode(bytes(orient)).decode(),
                   "type": base64.b64encode(bytes(typ)).decode()}
    assert len(types) < 255
    widths = [round(sizes[t][0] * 1000 / Q) for t in types]

    def disp(a, b):
        """Moves (Euclidean, um) of the cells in both: mean over all, max, how many moved, and
        the mean over those that moved."""
        d = [((a[n][2] - b[n][2]) ** 2 + (a[n][3] - b[n][3]) ** 2) ** 0.5 / 1000 for n in a if n in b]
        mv = [v for v in d if v > 0]
        return [round(sum(d) / len(d), 2), round(max(d), 2), len(mv), round(sum(mv) / len(mv), 2) if mv else 0]

    rlog, clog, hlog = (step_log(x) for x in ("openroad-repairdesignpostgpl", "openroad-cts",
                                              "openroad-resizertimingpostcts"))
    num = lambda pat, text, f=int: f(re.search(pat, text)[1])
    glog = step_log("openroad-globalplacement")
    inbufs = sorted(n for n in stages[0][1] if re.match(r"input\d+$", n))
    allnets_ = read_nets(step_def("openroad-detailedrouting"), r".")
    buffered = sorted(c[1] for nm, conns in allnets_.items() if any(c_[0] in inbufs and c_[1] == "A" for c_ in conns)
                      for c in conns if c[0] == "PIN")
    meta = {
        "gpl": {"target": num(r"Placement target density:\s+([\d.]+)", glog, float),
                "asked": num(r"Target density ([\d.]+) is too low", glog, float),
                "util": num(r"Utilization:\s+([\d.]+)", glog, float),
                # all instances' area (fixed included), and the padding added for pin density
                "area": num(r"Total instances area:\s+([\d.]+)", glog, float),
                "pinadj": num(r"Pin density area adjust:\s+([\d.]+)", glog, float),
                "bins": num(r"Bin count \(X, Y\):\s+(\d+)", glog)},
        "sdc": {"slew": cfg["MAX_TRANSITION_CONSTRAINT"], "cap": cfg["MAX_CAPACITANCE_CONSTRAINT"],
                "fanout": cfg["MAX_FANOUT_CONSTRAINT"], "uncertainty": cfg["CLOCK_UNCERTAINTY_CONSTRAINT"],
                "period": cfg["CLOCK_PERIOD"], "slewpct": cfg["DESIGN_REPAIR_MAX_SLEW_PCT"],
                "cappct": cfg["DESIGN_REPAIR_MAX_CAP_PCT"]},
        "inputs": buffered,
        "rsz": {"inbuf": num(r"Inserted (\d+) \S+ input buffers", rlog), "slew": num(r"Found (\d+) slew violations", rlog),
                "fanout": num(r"Found (\d+) fanout violations", rlog), "resized": num(r"Resized (\d+) instances", rlog),
                "buffers": num(r"Inserted (\d+) buffers in", rlog), "nets": num(r"buffers in (\d+) nets", rlog)},
        "dpl": {"mirrored": num(r"Mirrored (\d+) instances", rlog),
                "hpwl": [num(r"original HPWL\s+([\d.]+)", rlog, float), num(r"legalized HPWL\s+([\d.]+)", rlog, float),
                         num(r"HPWL after\s+([\d.]+)", rlog, float)],
                "disp": disp(stages[0][1], stages[1][1])},
        "cts": {"sinks": num(r"has (\d+) sinks", clog), "clusters": num(r"sinks after clustering: (\d+)", clog),
                "buffers": num(r"Created (\d+) clock buffers", clog), "dummies": num(r"Dummy loads inserted (\d+)", clog),
                "depth": num(r"Maximum number of buffers in the clock path: (\d+)", clog),
                "mindepth": num(r"Minimum number of buffers in the clock path: (\d+)", clog),
                "maxsinks": num(r"clustering size of (\d+)", clog),
                "mirrored": num(r"Mirrored (\d+) instances", clog), "disp": disp(stages[2][1], stages[3][1]),
                # the clock nets routed with a non-default rule (wider spacing), from the routed DEF
                "ndr": re.findall(r"(?m)^\s+- (\S+) .*\+ NONDEFAULTRULE ", open(step_def("openroad-detailedrouting")).read())},
        "hold": {"endpoints": num(r"Found (\d+) endpoints with hold violations", hlog),
                 "buffers": num(r"Inserted (\d+) hold buffers", hlog),
                 "wns": [float(x) for x in re.findall(r"^\s+(?:0|final) \|(?:[^|]*\|){4}\s*(-?[\d.]+)", hlog, re.M)],
                 "area": re.search(r"^\s+final \|(?:[^|]*\|){3}\s*(\S+)", hlog, re.M)[1],
                 "margin": float(re.search(r"-hold_margin ([\d.]+)", hlog)[1]),
                 "mirrored": num(r"Mirrored (\d+) instances", hlog), "disp": disp(stages[4][1], stages[5][1])},
    }
    # The clock tree: each clock net's driver and loads, as indices into the cell list (-1: the pin)
    idx = {n: i for i, n in enumerate(union)}
    cnets = read_nets(step_def("openroad-cts"), r"clk$|clknet_")
    clock = []
    for name, conns in sorted(cnets.items()):
        drv = [c for c in conns if c[0] == "PIN" or c[1] in ("X", "Y")]
        assert len(drv) == 1, name
        clock.append([name, -1 if drv[0][0] == "PIN" else idx[drv[0][0]],
                      [idx[c[0]] for c in conns if c is not drv[0]]])
    # Global routing guides, in g-cells, layer by layer
    guides = read_guides(glob.glob(f"{RUN}/*-openroad-globalrouting/after_grt.guide")[0])
    gsize = min(r[2] - r[0] for g in guides.values() for r in g)
    # FastRoute's grid: whole g-cells, the last column and row stretched to the die edge
    gnx, gny = die[2] // gsize, die[3] // gsize
    gcol = lambda x: min(x // gsize, gnx - 1)
    grow_ = lambda y: min(y // gsize, gny - 1)
    glayers = ["li1", "met1", "met2", "met3", "met4"]
    gnames = sorted(guides)
    gbytes, gcount = bytearray(), []
    for n in gnames:
        gcount.append(len(guides[n]))
        for x0, y0, x1, y1, layer in guides[n]:
            # x1, y1 may end off the g-cell grid at the die edge: round up
            gbytes += bytes([gcol(x0), grow_(y0), gcol(x1 - 1) + 1, grow_(y1 - 1) + 1, glayers.index(layer)])
    grtlog = step_log("openroad-globalrouting")
    pitch = {m[0]: float(m[1]) for m in re.findall(r"Layer (\S+)\s+Track-Pitch = ([\d.]+)", grtlog)}
    # Example nets for the animation: a two-pin net, a few-pin net and the widest net on three
    # or more layers, none of them clock nets; each with its pins (cells, or top-level pins)
    allnets = read_nets(step_def("openroad-globalrouting"), r".")
    def span(n):
        return sum((x1 - x0) * (y1 - y0) for x0, y0, x1, y1, _ in guides[n]) // (gsize * gsize)
    def nlayers(n):
        return len({r[4] for r in guides[n]})
    ok = [n for n in gnames if not re.match(r"clk|clknet", n) and n in allnets]
    pins_of = lambda n: allnets[n]
    two = max((n for n in ok if len(pins_of(n)) == 2 and nlayers(n) >= 2), key=span)
    few = max((n for n in ok if 4 <= len(pins_of(n)) <= 6 and nlayers(n) >= 3), key=span)
    wide = max((n for n in ok if nlayers(n) >= 3 and n not in (two, few)), key=span)
    examples = []
    for n in (two, few, wide):
        conns = pins_of(n)
        examples.append({"net": gnames.index(n),
                         "cells": [idx[c[0]] for c in conns if c[0] != "PIN"],
                         "pins": [c[1] for c in conns if c[0] == "PIN"]})
    usage = {m[0]: float(m[1]) for m in re.findall(r"^(met\d)\s+\d+\s+\d+\s+([\d.]+)%", grtlog, re.M)}
    grt = {"g": gsize, "nx": gnx, "ny": gny, "layers": glayers, "nets": gnames, "count": gcount,
           "pitch": [pitch[l] for l in glayers], "examples": examples,
           "adjust": num(r"Global adjustment: (\d+)%", grtlog), "extra": len(re.findall(r"Start extra iteration", grtlog)),
           "rects": base64.b64encode(bytes(gbytes)).decode(), "usage": usage,
           "wirelength": num(r"Total wirelength: (\d+)", grtlog), "routed": num(r"Routed nets: (\d+)", grtlog),
           "overflow": num(r"(?m)^Total\s+\d+\s+\d+\s+[\d.]+%\s+\d+ /\s+\d+ /\s+(\d+)", grtlog, int)}
    # Antenna repair: the violation it fixes, and the orientations it resets
    alog = open(glob.glob(f"{RUN}/*-openroad-checkantennas/reports/antenna_summary.rpt")[0]).read()
    am = re.search(r"\u2502\s*([\d.]+)\s*\u2502\s*([\d.]+)\s*\u2502\s*([\d.]+)\s*\u2502\s*(\S+)\s*\u2502\s*(\S+)\s*\u2502\s*(\S+)\s*\u2502", alog)
    hold_st, ant_st = stages[5][1], stages[6][1]
    meta["ant"] = {"pr": float(am[1]), "partial": float(am[2]), "required": float(am[3]), "net": am[4], "pin": am[5],
                   "layer": am[6], "diodes": sum(1 for n in ant_st if n not in hold_st),
                   "moved": sum(1 for n in hold_st if n in ant_st and hold_st[n][2:4] != ant_st[n][2:4]),
                   "flipped": sum(1 for n in hold_st if n in ant_st and hold_st[n][4] != ant_st[n][4])}
    assert phys(read_def(step_def("openroad-detailedrouting"))[2]).keys() >= ant_st.keys()
    # Detailed routing: every signal wire and via, nets in the guides' order; positions in
    # units of 5 DBU (the manufacturing grid)
    wires = read_wires(step_def("openroad-detailedrouting"))
    wl = ["li1", "met1", "met2", "met3", "met4"]
    vtypes = sorted({v[0] for sg, vs in wires.values() for v in vs})
    sb, vb, scount, vcount, length = bytearray(), bytearray(), [], [], {l: 0 for l in wl}
    for n in gnames:
        sg, vs = wires.get(n, ([], []))
        scount.append(len(sg)); vcount.append(len(vs))
        for layer, x0, y0, x1, y1 in sg:
            sb += struct.pack("<4HB", x0 // 5, y0 // 5, x1 // 5, y1 // 5, wl.index(layer))
            length[layer] += abs(x1 - x0) + abs(y1 - y0)
        for name, x, y in vs:
            vb += struct.pack("<2HB", x // 5, y // 5, vtypes.index(name))
    assert sum(len(w[0]) for w in wires.values()) == sum(scount), "wires on nets without guides"
    # how many nets' guides antenna repair re-made (their g-cells per layer changed)
    post_all = read_guides(os.path.join(HERE, "guides", "post_antenna.guide"))
    def cover(rects):
        cells = set()
        for x0, y0, x1, y1, layer in rects:
            for gx in range(gcol(x0), gcol(x1 - 1) + 1):
                for gy in range(grow_(y0), grow_(y1 - 1) + 1):
                    cells.add((gx, gy, layer))
        return cells
    meta["ant"]["rerouted"] = sum(1 for n in gnames if cover(guides[n]) != cover(post_all.get(n, [])))
    # the guides detailed routing followed (antenna repair re-made some): for the example nets,
    # which must hold their wires
    post = post_all
    for ex in examples:
        n = gnames[ex["net"]]
        eb = bytearray()
        for x0, y0, x1, y1, layer in post[n]:
            eb += bytes([gcol(x0), grow_(y0), gcol(x1 - 1) + 1, grow_(y1 - 1) + 1, glayers.index(layer)])
        ex["guides"] = base64.b64encode(bytes(eb)).decode()
        # in plan view every wire lies inside the net's guides; the router may still pick
        # another layer than the guide planned (it treats the layer as a preference)
        inside = lambda x, y, ly=None: any(gx0 <= x <= gx1 and gy0 <= y <= gy1 and (ly is None or gl_ == ly)
                                           for gx0, gy0, gx1, gy1, gl_ in post[n])
        segs_ = wires[n][0]
        bad = [sg for sg in segs_ if not (inside(sg[1], sg[2]) and inside(sg[3], sg[4]))]
        assert not bad, f"{n}: wires outside its guides: {bad[:3]}"
        ex["offlayer"] = round(sum(abs(sg[3] - sg[1]) + abs(sg[4] - sg[2]) for sg in segs_
                                   if not (inside(sg[1], sg[2], sg[0]) and inside(sg[3], sg[4], sg[0]))) / 1000, 1)
    dlog = step_log("openroad-detailedrouting")
    dm = json.load(open(f"{RUN}/final/metrics.json"))
    drt = {"layers": wl, "vtypes": vtypes, "segs": base64.b64encode(bytes(sb)).decode(), "scount": scount,
           "vias": base64.b64encode(bytes(vb)).decode(), "vcount": vcount,
           "length": {l: int(v) for l, v in re.findall(r"Total wire length on LAYER (\S+) = (\d+) um", dlog)[-6:] if l in wl},
           "iters": [int(x) for x in re.findall(r"Number of violations = (\d+)", dlog)],
           "wirelength": dm["route__wirelength"], "nvias": dm["route__vias"],
           "runtime": open(glob.glob(f"{RUN}/*-openroad-detailedrouting/runtime.txt")[0]).read().strip()}
    # Fill: the filler cells, in site and row units
    x0c, y0c = core[0], core[1]
    _, _, fl = read_def(step_def("openroad-fillinsertion"))
    fill = [[type_index(m), (x - x0c) // site_w, (y - y0c) // row_h, round(sizes[m][0] * 1000 / site_w)]
            for nme, (m, st_, x, y, o) in sorted(fl.items()) if nme.startswith("FILLER")]
    # Signoff timing: the worst register-to-register setup path (slow corner, maximum
    # parasitics) and the worst hold path (fast corner, minimum parasitics), and the summary
    sta_dir = glob.glob(f"{RUN}/*-openroad-stapostpnr")[0]
    def reg2reg(ps):
        return [q for q in ps if "flip-flop" in q["kinds"][0] and "flip-flop" in q["kinds"][1]]
    setup = min(reg2reg(read_paths(f"{sta_dir}/max_ss_100C_1v60/max.rpt")), key=lambda q: q["slack"])
    hold = min(reg2reg(read_paths(f"{sta_dir}/min_ff_n40C_1v95/min.rpt")), key=lambda q: q["slack"])
    nets_by_pin = {}
    for nm, conns in allnets.items():
        for inst, pin in conns:
            nets_by_pin[f"{inst}/{pin}"] = nm
    def sta_path(q):
        stages = []
        for pp in q["pins"]:
            inst = pp["pin"].split("/")[0]
            stages.append([pp["pin"], pp["cell"].replace("sky130_fd_sc_hd__", "") if pp["cell"] else None,
                           round(pp["time"], 4), idx.get(inst, -1), gnames.index(nets_by_pin[pp["pin"]]) if pp["pin"] in nets_by_pin and nets_by_pin[pp["pin"]] in gnames else -1])
        out = {k: q[k] for k in ("start", "end", "launch", "clock", "period", "uncertainty", "crpr", "libtime", "required", "slack") if k in q}
        out["stages"] = stages
        return out
    summary = open(f"{sta_dir}/summary.rpt").read()
    corners = {}
    for m in re.finditer(r"\u2502 (\w+_\w+_\w+_\w+)\s+\u2502\s*([-\d.]+)\s*\u2502\s*([-\d.]+)\s*\u2502(?:[^\u2502]*\u2502){3}\s*([-\d.]+)\s*\u2502\s*([-\d.]+)\s*\u2502(?:[^\u2502]*\u2502){4}\s*(\d+)\s*\u2502", summary):
        corners[m[1]] = {"hold": float(m[2]), "setup": float(m[4]), "setup_r2r": float(m[5]), "slew": int(m[6])}
    # the worst setup path of all, any kind, in the slow corner
    worst = min(read_paths(f"{sta_dir}/max_ss_100C_1v60/max.rpt"), key=lambda q: q["slack"])
    derate = num(r"Setting timing derate to: ([\d.]+)%", open(f"{sta_dir}/max_ss_100C_1v60/sta.log").read(), float)
    sta = {"setup": sta_path(setup), "hold": sta_path(hold), "corners": corners, "derate": derate,
           "worst": {"start": worst["start"], "end": worst["end"], "slack": worst["slack"]}}
    # IR drop: each instance's power and ground pin voltage (tt corner), as a drop in microvolts
    irdir = glob.glob(f"{RUN}/*-openroad-irdropreport")[0]
    ir = {}
    for net, supply in (("VPWR", 1.8), ("VGND", 0.0)):
        rows_ = [l.split(",") for l in open(f"{irdir}/net-{net}.csv").read().split("\n")[1:] if l]
        pts = bytearray()
        for r_ in rows_:
            drop = abs(float(r_[5]) - supply) * 1e6
            pts += struct.pack("<3H", round(float(r_[3]) * 100), round(float(r_[4]) * 100), round(drop * 100))
        ir[net] = base64.b64encode(bytes(pts)).decode()
    irlog = open(glob.glob(f"{irdir}/*.log")[0]).read()
    ir["worst"] = [float(x) * 1e6 for x in re.findall(r"Worstcase IR drop: ([\d.e+-]+)", irlog)]
    ir["average"] = [float(x) * 1e6 for x in re.findall(r"Average IR drop  : ([\d.e+-]+)", irlog)]
    ir["power"] = float(re.search(r"Total power      : ([\d.e+-]+)", irlog)[1])
    ir["corner"] = re.search(r"Corner           : (\S+)", irlog)[1]
    # The GDS: each master's rectangles, and every instance; vias from their definitions
    g = json.load(open(os.path.join(HERE, "gds", "gds.json")))
    gl = g["layers"]
    mb = []
    for mm in g["masters"]:
        b = bytearray()
        for ln, rr in mm["layers"].items():
            for x0, y0, x1, y1 in rr:
                b += struct.pack("<B4h", gl.index(ln), x0, y0, x1, y1)
        mb.append(base64.b64encode(bytes(b)).decode())
    ib = bytearray()
    for mi, x, y, rot, mir in g["insts"]:
        ib += struct.pack("<B2HB", mi, x // 5, y // 5, rot + 4 * mir)
    vdefs = {}
    for v in vtypes:
        text_ = open(cfg["TECH_LEFS"]["nom_*"]).read()
        blk = re.search(rf"^VIA {v} DEFAULT(.*?)^END {v}", text_, re.S | re.M)[1]
        vdefs[v] = [[ly, *[round(float(c) * 1000) for c in rc.split()]] for ly, rcs in re.findall(r"LAYER (\S+) ;((?:\s*RECT[^;]*;)+)", blk)
                    for rc in re.findall(r"RECT ([^;]*);", rcs)]
    # the power grid's generated vias (DEF VIAS: cut size, spacing, enclosure, rows and columns)
    pdnvias = []
    deftext = open(step_def("openroad-generatepdn")).read()
    for vm in re.finditer(r"- (\S+) \+ VIARULE \S+ \+ CUTSIZE (\d+) (\d+)\s+\+ LAYERS (\S+) (\S+) (\S+)\s+\+ CUTSPACING (\d+) (\d+)\s+\+ ENCLOSURE (\d+) (\d+) (\d+) (\d+)\s+\+ ROWCOL (\d+) (\d+)", deftext):
        cw, ch, bot, cut, topl = int(vm[2]), int(vm[3]), vm[4], vm[5], vm[6]
        sxp, syp, e = int(vm[7]), int(vm[8]), [int(vm[k]) for k in range(9, 13)]
        rows_n, cols_n = int(vm[13]), int(vm[14])
        aw, ah = cols_n * cw + (cols_n - 1) * sxp, rows_n * ch + (rows_n - 1) * syp
        rr = [[bot, -aw // 2 - e[0], -ah // 2 - e[1], aw // 2 + e[0], ah // 2 + e[1]],
              [topl, -aw // 2 - e[2], -ah // 2 - e[3], aw // 2 + e[2], ah // 2 + e[3]]]
        for r_ in range(rows_n):
            for c_ in range(cols_n):
                x0 = -aw // 2 + c_ * (cw + sxp); y0 = -ah // 2 + r_ * (ch + syp)
                rr.append([cut, x0, y0, x0 + cw, y0 + ch])
        pdnvias.append(rr)
    assert len(pdnvias) == 3, pdnvias
    gds = {"layers": gl, "pdnvias": pdnvias, "masters": [mm["name"].replace("sky130_fd_sc_hd__", "") for mm in g["masters"]], "mrects": mb,
           "insts": base64.b64encode(bytes(ib)).decode(), "vias": vdefs, "topcount": g["topcount"]}
    # the pins this design leaves unconnected: their nets have no routing in the final DEF
    dtext = open(step_def("openroad-detailedrouting")).read()
    pin_nets = re.findall(r"^\s+- (\S+) \+ NET (\S+)", dtext[dtext.index("\nPINS "):dtext.index("END PINS")], re.M)
    nets_text = dtext[dtext.index("\nNETS "):dtext.index("END NETS")]
    def routed(net):
        m = re.search(r"\n\s+- " + re.escape(net) + r" (.*?);", nets_text, re.S)
        return bool(m) and "ROUTED" in m[1]
    unused_pins = [pn.replace("\\", "") for pn, nt in pin_nets if pn not in ("VPWR", "VGND") and not routed(nt)]
    later = {"unusedPins": unused_pins, "names": union[len(names):], "cls": cls[len(names):], "kf": kf, "widths": widths, "meta": meta,
             "drt": drt, "fill": fill, "sta": sta, "ir": ir, "gds": gds,
             "clock": clock, "grt": grt}

    pdn = read_pdn(step_def("openroad-generatepdn"))
    pins = read_pins(step_def("odb-applydeftemplate"))

    data = {
        "netlist": netlist,
        "gpl": gpl,
        "cells": later,
        "pdn": pdn,
        "pins": pins,
        "units": 1000,
        "die": die, "core": core,
        "site": [site_w, row_h],
        "rows": [1 if r["orient"] == "FS" else 0 for r in rows],
        "sitesPerRow": rows[0]["n"],
        "types": types,
        "fixed": cells,           # [kind, type, site, row, width in sites, orientation, instance]
        # the netlist's cells: all still unplaced in the floorplan DEF
        "netlistCells": sum(1 for line in open(step_def("openroad-floorplan"))
                            if re.match(r"\s+- \S+ sky130_", line)),
    }
    json.dump(data, open(OUT, "w"), separators=(",", ":"))
    print(f"{OUT}: {len(cells)} fixed cells, {len(rows)} rows, netlist {data['netlistCells']}, "
          f"{len(gpl)} placement frames")


main()
