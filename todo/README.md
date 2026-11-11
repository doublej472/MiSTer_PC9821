# TODO - index

`todo/` holds only work we still need to follow up on or verify: a capture owed on the real
machine whose answer would change what a guest observes, a divergence to fix, a re-check, or an
open owner decision. Known limitations with no plan belong in `docs/user/troubleshooting.md`'s "Known issues";
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

## Items

Item numbers are stable public IDs cited as `item NN` across the tree: never renumber or reuse
one. A closed item is DELETED and its number RETIRED (listed below); reword any `item NN`
reference to it first (`tools/check_todo_split.py` fails on a reference to a retired number).

Retired numbers: 1, 2, 3, 4, 5, 6, 7, 8, 9, 11, 12, 14, 15, 16, 17, 19, 20, 25, 29, 30, 32, 33, 34, 37, 39, 40, 41, 44, 45, 46, 48, 49, 50, 51, 52, 54, 55, 56, 57, 58, 60, 61, 62, 63, 64, 65, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 79, 80, 81, 83, 84, 86, 87, 88, 89, 90, 91, 92, 93, 95, 96, 100, 101, 102, 103, 104, 105, 107, 108, 109, 110, 111, 113, 115, 116, 117, 118, 119, 120, 122, 123, 124, 125, 127, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 142, 144, 145, 146, 147, 148, 162, 164, 165, 166, 169, 175, 176, 177, 182, 183, 184, 185, 186, 188, 191, 192

| # | Title | File |
|---|---|---|
| 10 | PIT channel 0: one-byte write retention and the `FFE5` divisor read. | `todo/2-probe-corrections.md` |
| 13 | GDC light-pen (LPEN) read-back. | `todo/2-probe-corrections.md` |
| 18 | OPNA extended read-back: the `0x110` flag mask on Timer A. | `todo/6-audio.md` |
| 21 | `0x0433`: bank 1's interrupt bit. | `todo/6-storage.md` |
| 22 | CRTC horizontal porch split. | `todo/3-capture-pending.md` |
| 23 | GDC status bit 6 (blank): the phase inside the line. | `todo/3-capture-pending.md` |
| 24 | Game port: opposite-direction priority. | `todo/3-capture-pending.md` |
| 26 | GDC SCROLL partition walk past partition 2. | `todo/3-capture-pending.md` |
| 27 | IDE bank-select `0x0432` bits 1-6 and the bank 02-07 task file. | `todo/6-storage.md` |
| 28 | `0x043F` read-back encoding, and the writes that freeze the machine. | `todo/3-capture-pending.md` |
| 31 | `0xE0000` answering nothing. | `todo/3-capture-pending.md` |
| 35 | `0x989x` write behaviour. | `todo/3-capture-pending.md` |
| 36 | `0x6C`: what the latch drives. | `todo/6-video.md` |
| 38 | OPNA ADPCM-B over the data bus. | `todo/3-capture-pending.md` |
| 42 | 16-bit word I/O at byte ports: what XE10T `/AUDIT` and `/AUDIT2` leave open. | `todo/4-reverification.md` |
| 43 | DMA bank ports `0x21/0x23/0x25/0x27`: low-nibble width. | `todo/4-reverification.md` |
| 47 | ADPCM-A rhythm without a driver: is the machine silent? | `todo/4-reverification.md` |
| 53 | z486 reset-state divergences. | `todo/5-owner-decisions.md` |
| 59 | FDC: an empty powered drive's status bytes. | `todo/6-storage.md` |
| 66 | In-game disk-load latency (Touhou 5 dialogue loads). | `todo/6-storage.md` |
| 78 | OPNA `0xA466` DAC-control handling. | `todo/6-audio.md` |
| 82 | Xe10 I/O timing: the EGC file's even read and the `out` side. | `todo/3-capture-pending.md` |
| 85 | GDC SYNC raster residuals. | `todo/6-video.md` |
| 94 | Software-DIP store: the machine's post-POST state. | `todo/3-capture-pending.md` |
| 97 | The `0x0461` window below page 8: a hole. | `todo/3-capture-pending.md` |
| 98 | `0x043B` bit 2: pin the measured polarity. | `todo/3-capture-pending.md` |
| 99 | Machine settings the OSD cannot yet offer. | `todo/3-capture-pending.md` |
| 106 | CD-ROM: what works and what is unverified. | `todo/6-storage.md` |
| 112 | Memory-switch cell `0x79` at a second RAM size. | `todo/3-capture-pending.md` |
| 114 | IRQ15's line: a short low pulse at each tick, not a level a read drops. | `todo/3-capture-pending.md` |
| 121 | IDE bank placement under Linux's `pc98ide` driver. | `todo/3-capture-pending.md` |
| 126 | Graphics GDC arc: radius and rounding. | `todo/3-capture-pending.md` |
| 128 | TXTMODE residuals: CSRR's last two bytes, BDA 0x0716, a CRTC write mid-picture. | `todo/6-video.md` |
| 140 | Licence of the original MiSTer port's surviving code. | `todo/5-owner-decisions.md` |
| 141 | Self-modifying code inside the prefetch window. | `todo/4-reverification.md` |
| 143 | Same-row write follow-on in the SDRAM controller. | `todo/6-memory.md` |
| 149 | Graphics GDC WRITE pacing. | `todo/5-owner-decisions.md` |
| 150 | Sync `sys/` with Template_MiSTer. | `todo/6-audio.md` |
| 151 | GRCG store period. | `todo/6-video.md` |
| 152 | GVRAM plain read period. | `todo/4-reverification.md` |
| 153 | EGC read pace. | `todo/6-video.md` |
| 154 | XE10T unified timing capture. | `todo/3-capture-pending.md` |
| 155 | OPNA BUSY, write loss and the 0x188 read details. | `todo/6-audio.md` |
| 156 | IRQ entry latency. | `todo/3-capture-pending.md` |
| 157 | 16-bit I/O on the faithful profile. | `todo/3-capture-pending.md` |
| 158 | probe2 /WIPE W5 fencepost. | `todo/2-probe-corrections.md` |
| 159 | ioprobe_decode against the current RTL. | `todo/2-probe-corrections.md` |
| 160 | CPU outlier instructions. | `todo/5-owner-decisions.md` |
| 161 | A DMA byte behind a posted PEGC store. | `todo/6-memory.md` |
| 163 | FDC timing is not tied to the disk's rotation. | `todo/6-storage.md` |
| 167 | A second hard disk on IDE bank 1. | `todo/3-capture-pending.md` |
| 168 | CPUSUITE on the Xe10: the CPU behaviours not adopted. | `todo/3-capture-pending.md` |
| 170 | What a software reboot resets on the Xe10. | `todo/3-capture-pending.md` |
| 171 | CD-DA ring depth against slow SD-card reads. | `todo/6-storage.md` |
| 172 | The BIOS SETUP items on the machine. | `todo/3-capture-pending.md` |
| 173 | The UART-mode exit (0xFF) is not ACKed: confirm it on an MPU-PC98II. | `todo/6-audio.md` |
| 174 | MIDI wire capture of the MPU card. | `todo/6-audio.md` |
| 178 | Floppy copy-protection fidelity. | `todo/6-storage.md` |
| 179 | Floppy media and interface details. | `todo/6-storage.md` |
| 180 | Port 0xCC bit 4 (the drive's RDY) in the 640K interface mode. | `todo/3-capture-pending.md` |
| 181 | The ITF's saved port table across a reset on the Xe10. | `todo/3-capture-pending.md` |
| 187 | YM2608 register read map: 0x10-0x1F, 0x22, 0x29 and 0xB4-0xB7 read FF. | `todo/6-audio.md` |
| 189 | CG window even page for the uncaptured classes. | `todo/6-video.md` |
| 190 | FDC VFO timer: a masked expiry is held and raised when TMSK is set. | `todo/6-storage.md` |
| 193 | Metajo SP from its own FreeDOS(98) hard-disk image stops after the R-FORCE logo. | `todo/4-reverification.md` |

## Adding to the list

1. Take the next free number: one more than the highest number in the item table or the
   retired list.
2. Put the item in its theme file as `NN. **Title.** **STATUS TAG.** What is needed. **Done
   when:** what closes it.` - a few lines, no session history.
3. Add a row to the item table above (and to the section map if you made a new file).
4. Run `python3 tools/check_todo_split.py`.

<!-- TODO-SPLIT:INDEX:END -->
