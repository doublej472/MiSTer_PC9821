# TODO - open work on the PC-9821 core

The live list of work we still need to follow up on or verify, one file per theme under
[`todo/`](todo/). This file is the INDEX; [`todo/README.md`](todo/README.md) carries the
status tags and the item -> file -> title table. Known limitations are in `README.md`; raw
machine captures live in `docs/probes/`.

## Sections

| # | Section | File |
|---|---|---|
| 2 | Probe re-runs | `todo/2-probe-corrections.md` |
| 3 | Capture-pending hardware questions | `todo/3-capture-pending.md` |
| 4 | Re-verification items | `todo/4-reverification.md` |
| 5 | Owner decisions | `todo/5-owner-decisions.md` |
| 6 | Audio: OPNA/SSG/ADPCM | `todo/6-audio.md` |
| 6 | Video: display, GDC/CRTC raster | `todo/6-video.md` |
| 6 | Storage: IDE/ATA, FDC, CD-ROM | `todo/6-storage.md` |
| 6 | Memory: the SDRAM controller and its bridges | `todo/6-memory.md` |

## Finding an item

Item numbers are stable public IDs cited across the tree as `item NN`; never renumber
them. Find item NN in `todo/README.md`'s item table, or:

```
grep -rn '^NN\. \*\*' todo/
```

A closed item is deleted and its number retired (never reused); the retired numbers are
listed in `todo/README.md`, and `python3 tools/check_todo_split.py` fails on any in-tree
`item NN` reference to one.
