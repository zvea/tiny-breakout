# Tutorial glossary

[glossary.json](glossary.json) holds the terms the tutorials define in their popups. Every
tutorial takes its definitions from this one file, so a term reads the same on every page. Each
tutorial is still a single self-contained HTML page: its build copies the terms it uses into the
page.

## Entries

The file is a list of entries, one per sense of a word. A word with two senses has two entries,
and each header names its field in parentheses, such as `cut (layout)`.

| Field | What it is |
|---|---|
| `id` | A stable name for the entry, which pages use to refer to it, such as `slew` or `cut-layout`. It does not change when the header or definition does. |
| `head` | The header shown in the popup, such as `cut (layout)`. |
| `match` | The pattern that finds the term in a page's text, as a JavaScript regular expression: `{"source": ..., "flags": ...}`. It matches the word only, not the qualifier. |
| `def` | The definition. |
| `grid` | Optional. A table shown after the definition, as a list of rows. The first row and the first column are headers. |
| `after` | Optional. Text shown after the table. |
| `reviewed` | `true` once the definition has been reviewed. |
| `sources` | Where the definition was checked, if anywhere: a list of references. |

Only text that belongs to the term is kept here. What a page does with it, such as which step
introduces it or where it is marked, stays with that page.

## The reviewed rule

A page build refuses to use an entry whose `reviewed` is not `true`, and refuses an `id` that is
not in the file. A new entry, or a changed definition, is added with `reviewed: false` and set
to `true` only after review.

## How pages use it

A page lists the entries it uses by `id`, each with the page's own fields. Its build reads this
file, checks every `id` it lists, and writes each entry's `head`, `match` and `def`, and its
`grid` and `after` if it has them, into the page. A page cannot give an entry its own value for
any of these.

- Physical design: [physical-design/page.html](../physical-design/page.html) lists them in its
  `GLOSSARY`, and [physical-design/build.py](../physical-design/build.py) fills them in. The
  page's own fields there are:
  - `from`: the step that introduces the term, which the popup links to;
  - `home`: the term is marked on that step too;
  - `not`: steps where the term is not marked;
  - `again`: steps where a second use is marked too;
  - `each`: the first use of each different word the pattern matches is marked, not only the
    first of all;
  - `inBold`, `inCode`: the term is marked in bold text or in code too;
  - `fig`: a figure drawn in the popup.
