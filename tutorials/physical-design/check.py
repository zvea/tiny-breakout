"""Checks the built tutorial page in a browser, at the screen sizes it supports.

Usage (from the repo root, in the project's .venv):

    .venv/bin/python tutorials/physical-design/check.py [--only CHECK,...] [--size WxH[t],...] [PAGE]

PAGE defaults to tutorials/physical-design.html. Sizes are laptops and tablets in landscape;
t marks a touch screen. It prints what it finds and exits 0 if it finds nothing, 1 if it finds
something, and 2 if it cannot run (a bad argument, or a page that does not start). The checks:

- layout (every size, both themes): at the start and end of every step, that the legend, zoom
  buttons, play bar, scale and play prompt do not overlap, that the page does not scroll
  sideways, and that no step name in the stepper is clipped or runs into the next.
- callouts (every size): at the picture each step waits on and through its animation, that each
  callout has a place, stays inside the view, and overlaps no other callout, the legend, the
  zoom buttons, the play bar, the scale or the play prompt, and that the Floorplan close-up
  shows.
- keyboard (the first size): that Tab from the panel text goes on to the picture, that the
  arrow keys step the tutorial after a click on the stepper, that replaying a part from its
  badge keeps the panel's scroll and focus, and that the play prompt is the first thing Tab
  reaches in the picture.
- touch (the touch sizes): that a tap on a term opens its popup and a tap elsewhere closes it,
  that a tap on the picture names what is under it, and that a drag moves the view.
- transitions (the first size): that pressing Play goes straight on from the picture the step
  waited on, measured over the first two frames on a paused clock; a step whose camera moves
  as it starts (GDS) changes the picture by design and is left out.

Script errors on the page are reported whichever checks run. For the callouts check the page
records each frame's callouts in window.pdProbe, which only this script sets.
"""
import argparse
import contextlib
import functools
import http.server
import re
import sys
import threading
import time
from pathlib import Path

from playwright.sync_api import Error as PlaywrightError
from playwright.sync_api import sync_playwright

SIZES = [(1440, 900, False), (1366, 768, False), (1280, 800, False), (1280, 700, False),
         (1180, 820, True), (1024, 768, True)]
DEFAULT_PAGE = Path(__file__).resolve().parent.parent / "physical-design.html"
SAMPLES = 10       # points along each animation the callouts check looks at, besides the start
START_MS = 15000   # how long a page may take to unpack its data and start


class PageError(Exception):
    """The page did not start; the message holds its script errors."""


def tag(size):
    w, h, touch = size
    return f"{w}x{h}{'t' if touch else ''}"


# ---- the session: a local server for the page, and a browser --------------------------------------

class _Quiet(http.server.SimpleHTTPRequestHandler):
    def log_message(self, *args):
        pass


class Session:
    """Serves the page's folder on a free local port and opens a browser; collects script errors."""

    def __init__(self, page, sizes=SIZES):
        self.page_path = Path(page).resolve()
        self.sizes = list(sizes)
        self.errors = []

    def __enter__(self):
        with contextlib.ExitStack() as stack:   # what is started is stopped again if a later part fails
            handler = functools.partial(_Quiet, directory=str(self.page_path.parent))
            server = http.server.ThreadingHTTPServer(("127.0.0.1", 0), handler)
            stack.callback(server.server_close)
            threading.Thread(target=server.serve_forever, daemon=True).start()
            stack.callback(server.shutdown)
            self.url = f"http://127.0.0.1:{server.server_address[1]}/{self.page_path.name}"
            pw = sync_playwright().start()
            stack.callback(pw.stop)
            browser = pw.chromium.launch()
            stack.callback(browser.close)
            self._browser = browser
            self._stack = stack.pop_all()
        return self

    def __exit__(self, *exc):
        self._stack.close()

    @contextlib.contextmanager
    def open(self, size, theme="light", reduced=False, probe=False, step=""):
        """The page at a size, started; its script errors go to self.errors."""
        w, h, touch = size
        ctx = self._browser.new_context(viewport={"width": w, "height": h}, has_touch=touch, color_scheme=theme,
                                        reduced_motion="reduce" if reduced else "no-preference")
        try:
            if probe:
                ctx.add_init_script("window.pdProbe = { frame: null };")
            pg = ctx.new_page()
            pg.on("pageerror", lambda e: self.errors.append(f"{tag(size)}: script error: {e}"))
            pg.on("console", lambda m: m.type == "error" and self.errors.append(f"{tag(size)}: console error: {m.text}"))
            pg.goto(self.url + ("#" + step if step else ""))
            # started once the stepper is built, which the page does once its data is unpacked
            try:
                pg.wait_for_function("() => document.querySelectorAll('#track .seg').length > 0", timeout=START_MS)
            except PlaywrightError:
                said = pg.evaluate("() => { const l = document.getElementById('loading'); return l ? l.textContent : ''; }")
                raise PageError(f"{tag(size)}: the page did not start" + (f" ({said})" if said else "")
                                + "".join("\n  " + e for e in self.errors)) from None
            pg.wait_for_timeout(300)
            yield pg
        finally:
            ctx.close()


# ---- moving about the page -------------------------------------------------------------------

def steps(pg):
    """The number of steps, from the stepper."""
    return pg.locator("#track .seg").count()


def jump(pg, i):
    """Step i from the stepper (a step that plays waits at its start), with the mouse out of the way."""
    pg.locator("#track .seg").nth(i).click()
    pg.mouse.move(0, 0)
    pg.wait_for_timeout(120)


def plays(pg):
    """Whether the current step has an animation to play."""
    return pg.is_visible("#readout")


def scrub(pg, v):
    """The current step's animation at v (0 to 1000), as the play bar's slider sets it."""
    pg.evaluate("v => { const s = document.getElementById('scrub'); s.value = v; s.dispatchEvent(new Event('input', { bubbles: true })); }", v)
    pg.wait_for_timeout(60)


def slug(pg):
    """The current step's name in the URL."""
    return pg.evaluate("() => location.hash.slice(1)")


# the boxes of the controls over the picture, relative to it
BOXES = """() => {
  const v = document.getElementById('view').getBoundingClientRect();
  const box = el => { if (!el || el.hidden || !el.getClientRects().length) return null;
    const r = el.getBoundingClientRect(); return r.width && r.height ? [r.left - v.left, r.top - v.top, r.right - v.left, r.bottom - v.top] : null; };
  const legend = document.getElementById('legend');
  return { W: v.width, H: v.height,
    legend: legend.children.length ? box(legend) : null, zoom: box(document.querySelector('.zoom')),
    'play bar': box(document.getElementById('readout')), scale: box(document.querySelector('.scale')),
    'play prompt': box(document.getElementById('playprompt')) };
}"""
CONTROLS = ("legend", "zoom", "play bar", "scale", "play prompt")


def overlap(a, b):
    return a is not None and b is not None and a[0] < b[2] - 1 and b[0] < a[2] - 1 and a[1] < b[3] - 1 and b[1] < a[3] - 1


# ---- layout ------------------------------------------------------------------------------------

STEPPER = """() => {
  const labels = [...document.querySelectorAll('#track .seg .long')].filter(l => getComputedStyle(l).visibility !== 'hidden' && getComputedStyle(l).display !== 'none');
  const now = document.querySelector('#track .seg.now .long');
  // clipped: cut off at its box. The current step's name, in bold, may instead run over its box,
  // as long as it does not reach the names beside it.
  const clipped = labels.filter(l => getComputedStyle(l).overflow !== 'visible' && l.scrollWidth > l.clientWidth + 1).map(l => l.textContent);
  const r = el => el.getBoundingClientRect();
  const crowded = now && labels.includes(now) ? labels.filter(l => l !== now).filter(l => { const a = r(now), b = r(l); return a.left < b.right && b.left < a.right; }).map(l => l.textContent) : [];
  return { clipped, crowded, now: now ? now.textContent : '', sideways: document.documentElement.scrollWidth > innerWidth + 1 };
}"""
PAIRS = (("legend", "zoom", "the legend overlaps the zoom buttons"),
         ("play bar", "scale", "the play bar overlaps the scale"),
         ("play prompt", "legend", "the play prompt overlaps the legend"),
         ("play prompt", "play bar", "the play prompt overlaps the play bar"))


def layout(s):
    found = []
    for size in s.sizes:
        for theme in ("light", "dark"):
            with s.open(size, theme, reduced=True) as pg:
                for i in range(steps(pg)):
                    jump(pg, i)
                    states = [("start", None), ("end", 1000)] if plays(pg) else [("end", None)]
                    for when, v in states:
                        if v is not None:
                            scrub(pg, v)
                        where = f"{tag(size)} {theme} {slug(pg)} ({when})"
                        b = pg.evaluate(BOXES)
                        found += [f"{where}: {text}" for x, y, text in PAIRS if overlap(b[x], b[y])]
                        st = pg.evaluate(STEPPER)
                        if st["sideways"]:
                            found.append(f"{where}: the page scrolls sideways")
                        found += [f"{where}: step name clipped: {n}" for n in st["clipped"]]
                        found += [f"{where}: step name {st['now']} runs into {n}" for n in st["crowded"]]
    return found


# ---- callouts ----------------------------------------------------------------------------------

SHOWN = 0.3   # a callout fainter than this (fading in or out) is not checked


def callouts(s):
    found = []
    for size in s.sizes:
        with s.open(size, reduced=True, probe=True) as pg:
            edge = pg.evaluate("() => window.pdProbe.edge")   # the margin the page keeps callouts from the sides
            for i in range(steps(pg)):
                jump(pg, i)
                # the picture a step waits on, then points through its animation
                points = [None] + ([round(1000 * (k + 1) / SAMPLES) for k in range(SAMPLES)] if plays(pg) else [])
                for v in points:
                    if v is not None:
                        scrub(pg, v)
                    where = f"{tag(size)} {slug(pg)}" + (f" at {v / 10:g}%" if v is not None else "")
                    frame = pg.evaluate("() => window.pdProbe.frame")
                    found += frame_findings(where, frame, pg.evaluate(BOXES), edge)
                    if slug(pg) == "floorplan" and not frame["lens"]:
                        found.append(f"{where}: the close-up not shown")
    return found


def frame_findings(where, frame, b, edge):
    found = []
    shown = [c for c in frame["placed"] if c["alpha"] > SHOWN]
    placed = {c["text"] for c in frame["placed"]}
    # a callout the page tried and could not place, unless it found a place on a second try
    for t in sorted({c["text"] for c in frame["unplaced"] if c["alpha"] > SHOWN} - placed):
        found.append(f"{where}: no place for callout {t!r}")
    for j, c in enumerate(shown):
        x0, y0, x1, y1 = c["box"]
        if x0 < edge - 1 or y0 < 0 or x1 > b["W"] - edge + 1 or y1 > b["H"]:
            found.append(f"{where}: callout {c['text']!r} outside the view")
        found += [f"{where}: callout {c['text']!r} overlaps the {name}" for name in CONTROLS if overlap(c["box"], b[name])]
        found += [f"{where}: callout {c['text']!r} overlaps callout {d['text']!r}" for d in shown[j + 1:] if overlap(c["box"], d["box"])]
    return found


# ---- keyboard ----------------------------------------------------------------------------------

FOCUS = "() => { const a = document.activeElement; return { id: a.id, inStage: !!a.closest('.stage') }; }"
TABS = 80   # enough to Tab through any step's terms and their popups' links


def keyboard(s):
    size = s.sizes[0]
    with s.open(size) as pg:
        return (tab_reaches_picture(pg, size) + arrows_after_stepper(pg, size)
                + badge_keeps_panel(pg, size) + prompt_first(pg, size))


def tab_reaches_picture(pg, size):
    """Tab from the first term of each step's text goes on, through the text, to the picture."""
    found = []
    for i in range(steps(pg)):
        jump(pg, i)
        if not pg.locator("#body .term").count():
            continue
        pg.locator("#body .term").first.focus()
        for _ in range(TABS):
            pg.keyboard.press("Tab")
            if pg.evaluate(FOCUS)["inStage"]:
                break
        else:
            found.append(f"{tag(size)} {slug(pg)}: Tab from the panel text does not reach the picture")
    return found


def arrows_after_stepper(pg, size):
    """After a click on the stepper, → goes on to the next step (tried on a step that does not play,
    where → does not play the step instead)."""
    for i in range(1, steps(pg) - 1):
        jump(pg, i)
        if not plays(pg):
            break
    before = slug(pg)
    pg.keyboard.press("ArrowRight")
    pg.wait_for_timeout(150)
    return [f"{tag(size)}: after a click on the stepper, → does not go to the next step"] if slug(pg) == before else []


def badge_keeps_panel(pg, size):
    """Replaying a part from its badge keeps the panel where it was scrolled to, and the focus on
    the badge (tried on the first step with badges whose text scrolls)."""
    for i in range(steps(pg)):
        jump(pg, i)
        badges = pg.locator("#body .runin.seek")
        room = pg.evaluate("() => { const b = document.getElementById('body'); return b.scrollHeight - b.clientHeight; }")
        if not badges.count() or room < 40:
            continue
        pg.evaluate("r => { document.getElementById('body').scrollTop = r; }", room)
        badges.last.focus()
        pg.keyboard.press("Enter")
        pg.wait_for_timeout(250)
        top = pg.evaluate("() => document.getElementById('body').scrollTop")
        if top < 10:
            return [f"{tag(size)} {slug(pg)}: replaying a part from its badge scrolls the panel to the top"]
        if not pg.evaluate("() => document.activeElement.classList.contains('seek')"):
            return [f"{tag(size)} {slug(pg)}: replaying a part from its badge loses the focus"]
        return []
    return [f"{tag(size)}: no step has badges and text that scrolls, to try replaying from a badge"]


def prompt_first(pg, size):
    """On a step waiting to be played, the play prompt is the first thing Tab reaches in the picture."""
    for i in range(steps(pg)):
        jump(pg, i)
        if pg.is_visible("#playprompt"):
            pg.focus("#view")
            pg.keyboard.press("Tab")
            ok = pg.evaluate(FOCUS)["id"] == "playprompt"
            return [] if ok else [f"{tag(size)} {slug(pg)}: Tab from the picture does not reach the play prompt first"]
    return [f"{tag(size)}: no step waits with the play prompt"]


# ---- touch -------------------------------------------------------------------------------------

# every 97th pixel of the picture, as RGB triples
SAMPLE = """() => { const c = document.getElementById('canvas'), d = c.getContext('2d').getImageData(0, 0, c.width, c.height).data, out = [];
  for (let i = 0; i < d.length; i += 4 * 97) out.push(d[i], d[i + 1], d[i + 2]);
  return out; }"""


def changed(a, b):
    """The share of sampled pixels that changed clearly between two samples of the picture."""
    n = len(a) // 3
    return sum(1 for i in range(n) if max(abs(a[3 * i + k] - b[3 * i + k]) for k in range(3)) > 24) / max(1, n)


def drag(pg, x0, y0, x1, y1):
    """A one-finger drag, as a touch screen sends it."""
    cdp = pg.context.new_cdp_session(pg)
    cdp.send("Input.dispatchTouchEvent", {"type": "touchStart", "touchPoints": [{"x": x0, "y": y0}]})
    for k in range(1, 11):
        cdp.send("Input.dispatchTouchEvent", {"type": "touchMove", "touchPoints": [{"x": x0 + (x1 - x0) * k / 10, "y": y0 + (y1 - y0) * k / 10}]})
    cdp.send("Input.dispatchTouchEvent", {"type": "touchEnd", "touchPoints": []})
    pg.wait_for_timeout(150)


def touch(s):
    found = []
    for size in [z for z in s.sizes if z[2]]:
        with s.open(size, step="place") as pg:
            pg.locator("#body .term").first.tap()
            pg.wait_for_timeout(150)
            if not pg.is_visible("#gloss"):
                found.append(f"{tag(size)}: a tap on a term does not open its popup")
            pg.locator("#title").tap()
            pg.wait_for_timeout(400)   # longer than the popup's own delay in closing
            if pg.is_visible("#gloss"):
                found.append(f"{tag(size)}: a tap outside a term's popup does not close it")
            v = pg.locator("#view").bounding_box()
            cx, cy = v["x"] + v["width"] / 2, v["y"] + v["height"] / 2
            pg.touchscreen.tap(cx, cy)
            pg.wait_for_timeout(150)
            if not pg.is_visible("#tip"):
                found.append(f"{tag(size)}: a tap on the picture does not name what is under it")
            before = pg.evaluate(SAMPLE)
            drag(pg, cx, cy, cx - 120, cy - 60)
            if changed(before, pg.evaluate(SAMPLE)) < 0.05:
                found.append(f"{tag(size)}: a drag does not move the view")
    return found


# ---- transitions -------------------------------------------------------------------------------

FLASH = 0.10   # the share of the picture that may change in the first two frames after Play
CAMERA = "() => document.getElementById('scalebar').style.width"   # changes as the camera zooms


def transitions(s):
    found = []
    size = s.sizes[0]
    with s.open(size) as pg:
        # a paused clock, so that the frames looked at are the same however fast the machine is
        pg.clock.install()
        pg.clock.pause_at(int(time.time() * 1000) + 1000)
        for i in range(steps(pg)):
            jump(pg, i)
            if not pg.is_visible("#playprompt"):
                continue
            before, cam = pg.evaluate(SAMPLE), pg.evaluate(CAMERA)
            pg.click("#playprompt")
            pg.clock.run_for(33)   # two frames
            share = changed(before, pg.evaluate(SAMPLE))
            if pg.evaluate(CAMERA) == cam and share > FLASH:
                found.append(f"{tag(size)} {slug(pg)}: Play changes {share:.0%} of the picture at once, not going on from the picture it waited on")
            pg.click("#navplay")   # pause, so that the next step starts from rest
    return found


CHECKS = {"layout": layout, "callouts": callouts, "keyboard": keyboard, "touch": touch, "transitions": transitions}


# ---- the command line ----------------------------------------------------------------------------

def parse_sizes(text):
    """WxH[t],... as (width, height, touch) triples."""
    sizes = []
    for part in text.split(","):
        m = re.fullmatch(r"([1-9]\d*)x([1-9]\d*)(t?)", part)
        if not m:
            raise argparse.ArgumentTypeError(f"not a size such as 1366x768 or 1180x820t: {part!r}")
        sizes.append((int(m[1]), int(m[2]), m[3] == "t"))
    return sizes


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n\n")[0])
    ap.add_argument("page", nargs="?", type=Path, default=DEFAULT_PAGE, help="the built page (default: %(default)s)")
    ap.add_argument("--only", help="comma-separated checks to run: " + ", ".join(CHECKS))
    ap.add_argument("--size", type=parse_sizes, default=SIZES, help="comma-separated sizes, such as 1366x768,1180x820t (default: all supported)")
    args = ap.parse_args(argv)
    if not args.page.is_file():
        ap.error(f"no such page: {args.page}")
    names = args.only.split(",") if args.only else list(CHECKS)
    for n in names:
        if n not in CHECKS:
            ap.error(f"no check named {n!r}")
    found = []
    try:
        with Session(args.page, args.size) as s:
            for n in names:
                if n == "touch" and not any(z[2] for z in args.size):
                    print("touch: skipped, no touch size given")
                    continue
                got = CHECKS[n](s)
                print(f"{n}: {len(got) or 'nothing'} found")
                found += got
            found += s.errors
    except (PageError, PlaywrightError) as e:   # the page did not start, or the browser would not run
        print(f"check.py could not run: {e}", file=sys.stderr)
        return 2
    for f in found:
        print("  " + f)
    return 1 if found else 0


if __name__ == "__main__":
    sys.exit(main())
