# Tutorials

Explanations of how this chip is made and checked, each a single self-contained HTML page. Read
them on the [project's site](https://zvea.github.io/tiny-breakout/tutorials/); on GitHub the
files here show as source, and in a clone they open in any browser.

| Tutorial | What it covers |
|---|---|
| [ASIC toolchain](https://zvea.github.io/tiny-breakout/tutorials/asic-toolchain.html) | The flow from RTL to GDS as Tiny Tapeout runs it, step by step: which tool does each step, the forms the design takes between them, and how the design is verified. Every tool, format and term has a short definition on hover and the full one on click. |
| [Physical design](https://zvea.github.io/tiny-breakout/tutorials/physical-design.html) | How the flow places and routes this chip, from an empty die to the finished GDS: placement, legalisation, the clock tree, routing, timing, IR drop and the layers of the GDS, each animated. Its sources, and a record of the run it shows, are in [physical-design/](physical-design/README.md). |

Each tutorial shows the chip as it was when written, and says when; they aren't updated with
every change.
