"""Tests for check.py: each check passes the built page, and catches a fault planted in a copy of it.

Run from the repo root: .venv/bin/pytest tutorials/physical-design -n 4
"""
from pathlib import Path

import pytest

import check

PAGE = Path(__file__).resolve().parent.parent / "physical-design.html"
LAPTOP = [(1366, 768, False)]
TABLET = [(1180, 820, True)]
SMALL_TABLET = [(1024, 768, True)]


def variant(tmp_path, *subs):
    """A copy of the built page with each (old, new) substitution made; old must occur once."""
    html = PAGE.read_text(encoding="utf-8")
    for old, new in subs:
        assert html.count(old) == 1, f"not exactly once in the page: {old!r}"
        html = html.replace(old, new)
    path = tmp_path / "physical-design.html"
    path.write_text(html, encoding="utf-8")
    return path


def css(rule):
    """The substitution that adds a CSS rule at the end of the page's styles."""
    return ("</style>", rule + "</style>")


def run(fn, page, sizes=LAPTOP):
    with check.Session(page, sizes) as s:
        return fn(s), s.errors


def has(found, text):
    return any(text in f for f in found)


@pytest.mark.parametrize("name", check.CHECKS)
def test_the_built_page_passes(name):
    found, errors = run(check.CHECKS[name], PAGE, TABLET if name == "touch" else LAPTOP)
    assert found == [] and errors == []


# ---- script errors -------------------------------------------------------------------------------

def test_script_errors_are_reported(tmp_path):
    page = variant(tmp_path, ("</body>", '<script>window.addEventListener("load", function () { throw new Error("planted"); });</script></body>'))
    _, errors = run(check.layout, page)
    assert has(errors, "planted")


def test_a_page_that_does_not_start_is_reported_with_its_error(tmp_path):
    page = variant(tmp_path, ("function start(D) {", 'function start(D) { throw new Error("planted");'))
    with pytest.raises(check.PageError, match="planted"):
        run(check.layout, page)


# ---- layout --------------------------------------------------------------------------------------

def test_layout_finds_the_legend_over_the_zoom_buttons(tmp_path):
    found, _ = run(check.layout, variant(tmp_path, css(".legend { left: 0 !important; }")))
    assert has(found, "legend overlaps the zoom buttons")


def test_layout_finds_the_play_bar_over_the_scale(tmp_path):
    found, _ = run(check.layout, variant(tmp_path, css(".readout { position: absolute; left: 0; }")))
    assert has(found, "play bar overlaps the scale")


def test_layout_finds_the_prompt_over_the_legend(tmp_path):
    found, _ = run(check.layout, variant(tmp_path, css(".playprompt { top: 22px !important; transform: translateX(-50%) !important; }")))
    assert has(found, "play prompt overlaps the legend")


def test_layout_finds_the_prompt_over_the_play_bar(tmp_path):
    found, _ = run(check.layout, variant(tmp_path, css(".playprompt { top: auto !important; bottom: 10px; left: 75% !important; transform: none !important; }")))
    assert has(found, "play prompt overlaps the play bar")


def test_layout_finds_the_page_scrolling_sideways(tmp_path):
    found, _ = run(check.layout, variant(tmp_path, css("body { min-width: 3000px; }")))
    assert has(found, "scrolls sideways")


def test_layout_finds_a_clipped_step_name(tmp_path):
    found, _ = run(check.layout, variant(tmp_path, css(".seg.now .long { max-width: 20px !important; overflow: hidden !important; }")))
    assert has(found, "step name clipped")


def test_layout_finds_a_step_name_running_into_the_next(tmp_path):
    found, _ = run(check.layout, variant(tmp_path, css(".track.numbered .seg .long { visibility: visible !important; }")), SMALL_TABLET)
    assert has(found, "runs into")


# ---- callouts ------------------------------------------------------------------------------------

def test_callouts_find_those_left_out(tmp_path):
    found, _ = run(check.callouts, variant(tmp_path, ("var placed = [], EDGE = 8;", "var placed = [], EDGE = 4000;")))
    assert has(found, "no place for callout")


def test_callouts_find_overlaps(tmp_path):
    found, _ = run(check.callouts, variant(tmp_path, ("    var bx = best[0], by = best[1];\n", "    var bx = 100, by = 100;\n")))
    assert has(found, "overlaps callout")


def test_callouts_find_one_outside_the_view(tmp_path):
    found, _ = run(check.callouts, variant(tmp_path, ("    var bx = best[0], by = best[1];\n", "    var bx = -50, by = best[1];\n")))
    assert has(found, "outside the view")


def test_callouts_find_one_over_the_legend(tmp_path):
    found, _ = run(check.callouts, variant(tmp_path, ("    var bx = best[0], by = best[1];\n", "    var bx = 60, by = 16;\n")))
    assert has(found, "overlaps the legend")


def test_callouts_find_the_close_up_missing(tmp_path):
    found, _ = run(check.callouts, variant(tmp_path, ("    if (rowPx > 30) return null;", "    return null;")))
    assert has(found, "close-up not shown")


# ---- keyboard ------------------------------------------------------------------------------------

def test_keyboard_finds_a_tab_trap(tmp_path):
    found, _ = run(check.keyboard, variant(tmp_path, ("if (e.shiftKey) t.focus(); else focusAfter(t);", "t.focus();")))
    assert has(found, "Tab from the panel text does not reach the picture")


def test_keyboard_finds_tab_dropping_the_focus(tmp_path):
    found, _ = run(check.keyboard, variant(tmp_path, ("if (e.shiftKey) t.focus(); else focusAfter(t);", "if (e.shiftKey) t.focus(); else t.blur();")))
    assert has(found, "Tab from the panel text does not reach the picture")


def test_keyboard_finds_the_stepper_keeping_the_arrow_keys(tmp_path):
    found, _ = run(check.keyboard, variant(tmp_path, ("goTo(i, { fresh: true }); if (e.detail > 0) b.blur();", "goTo(i, { fresh: true });")))
    assert has(found, "after a click on the stepper")


def test_keyboard_finds_a_replay_resetting_the_panel(tmp_path):
    found, _ = run(check.keyboard, variant(tmp_path, ("target = k; if (changed) updatePanel();", "target = k; updatePanel();")))
    assert has(found, "replaying a part from its badge")


PROMPT = ('      <button type="button" class="playprompt" id="playprompt" hidden><svg viewBox="0 0 16 16" aria-hidden="true">'
          '<path d="M5 3.5v9l7.5-4.5z" fill="currentColor"/></svg>Play the animation <kbd>→</kbd></button>\n')


def test_keyboard_finds_the_prompt_out_of_order(tmp_path):
    legend = '      <ul class="legend" id="legend" aria-label="Legend"></ul>\n'
    found, _ = run(check.keyboard, variant(tmp_path, (PROMPT, ""), (legend, legend + PROMPT)))
    assert has(found, "does not reach the play prompt first")


# ---- touch ---------------------------------------------------------------------------------------

def test_touch_finds_a_popup_that_does_not_open(tmp_path):
    found, _ = run(check.touch, variant(tmp_path, css(".gloss { visibility: hidden !important; }")), TABLET)
    assert has(found, "tap on a term")


def test_touch_finds_a_popup_that_does_not_close(tmp_path):
    page = variant(tmp_path,
                   ('document.addEventListener("click", function (e) { if (!e.target.closest(".term, .gloss")) hideGloss(); });', ""),
                   ('bodyEl.addEventListener("focusout", function () { glossTimer = setTimeout(function () { if (!gloss.contains(document.activeElement)) hideGloss(); }, 200); });', ""))
    found, _ = run(check.touch, page, TABLET)
    assert has(found, "does not close it")


def test_touch_finds_a_tap_that_names_nothing(tmp_path):
    found, _ = run(check.touch, variant(tmp_path, ('if (tapStart && e.type === "pointerup"', 'if (false && tapStart && e.type === "pointerup"')), TABLET)
    assert has(found, "tap on the picture")


def test_touch_finds_a_drag_that_does_not_pan(tmp_path):
    found, _ = run(check.touch, variant(tmp_path, ("cam.x -= (e.clientX - p.x) / cam.s; cam.y += (e.clientY - p.y) / cam.s; clampCam();", "")), TABLET)
    assert has(found, "drag")


# ---- transitions ---------------------------------------------------------------------------------

def test_transitions_find_a_flash_of_the_step_before(tmp_path):
    found, _ = run(check.transitions, variant(tmp_path, ("var settled = !carried() && pos > target - 1;", "var settled = !anim && pos > target - 1;")))
    assert has(found, "Play changes")


# ---- the command line ----------------------------------------------------------------------------

@pytest.mark.parametrize("text", ["1366x768x", "1366x768tt", "big", "0x768"])
def test_a_bad_size_is_refused(text, capsys):
    with pytest.raises(SystemExit) as e:
        check.main(["--size", text])
    assert e.value.code == 2 and "size" in capsys.readouterr().err


def test_a_missing_page_is_refused(tmp_path, capsys):
    with pytest.raises(SystemExit) as e:
        check.main([str(tmp_path / "nothing.html")])
    assert e.value.code == 2 and "no such page" in capsys.readouterr().err
