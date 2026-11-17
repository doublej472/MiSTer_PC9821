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

Retired numbers: 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 14, 15, 16, 17, 19, 20, 25, 29, 30, 32, 33, 34, 37, 39, 40, 41, 44, 45, 46, 47, 48, 49, 50, 51, 52, 54, 55, 56, 57, 58, 60, 61, 62, 63, 64, 65, 67, 68, 69, 70, 71, 72, 73, 74, 75, 76, 77, 79, 80, 81, 83, 84, 86, 87, 88, 89, 90, 91, 92, 93, 95, 96, 100, 101, 102, 103, 104, 105, 107, 108, 109, 110, 111, 113, 115, 116, 117, 118, 119, 120, 122, 123, 124, 125, 126, 127, 129, 130, 131, 132, 133, 134, 135, 136, 137, 138, 139, 142, 144, 145, 146, 147, 148, 152, 157, 159, 162, 164, 165, 166, 169, 175, 176, 177, 182, 183, 184, 185, 186, 188, 189, 191, 192, 195, 198, 209, 224, 241

| # | Title | File |
|---|---|---|
| 13 | GDC light-pen (LPEN) read-back. | `todo/2-probe-corrections.md` |
| 18 | OPNA extended read-back: `0x18E` with 0x18C = 0F. | `todo/6-audio.md` |
| 21 | `0x0433`: bank 1's interrupt bit. | `todo/6-storage.md` |
| 22 | CRTC horizontal porch split. | `todo/3-capture-pending.md` |
| 23 | GDC status bit 6 (blank): the window against the active dots. | `todo/3-capture-pending.md` |
| 24 | Game port: opposite-direction priority. | `todo/3-capture-pending.md` |
| 26 | GDC SCROLL partition walk past partition 2. | `todo/3-capture-pending.md` |
| 27 | IDE bank-select `0x0432`: what the measured rows leave open. | `todo/6-storage.md` |
| 28 | `0x043F` read-back encoding, and the writes that freeze the machine. | `todo/3-capture-pending.md` |
| 31 | `0xE0000` answering nothing. | `todo/3-capture-pending.md` |
| 35 | `0x989x`: bits 0-2 of the latch. | `todo/3-capture-pending.md` |
| 36 | `0x6C`: what the latch drives. | `todo/6-video.md` |
| 38 | OPNA ADPCM-B over the data bus: the read-back and BRDY timing. | `todo/3-capture-pending.md` |
| 42 | 16-bit word I/O at byte ports: what XE10T `/AUDIT` and `/AUDIT2` leave open. | `todo/4-reverification.md` |
| 43 | DMA bank ports `0x21/0x23/0x25/0x27`: low-nibble width. | `todo/4-reverification.md` |
| 53 | z486 reset-state divergences. | `todo/5-owner-decisions.md` |
| 59 | FDC: an empty powered drive's status bytes. | `todo/6-storage.md` |
| 66 | In-game disk-load latency (Touhou 5 dialogue loads). | `todo/6-storage.md` |
| 78 | PC-9801-86 PCM: the `0xA46A` write guard and the Policenauts IRQ re-assert. | `todo/6-audio.md` |
| 82 | Xe10 I/O timing: the EGC file's even read and the `out` side. | `todo/3-capture-pending.md` |
| 85 | GDC SYNC raster residuals. | `todo/6-video.md` |
| 94 | Software-DIP store: the machine's post-POST state. | `todo/3-capture-pending.md` |
| 97 | The `0x0461` window above page 9. | `todo/3-capture-pending.md` |
| 98 | `0x043B` bit 2: pin the measured polarity; bit 3 when unwritten. | `todo/3-capture-pending.md` |
| 99 | Machine settings the OSD cannot yet offer. | `todo/3-capture-pending.md` |
| 106 | CD-ROM: what works and what is unverified. | `todo/6-storage.md` |
| 112 | Memory-switch cell `0x79` at a second RAM size. | `todo/3-capture-pending.md` |
| 114 | IRQ15: the tick at a 0x128 write. | `todo/3-capture-pending.md` |
| 121 | IDE bank placement under Linux's `pc98ide` driver. | `todo/3-capture-pending.md` |
| 128 | TXTMODE residuals: CSRR's last two bytes, BDA 0x0716, a CRTC write mid-picture. | `todo/6-video.md` |
| 140 | Licence of the original MiSTer port's surviving code. | `todo/5-owner-decisions.md` |
| 141 | Self-modifying code inside the prefetch window. | `todo/4-reverification.md` |
| 143 | Same-row write follow-on in the SDRAM controller. | `todo/6-memory.md` |
| 149 | Graphics GDC WRITE pacing. | `todo/5-owner-decisions.md` |
| 150 | Sync `sys/` with Template_MiSTer. | `todo/4-reverification.md` |
| 151 | GVRAM store period: the residuals of the Xe10 table. | `todo/6-video.md` |
| 153 | EGC read pace. | `todo/5-owner-decisions.md` |
| 154 | XE10T unified timing capture. | `todo/3-capture-pending.md` |
| 155 | OPNA BUSY, write loss and the 0x188 read details. | `todo/6-audio.md` |
| 156 | IRQ entry latency. | `todo/3-capture-pending.md` |
| 158 | probe2 /WIPE W5 fencepost. | `todo/2-probe-corrections.md` |
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
| 187 | YM2608 register read map: the lost-interrupt state of the kit-1 YM29 run. | `todo/6-audio.md` |
| 190 | FDC VFO timer: the held masked expiry on a card. | `todo/6-storage.md` |
| 193 | Metajo SP from its own FreeDOS(98) hard-disk image stops after the R-FORCE logo. | `todo/4-reverification.md` |
| 194 | Ready change on a floppy insert with the motor stopped. | `todo/3-capture-pending.md` |
| 196 | `cpu_run` fans out raw into the CPU request gating. | `todo/6-memory.md` |
| 197 | Xe10 class table: the aperture's own read class. | `todo/6-video.md` |
| 199 | PEGC packed store: two states. | `todo/3-capture-pending.md` |
| 200 | MPU-PC98 clock-to-host: where the 4-phase dither stands at each 0xE7 row. | `todo/6-audio.md` |
| 201 | uPD4990A TIME SET: the folds no capture row measures. | `todo/3-capture-pending.md` |
| 202 | GDCFIG's last graphics character: plane B only on the Xe10. | `todo/6-video.md` |
| 203 | A 77-cylinder 15x512 2HD floppy title stays black on the core. | `todo/6-storage.md` |
| 204 | FDC write-side and FORMAT rows. | `todo/3-capture-pending.md` |
| 205 | IRQ10 (the 640 KB FDC interrupt): the masked request. | `todo/3-capture-pending.md` |
| 206 | The drive-letter search time behind Rusty's cut voice. | `todo/3-capture-pending.md` |
| 207 | Graphics GDC PITCH and DGD at 5 MHz. | `todo/3-capture-pending.md` |
| 208 | EXECUTE DEVICE DIAGNOSTIC (0x90): the interrupt. | `todo/3-capture-pending.md` |
| 210 | XE10Z on the current core. | `todo/4-reverification.md` |
| 211 | YM2608 0x29 bits 4:2 and the ADPCM-B interrupts. | `todo/6-audio.md` |
| 212 | ATAPI MODE SELECT with no data-out phase. | `todo/6-storage.md` |
| 213 | FORMAT on a D88 floppy image. | `todo/6-storage.md` |
| 214 | ATA aborted commands: the status of a generic unsupported command. | `todo/6-storage.md` |
| 215 | ATAPI READ across a disc change: the sense. | `todo/6-storage.md` |
| 216 | A 2DD floppy title whose IPL retries forever. | `todo/6-storage.md` |
| 217 | MGL slot indices in the user docs. | `todo/6-storage.md` |
| 218 | A CD title freezes on its first intro text. | `todo/4-reverification.md` |
| 219 | Three titles take no input at their first menu. | `todo/4-reverification.md` |
| 220 | Partial titles from the hard-disk smoke run not in the compatibility list. | `todo/4-reverification.md` |
| 221 | 31 kHz on an analog VGA monitor. | `todo/4-reverification.md` |
| 222 | The Japanese-keyboard Known issue and the Main_MiSTer release. | `todo/4-reverification.md` |
| 223 | The release game sample as a tracked list. | `todo/4-reverification.md` |
| 225 | INTA bridge: the taken flag follows the masked strobe. | `todo/6-memory.md` |
| 226 | Tool leftovers: quartus_gui, wait_build, the MPU decoder. | `todo/4-reverification.md` |
| 227 | CRTC: the 31 kHz text shift and the two-byte simple-graph cell. | `todo/6-video.md` |
| 228 | Xe10 I/O timing below about 47 MHz clk_sys. | `todo/6-memory.md` |
| 229 | mediumoc: CL3 at 100 MHz unconfirmed on hardware. | `todo/6-memory.md` |
| 230 | Keyboard receive FIFO overrun: which byte is lost. | `todo/5-owner-decisions.md` |
| 231 | Published-tree hygiene: attributions, internal labels and a check. | `todo/5-owner-decisions.md` |
| 232 | Trade rows still Raised: a disposition for each. | `todo/5-owner-decisions.md` |
| 233 | z486 microcode and table data files: their licence. | `todo/5-owner-decisions.md` |
| 234 | NOTICE part 8 and the GPL-2 text. | `todo/5-owner-decisions.md` |
| 235 | Build identification in the OSD. | `todo/5-owner-decisions.md` |
| 236 | `mister_load.sh` and an RBF with no timing record. | `todo/5-owner-decisions.md` |
| 237 | Release notes for the next release. | `todo/5-owner-decisions.md` |
| 238 | PC-9801-86 PCM: a frame spliced by a FIFO overflow. | `todo/5-owner-decisions.md` |
| 239 | The throttle tiers' runtime runs in the gates. | `todo/4-reverification.md` |
| 240 | Benches and RTL files with no recorded mutant. | `todo/4-reverification.md` |
| 242 | The census clock proc in a real Quartus STA session. | `todo/4-reverification.md` |
| 243 | Speak Board (Idol Japan) as a selectable sound board. | `todo/6-audio.md` |
| 244 | PIC OCW2 0x80: rotate in auto-EOI mode. | `todo/3-capture-pending.md` |
| 245 | ATAPI READ CD (0xBE) and READ CD MSF (0xB9). | `todo/6-storage.md` |
| 246 | FDC WRITE with terminal count: ST0 HD. | `todo/3-capture-pending.md` |
| 247 | ATAPI READ CAPACITY: count or last LBA, and with no medium. | `todo/3-capture-pending.md` |
| 248 | PIT: a two-byte reload while the counter runs. | `todo/3-capture-pending.md` |
| 249 | Keyboard 0x9C: typematic delay and rate. | `todo/3-capture-pending.md` |
| 250 | Keyboard link byte time. | `todo/3-capture-pending.md` |
| 251 | The PCMKIT capture run on the Xe10. | `todo/3-capture-pending.md` |
| 252 | IRQ0 withdrawn on an unmasked OUT0 fall. | `todo/3-capture-pending.md` |
| 253 | ATA READ SECTORS: the status while BSY, and a command written while BSY. | `todo/3-capture-pending.md` |
| 254 | Mouse port 0x7FDB with Port B an input. | `todo/3-capture-pending.md` |
| 255 | MPU status port: the idle byte by card model. | `todo/6-audio.md` |
| 256 | `tb_pc9821_gvram_latency`: a ceiling or the machine's pace. | `todo/5-owner-decisions.md` |
| 257 | Benches that pin exact latency and handshake laws. | `todo/5-owner-decisions.md` |
| 258 | Keyboard 0x9D: the NUM lamp bit. | `todo/5-owner-decisions.md` |
| 259 | The keyboard's IRQ1 re-poke dip through the real PIC. | `todo/4-reverification.md` |
| 260 | EGC shifter rows that rest on NP2kai alone. | `todo/6-video.md` |
| 261 | Graphics GDC drawing cases no capture covers. | `todo/3-capture-pending.md` |
| 262 | ATA answers taken from a spec or a reading, not the machine. | `todo/6-storage.md` |
| 263 | FDC: READ DATA's C after RECALIBRATE, and 0x04BE bit 4 against the 640K DIP. | `todo/3-capture-pending.md` |
| 264 | ATA: the status while SRST is still held after a drained block. | `todo/6-storage.md` |
| 265 | ATAPI READ TOC with more than 127 tracks. | `todo/6-storage.md` |
| 266 | ROM loader: a short pack download. | `todo/5-owner-decisions.md` |
| 267 | CRTC state when cpu_run falls and rises within one frame. | `todo/4-reverification.md` |
| 268 | IRQ12: back-to-back bubbles against WD_FILTER. | `todo/4-reverification.md` |
| 269 | Two request-path cones no fit has timed. | `todo/4-reverification.md` |
| 270 | Bench policy: reference copies, mutants and internal pins. | `todo/5-owner-decisions.md` |
| 271 | OPNA: the select latch after a 0xA460 bit-0 drop. | `todo/6-audio.md` |
| 272 | PIC OCW2: the rotate-in-auto-EOI command with nonzero L bits. | `todo/4-reverification.md` |
| 273 | `tb_pc9821_cg_window`: the reset-persistence check and two unconnected inputs. | `todo/4-reverification.md` |
| 274 | ATA IDENTIFY words 57-58 for an image over 128 GiB. | `todo/6-storage.md` |

## Adding to the list

1. Take the next free number: one more than the highest number in the item table or the
   retired list.
2. Put the item in its theme file as `NN. **Title.** **STATUS TAG.** What is needed. **Done
   when:** what closes it.` - a few lines, no session history.
3. Add a row to the item table above (and to the section map if you made a new file).
4. Run `python3 tools/check_todo_split.py`.

<!-- TODO-SPLIT:INDEX:END -->
