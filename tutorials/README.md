# Tutorials

Explanations of how this chip is made and checked, each a single self-contained HTML page. Read
them on the [project's site](https://zvea.github.io/tiny-breakout/tutorials/); on GitHub the
files here show as source, and in a clone they open in any browser.

| Tutorial | What it covers |
|---|---|
| [ASIC toolchain](https://zvea.github.io/tiny-breakout/tutorials/asic-toolchain.html) ([source](asic-toolchain.html)) | The flow from RTL to GDS as Tiny Tapeout runs it, step by step: which tool does each step, the forms the design takes between them, and how the design is verified. Every tool, format and term has a short definition on hover and the full one on click. |

The site ([.github/workflows/site.yaml](../.github/workflows/site.yaml)) publishes this folder's
pages next to Tiny Tapeout's 3D viewer of the latest GDS from a gds run on main that passed. A
tutorial describes the flow as it was when written, which its page states; it isn't updated with
every change to the chip.
