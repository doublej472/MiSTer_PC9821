# TODO - index

`todo/` holds only work we still need to follow up on or verify: a capture owed on the real
machine whose answer would change what a guest observes, a divergence to fix, a re-check, or an
open owner decision. Known limitations with no plan belong in `README.md`'s "Known issues";
latency/area trades in `docs/trade-candidates.md`; standing rules in `AGENTS.md`.
A finished item is deleted, not marked done.

## Status tags

| Tag | Meaning |
|---|---|
| **VERIFIED (HW)** | A capture in `docs/probes/` measures it and the RTL disagrees. Ready to implement with a fail-first bench whose expected value comes from the capture. |
| **CAPTURE-PENDING** | No valid measurement exists; a named probe or experiment must run on the machine first. |
| **NEEDS RE-VERIFICATION** | A claim rests on one sample or a suspect derivation and must be re-checked before it is relied on. |
| **UNVERIFIED (INFERRED)** | Implemented from a reference reading only; the item says what would confirm it. |
| **DECISION (OWNER)** | Blocked on a maintainer decision, not on work. |
| **WORK** | A concrete task with no hardware blocker. |

Evidence rules and the gates for any RTL change are in `AGENTS.md`.

---

<!-- TODO-SPLIT:INDEX:BEGIN -->

The repo-root [`TODO.md`](../TODO.md) is the short index.

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

## Items

Item numbers are stable public IDs cited as `item NN` across the tree: never renumber or reuse
one. A closed item is DELETED and its number RETIRED (listed below); reword any `item NN`
reference to it first (`tools/check_todo_split.py` fails on a reference to a retired number).

Retired numbers: 1, 2, 4, 5, 6, 7, 8, 9, 11, 12, 14, 16, 19, 20, 25, 29, 30, 32, 33, 39, 40, 41, 44, 45, 46, 48, 49, 50, 51, 52, 54, 55, 56, 57, 58, 60, 61, 62, 63, 64, 65, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 79, 80, 81, 83, 84, 86, 87, 88, 89, 90, 91, 92, 93, 95, 96, 100, 101, 102, 103, 104, 105, 107, 108, 109, 111, 113, 115, 116, 117, 118, 119, 120, 122, 123, 124, 125, 127, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 142, 144, 145, 147

| # | Title | File |
|---|---|---|
| 3 | `0x9A8` latch width. | `todo/3-capture-pending.md` |
| 10 | PIT channel 0: one-byte write retention and the `FFE5` divisor read. | `todo/2-probe-corrections.md` |
| 13 | GDC light-pen (LPEN) read-back. | `todo/2-probe-corrections.md` |
| 15 | Analog palette registers: index width and read-back. | `todo/3-capture-pending.md` |
| 17 | GDC `mode1` (`0x68`) read model. | `todo/3-capture-pending.md` |
| 18 | OPNA extended read-back: `0x18A`/`0x18E`/`0x18C`. | `todo/3-capture-pending.md` |
| 21 | `0x0433`: IDE connect flag or IRQ-pending? | `todo/3-capture-pending.md` |
| 22 | CRTC horizontal porch split. | `todo/3-capture-pending.md` |
| 23 | GDC status bit 6 (blank): per-line on the machine, per-frame on the core. | `todo/3-capture-pending.md` |
| 24 | Game port: opposite-direction priority. | `todo/3-capture-pending.md` |
| 26 | GDC SCROLL partition walk past partition 2. | `todo/3-capture-pending.md` |
| 27 | IDE bank-select `0x0432` bit 7 and `0x074E` with the slave selected. | `todo/3-capture-pending.md` |
| 28 | `0x043F` read-back encoding. | `todo/3-capture-pending.md` |
| 31 | `0xE0000` answering nothing. | `todo/3-capture-pending.md` |
| 34 | `0xDC000-0xDFFFF` with the IDE work-RAM gate on. | `todo/3-capture-pending.md` |
| 35 | `0x989x` write behaviour. | `todo/3-capture-pending.md` |
| 36 | `0x6C` and the `0x60-0x6F` decode. | `todo/3-capture-pending.md` |
| 37 | CG window even offsets. | `todo/3-capture-pending.md` |
| 38 | OPNA ADPCM-B over the data bus. | `todo/3-capture-pending.md` |
| 42 | `0x7C` 16-bit word `IN`. | `todo/4-reverification.md` |
| 43 | DMA bank ports `0x21/0x23/0x25/0x27`: low-nibble width. | `todo/4-reverification.md` |
| 47 | ADPCM-A rhythm sounds on the core without a driver; the machine's is silent. | `todo/4-reverification.md` |
| 53 | z486 reset-state divergences. | `todo/5-owner-decisions.md` |
| 59 | FDC: re-capture with both drives powered. | `todo/6-storage.md` |
| 66 | In-game disk-load latency (Touhou 5 dialogue loads). | `todo/6-storage.md` |
| 78 | OPNA `0xA466` DAC-control handling. | `todo/6-audio.md` |
| 82 | I/O access cost per port class: machine bus time or the shortest stall. | `todo/5-owner-decisions.md` |
| 85 | GDC SYNC raster residuals. | `todo/6-video.md` |
| 94 | Software-DIP store: the machine's post-POST state. | `todo/3-capture-pending.md` |
| 97 | The `0x0461` window's page 0/1: alias or hole. | `todo/3-capture-pending.md` |
| 98 | `0x043B` bit 2: the 15-16 MiB system space's polarity. | `todo/3-capture-pending.md` |
| 99 | Machine settings the OSD cannot yet offer. | `todo/3-capture-pending.md` |
| 106 | CD-ROM: what works and what is unverified. | `todo/6-storage.md` |
| 110 | The DIP store's write-side parity bits. | `todo/3-capture-pending.md` |
| 112 | Memory-switch cell `0x79` at a second RAM size. | `todo/3-capture-pending.md` |
| 114 | Masked-request withdraw on the acking access: IRQ15. | `todo/3-capture-pending.md` |
| 121 | IDE bank placement under Linux's `pc98ide` driver. | `todo/3-capture-pending.md` |
| 126 | Graphics GDC arc: radius and rounding. | `todo/3-capture-pending.md` |
| 128 | Text row geometry: 20/30 lines, partitions, smooth scroll. | `todo/3-capture-pending.md` |
| 140 | Licence of the original MiSTer port's surviving code. | `todo/5-owner-decisions.md` |
| 141 | Self-modifying code inside the prefetch window: clock-ratio dependence. | `todo/4-reverification.md` |
| 143 | Same-row write follow-on in the SDRAM controller. | `todo/6-memory.md` |
| 146 | Review NOTICE's copyright line. | `todo/5-owner-decisions.md` |
| 148 | DMA into an EMS page or the PEGC bank goes to the SDRAM hole. | `todo/6-memory.md` |
| 149 | Graphics GDC WRITE pacing. | `todo/5-owner-decisions.md` |
| 150 | Sync `sys/` with Template_MiSTer. | `todo/6-audio.md` |

## Adding to the list

1. Take the next free number: one more than the highest number in the item table or the
   retired list.
2. Put the item in its theme file as `NN. **Title.** **STATUS TAG.** What is needed. **Done
   when:** what closes it.` - a few lines, no session history.
3. Add a row to the item table above (and to the section map if you made a new file).
4. Run `python3 tools/check_todo_split.py`.

<!-- TODO-SPLIT:INDEX:END -->
