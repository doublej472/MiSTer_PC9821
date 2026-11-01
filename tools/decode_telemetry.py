#!/usr/bin/env python3
"""Decode a PC-9821 core watchdog telemetry capture.

The core emits one record per stall over /dev/ttyS1 at 115200. The stall record is
ONE line of 351 characters, ended by a single LF (a record ended CR LF would arrive as
two newlines: a serial tty's ICRNL maps CR to LF on the way into a capture, which shows
up as a blank line between records). Several field names are counter-intuitive, so this decoder exists to make
misreading harder: N is vid_lit_cnt (a video counter), not an unmapped-port
count, and the unmapped read/write counts are not in the message at all.

A PRF record follows the stall record: one line of 256 bytes, the interval itself and the
per-interval subsystem counters (the CPU's memory-wait cycles, the SDRAM controller's accepted
transactions on each port, the GVRAM's array walk, the EGC/GRCG operation counts, the visible-line
graphics cycles, the page-coincidence probe and the CPU's last page fault). Its module is
src/pc9821/core/pc9821_perf_msg.sv. A GFX
record follows the PRF record: one line of 100 bytes, the graphics and stall-split
counters (the GRCG's RMW and TDW walks, the EGC, the plain plane-window write, the CPU's
device wait, and the frame and interrupt counts). Its module is
src/pc9821/core/pc9821_gfx_msg.sv.

Usage:
    tools/decode_telemetry.py FILE        # decode a captured log
    tools/decode_telemetry.py -           # decode stdin
    ssh "${MISTER_HOST:-root@MiSTer}" 'timeout 3 cat /dev/ttyS1' | tools/decode_telemetry.py -
    tools/decode_telemetry.py --clk-mhz=50 FILE   # a capture from the 50 MHz base build

The PRF line's derived block turns its deltas into percentages and rates against the interval the
record itself carries (CY), so nothing is divided by an assumed period: memory wait MW/CY, the
mean GVRAM walk GC/GW, and the EGC and GRCG costs per operation (EG/ET, EG/EU, (GR+GT)/GS from the
GFX record). CY is
in CYCLES, so the seconds and the per-second rates need the clk_sys frequency the capture was taken
at and assume 83.333 MHz (the production profile) unless --clk-mhz says otherwise; the assumption
is printed with the block rather than applied silently.

Capture, for reference:
    ssh "${MISTER_HOST:-root@MiSTer}" 'timeout 5 cat /dev/ttyS1' > /tmp/telemetry.txt

Field map source: src/pc9821/core/pc9821_watchdog_msg.sv for indices 0..348, and
src/pc9821/core/pc9821_dbg_record.sv's WDG_TRIG_IDX for index 349 - the SECOND-TO-LAST byte of the
351-byte record, which the emitter OVERWRITES with the trigger letter. The formatter's own byte there is
'?', the placeholder a capture shows when nothing substituted it, and the last byte is the LF
that ends the line. The field map genuinely has two homes because the byte has two writers and
only one of them is seen; tools/check_telemetry_contract.py holds the two together by checking
that the emitter's index lands on the ROM's '?' and is followed by the LF. Every byte is emitted
one at a time over dbg_uart_byte.
"""

import re
import sys

# (field, width, meaning) for the stall record, in emission order. ONE table, because the record
# is ONE line: the four per-line tables this replaced (W, and SIMPLE_LINES' P, K and L) could only
# be parsed per line, and two of their fields collided once the lines were joined - both the
# keyboard group and the L group called their field "del". They are DLV (bytes delivered) and LSC
# (the last scan code) here, named distinctly so that a single ordered table can hold the whole
# record. Everything is uppercase for the same reason: tools/check_telemetry_contract.py reads this
# table and only matches uppercase names, so an uppercase table is one whose every declared width
# is checked against the formatter.
W_FIELDS = [
    ("CS", 4, "guest CS at the stall"),
    ("EIP", 8, "guest EIP at the stall"),
    ("ST", 2, "io_debug_status: b0 rom_ready, b1 ioctl_download, b2 cpu_run, "
              "b3 ext_mem_busy, b4 load_error, b7:5 the RAM-size code "
              "(log2 of the guest size in MiB, 0..6 = 1..64 MiB)"),
    ("TF", 1, "triple_fault_reset"),
    ("D", 1, "hdd_mounted"),
    ("C", 8, "hdd_capacity in sectors (0x0010F010 = the 542 MiB image)"),
    ("V", 1, "gdc_disp (display enabled)"),
    ("F", 2, "vid_frame_cnt"),
    ("R", 2, "hdd_req_cnt: block requests served"),
    ("E", 2, "hdd_err_cnt: block errors"),
    ("B", 1, "hdd_busy"),
    ("P", 1, "vid_lit_seen"),
    ("N", 2, "vid_lit_cnt (VIDEO counter - not unmapped ports)"),
    ("A", 2, "ata_dbg_state {device present, mounted, channel 0, state, BSY, DRQ}"),
    ("ATA", 8, "the ATA diagnostic word, HIGH HALF FIRST: {abort count, last command, "
               "command count, {4'h0, abort reason}}. One field, because it is one register: "
               "the labels K, X, Z and Q it used to spend all read parts of this value "
               ""),
    ("G", 1, "io_dbg_gate {window enabled, 0x053D bit4, 0x063C[1:0]}"),
    ("M", 1, "mounted_at_run"),
    ("SAD", 4, "GDC start address"),
    ("PIT", 2, "GDC pitch"),
    ("C40", 1, "40-column flag"),
    ("DSP", 1, "display enable, the GDC's register"),
    ("PS2", 2, "keyboard events"),
    ("DLV", 2, "keyboard bytes delivered (the K line's 'del')"),
    ("RD41", 2, "reads of port 0x41"),
    ("WR43", 2, "writes of port 0x43"),
    ("RTS", 1, "keyboard RTS"),
    ("RXE", 1, "keyboard RX enable"),
    ("IRQ", 1, "keyboard IRQ level. Reported ONCE: the L line's 'I=' was the same bit"),
    ("LSC", 2, "the last delivered scan code (the L line's 'del')"),
    ("C0", 2, "keyboard control 0"),
    ("C1", 2, "keyboard control 1"),
    ("IMR", 2, "PIC mask"),
    ("IRR", 2, "PIC request"),
    ("ISR", 2, "PIC in-service"),
    ("VEC", 2, "last INTA vector"),
    ("CPU", 2, "CPU interrupt state: bit 7 EFLAGS.IF, bit 1 the CPU's INTR input; the other "
              "bits read 0 (the CPU exports no other interrupt state)"),
    ("INTA", 2, "interrupt acknowledge count"),
    ("U", 4, "the ARTIC timestamp counter's upper half, the value `in ax,0x5E` returns"),
    ("IO", 4, "the port of the most recent I/O access (the freeze loop's polled port)"),
    ("DR", 1, "that access's direction: 1 read, 2 write, 0 no access yet"),
    ("IV", 2, "that access's data byte"),
    ("HP", 8, "the LAST COMPLETED HPS block transfer's cycles: the sd_rd -> sd_ack -> "
              "256-word stream -> req_done round trip, in clk_sys (50 MHz: 4600 = 92 us). "
              "It is a live gauge held until the next transfer completes, so a capture taken "
              "during a load shows the per-512-byte-block latency the guest waits behind; "
              "with the disk idle it holds the last value and R (the request count) says "
              "whether any happened. Saturating at FFFFFFFF; a rejected request never "
              "touches it"),
    ("FST", 2, "the FDC's state byte {IRQ, DRQ, st[2:0], x_st[2:0]}: b7 the level IRQ (a "
              "result is waiting), b6 dma_drq (a sector byte is waiting on the DMA engine), "
              "b5:3 the command FSM (0 idle, 1 collecting parameters, 2 executing, 3 result "
              "phase), b2:0 the media data path (0 idle, 1 awaiting the media's answer, 2 "
              "moving sector bytes). A hung READ names its wait here: x_st=1 and stuck is the "
              "media (the HPS fetch behind it) never answering, x_st=2 with DRQ=1 is the FDC "
              "waiting on the DMA engine"),
    ("FCM", 2, "the FDC's last command byte: b7 MT (the head-flip walk), b6:5 the MF/flag "
              "bits the model drops, b4:0 the opcode (0x02/0x06/0x0C the READ DATA class, "
              "0x07 RECALIBRATE, 0x0F SEEK, 0x08 SENSE INTERRUPT STATUS, 0x04 SENSE DRIVE "
              "STATUS, 0x03 SPECIFY, 0x0A READ ID)"),
    ("FRS", 8, "the FDC's last answer, HIGH HALF FIRST: {res0, res1, res2, exec_st0}. "
              "res0..2 are the first three bytes of the last result phase - {ST0, ST1, ST2} "
              "for a data command (success is 0x00/0x00/0x00 with the unit/head in res0's low "
              "bits; a missing sector is ST0 IC0 = 0x40 with ST1 ND = 0x04; a write against "
              "the read-only medium is 0x40/0x02 NW) or the ST0/PCN pair a SENSE INTERRUPT "
              "STATUS answered - and exec_st0 is the ST0 latched at the command's accept for "
              "the deferred (probe-subset) completion"),
    ("FCH", 8, "the FDC data path's sector address in flight, HIGH HALF FIRST: "
              "{C, H, R, N} - cylinder, head, sector, size code (bytes = 128 << N). Read it "
              "WITH FST: it names the sector a transfer stopped on"),
    ("ALB", 8, "the ATA's transfer LBA: the sector the in-flight or last READ/WRITE started "
              "at. It advances per sector as a transfer drains, so at a freeze it names the "
              "sector being fetched - the address a failed transfer stopped on"),
    ("ASE", 4, "the ATA task file's {sector_count, error_reg}, HIGH HALF FIRST: how many "
              "sectors the transfer still owes the guest (it decrements per completed "
              "sector) and the error register (0x04 ABRT is an aborted command; the abort "
              "reason is in the ATA word above)"),
    ("T", 2, "the ITF's last stage: the loader stage it is sitting in"),
]

# (field, width, meaning) for the PRF record, in emission order. Every field is 8 hex digits and
# free-running, so it is read as a DELTA between two records (2 s apart); the counters and the
# layout are one module's, src/pc9821/core/pc9821_perf_msg.sv, and check_telemetry_contract.py
# holds its labels and length to this table.
PRF_FIELDS = [
    ("CY", 8, "clk_sys cycles between this record and the previous one: the INTERVAL, and the "
              "denominator every other field here is a fraction of. The trigger's window counters "
              "freeze while a record is being emitted, but this one does not, so the interval is "
              "window + emission and NOT the nominal WDG_PERIOD; dividing by the nominal period "
              "is ~2 % low on a 2 s heartbeat and ~20 % low on a 200 ms stall"),
    ("MW", 8, "clk_sys cycles a CPU memory request was OUTSTANDING and not accepted: the CPU's "
              "wait on the memory system, and the number added to answer WHERE the time "
              "goes when the guest is not wedged"),
    ("RD", 8, "read transactions the SDRAM controller ACCEPTED on the main backend port. It "
              "carries the mapper's CPU RAM and the firmware loader and NOT the GVRAM, which is "
              "on-chip M10K and emits no SDRAM traffic at all; the font fetch has its "
              "own port and is not counted here either. One per valid/ready handshake, so a "
              "4-dword fill burst counts once"),
    ("WR", 8, "write transactions accepted on that port, on exactly the same rule: the mapper's "
              "CPU RAM and the loader, never a GVRAM store"),
    ("GW", 8, "GVRAM ARRAY WALKS started: the one-visit per-lane walk the plain plane-window "
              "access, the GRCG store and the EGC burst's fallback all enter. Read as a "
              "DELTA it is the number of client accesses that walked, and GC/GW is the mean walk in "
              "clk_sys - the number fix 1a moves"),
    ("GC", 8, "clk_sys the GVRAM's array walk was in flight, from the accept cycle (where its "
              "FIRST lane is resolved) through its last. It is charged to the CPU: the walk holds "
              "the client's request, so these cycles are inside MW exactly as GR/EG/GT/PW are"),
    ("ET", 8, "EGC TRANSACTIONS begun: one per EGC command the sequencer accepts (one CPU access - "
              "an I/O-visible 0x3100-style blit). With the graphics record's EG, EG/ET is the mean "
              "cycles a whole EGC transaction holds the CPU"),
    ("EU", 8, "EGC UNITS processed: one per byte/word unit the EGC commits within a transaction. A "
              "unit is one lane group of the CPU access (NP2kai's wr16/rd16 split), so EU/ET is the "
              "mean units per transaction and EG/EU the mean cycles per unit - the pair that "
              "separates 'many EGC operations' from 'long EGC operations'"),
    ("GS", 8, "GRCG STORES begun: one per RMW/TDW store the GRCG accepts. With the graphics "
              "record's GR+GT it gives (GR+GT)/GS, the mean cycles a GRCG store holds the CPU "
              ""),
    ("GV", 8, "Graphics-owned cycles on VISIBLE scanlines: every clk_sys the GRCG OWNED the GVRAM "
              "while v_active was high, the same ownership the graphics record's GR+GT total "
              "accumulates, gated by the raster. This is the sprite pass's VISIBLE "
              "SPILL: section 5.1.2's decisive counter, since a sprite store that lands on a "
              "visible line is a sprite the beam can catch erased"),
    ("EV", 8, "EGC-owned cycles on VISIBLE scanlines: the same gate for the graphics record's EG. "
              "The EGC is the tile layer and redraws in place, so a nonzero EV is expected and "
              "harmless; GV is the one the blacking rides on"),
    ("PD", 8, "A GAUGE, not a counter: clk_sys from the vblank edge (the VSYNC pulse's rise, the "
              "edge INT 0Ah rises on) to the LAST GRCG store of the most recent frame - the sprite "
              "pass's wall-clock against the 66,462 clk_sys the guest has from vline 407 to the "
              "next active line. Read it as a VALUE; its delta between records is the "
              "difference between two frames' passes, not an interval cost"),
    ("PC", 8, "PAGE-COINCIDENCE cycles: every clk_sys a GVRAM STORE was IN FLIGHT (the array was "
              "owned by the GRCG, by the EGC, or by the plain plane-window client - all three "
              "write owners) while the CPU's access page EQUALLED the page "
              "the scanout's line fetch was latched on. CORRECT DOUBLE-BUFFERING keeps "
              "the two pages OPPOSITE every clk_sys, so this is ZERO; a NONZERO PC is the "
              "decisive measurement - the sprite stores are landing on the DISPLAYED page, which "
              "is the page-scanout leak the blackout rides on. Read it as a DELTA across records. "
              "COVERAGE CHANGED 2026-10-03: the arm used to be the GRCG's ownership alone, which "
              "could not see a leak through a PLAIN plane-window store - and Farland Story, the "
              "game this probe was read for, draws with exactly those (its intervals move "
              "GW/GC/PW while GS/GR/GT stay flat). A capture taken before that date under-reports "
              "PC, so a zero PC in an older capture does NOT clear a plain-store leak."),
    ("SP", 8, "STATUS, not a counter: the page the scanout's line fetch is LATCHED on - the "
              "display page (port 0xA4), which pc9821_gdc_text carries out on gfx_line_addr[15] "
              "(its v_page). 0 or 1 as read into the record, so a capture shows the page the beam "
              "is reading; read it WITH AP and PC"),
    ("AP", 8, "STATUS, not a counter: the CPU's access page (port 0xA6), the page a GRCG/EGC "
              "write lands on. 0 or 1 as read into the record; correct double-buffering keeps "
              "AP = !SP while the engines run, so SP == AP alongside a nonzero PC is the leak, "
              "and SP == AP with PC zero is the instant of a software page flip"),
    ("S1", 8, "the font/glyph port's (SDRAM requester 1) ACCEPTED read transactions this "
              "interval, one per valid/ready handshake like RD/WR. RD/WR count port 0 only, so "
              "the font, PCM and scanout loads were invisible; S1/S2/S3 make every requester's "
              "transaction rate visible, and RD+WR+S1+S2+S3 is the whole SDRAM demand"),
    ("S2", 8, "the 86-PCM sample buffer's (SDRAM requester 2) accepted transactions: one 32-bit "
              "word read or written per 44.1 kHz frame, so a steady capture reads ~44/s "
              "regardless of clk_sys"),
    ("S3", 8, "the PEGC packed scanout's (SDRAM requester 3) accepted read bursts. The line "
              "fetch is 16 bursts of 10 dwords per line, so this is the hard-deadline client's "
              "share of the bus; read it WITH W3"),
    ("W3", 8, "clk_sys cycles the scanout port PRESENTED a request and was NOT accepted - the "
              "line fetch waiting for the SDRAM bus. The scanout is the only client with a hard "
              "real-time deadline (a line is 2014 clk_sys at 50 MHz, 40.28 us), so this is the "
              "number that rises first under contention (the SDRAM runs on clk_sys, so its "
              "bandwidth scales with clk_sys while the line's wall time does not)"),
    ("PF", 8, "STATUS, not a counter: the CPU's LAST page-fault ERROR CODE, read live from the "
              "core's latch. A page fault is normal on this machine (DOS/4GW demand-pages), so "
              "this is the most recent one, not the first or the worst - take the capture right "
              "after a guest fault and it is the fatal one. Bit 0 present(1)/not-present(0), "
              "bit 1 write, bit 2 user"),
    ("PA", 8, "STATUS, not a counter: the CPU's LAST page-fault LINEAR ADDRESS (CR2), read live "
              "from the core's latch. This is the datum a guest's own exception printout does "
              "NOT carry, and it is what separates 'the machine produced a wrong pointer' from "
              "'a legitimate access the software refused': read it WITH PF"),
]
# The clk_sys frequency a capture was taken at. The record carries CY in CYCLES on purpose - the
# hardware must not assume a clock - so turning a delta into seconds or a rate is the READER's
# assumption and this decoder states it in its own output rather than applying it silently.
# 83.333 MHz was the production profile when this default was set; pass --clk-mhz for the build you ran.
# --clk-mhz=<mhz> overrides it.
CLK_MHZ_DEFAULT = 83.333
PRF_START = "PRF "

# (field, width, meaning) for the GFX record, in emission order. Every field is 8 hex digits and
# free-running, so it is read as a DELTA between two records (2 s apart); the counters and the
# layout are one module's, src/pc9821/core/pc9821_gfx_msg.sv, and check_telemetry_contract.py
# holds its labels and length to this table. The first four counters partition the CPU's GVRAM
# time (pc9821_gvram's dispatch makes the owners mutually exclusive), so they read as one
# breakdown; DW is the I/O subset of the PRF record's MW, so MW - DW is the memory-only wait.
GFX_FIELDS = [
    ("GR", 8, "clk_sys cycles the GRCG owned an RMW store: the per-lane walk's whole cost, for "
              "which the CPU is held"),
    ("GT", 8, "clk_sys cycles the GRCG owned a TDW store (master.lib's graph_clear fills)"),
    ("EG", 8, "clk_sys cycles the EGC owned the access: a 0x3100 blit or the background restore"),
    ("PW", 8, "clk_sys cycles the plain client owned a plane-window WRITE (a plane READ is not "
              "counted here)"),
    ("DW", 8, "clk_sys cycles an I/O request was outstanding and unaccepted: the CPU's DEVICE "
              "wait. It is the I/O subset of the PRF record's MW, so MW - DW is the memory-only "
              "wait"),
    ("FR", 8, "video frames (vsync edges) in the interval: divides the four cycle counts into a "
              "per-frame cost"),
    ("IR", 8, "interrupt acknowledges (INTA pulses) in the interval"),
    ("WK", 8, "JIS row-cache walk slots whose walk was skipped because the previous walk was "
              "still in flight (issue I4). A SATURATING counter, not free-running: it "
              "stops at 0xFFFF rather than wrapping, so a capture reading a non-zero but "
              "unchanging WK shows the walker overran once and the row it owned was never "
              "filled"),
]
GFX_START = "GFX "

ABORT_REASONS = {0x1: "block engine error", 0x2: "read-path validation",
                 0x3: "IDP (geometry mismatch)", 0x4: "READ MULTIPLE unsupported",
                 0x5: "SET MULTIPLE unsupported", 0x6: "SET FEATURES subcommand",
                 0x7: "write-path validation", 0x8: "unsupported command"}

ST_BITS = [("rom_ready", 0), ("ioctl_download", 1), ("cpu_run", 2),
           ("ext_mem_busy", 3), ("load_error", 4)]

# Index 349, the SECOND-TO-LAST byte of the record; index 350 is the LF that ends the line. The
# watchdog has THREE triggers that emit the identical 351 characters, and this one byte is the
# only thing in the record that separates them. It is emitted by pc9821_wdg_trigger.sv (through
# pc9821_system.sv), not by the formatter - and the formatter's own byte there is '?', which is
# what a capture reads when nothing substituted it.
#
# THE THREE STATES, and the reading of P is the one that matters:
#   W  WEDGED. A request is OUTSTANDING and nothing has COMPLETED for 200 ms. The machine
#      has stopped making progress and the first uncompleted transaction is where to look.
#   S  the CPU has stopped ASKING - no request at all for 200 ms. Halted, or a long I/O wait.
#      Usually healthy: a guest that is thinking looks like this.
#   P  the 2 s heartbeat, emitted whether or not anything is wrong. ON ITS OWN P SAYS NOTHING
#      ABOUT PROGRESS. This comment used to say the opposite - "P means the CPU IS issuing
#      memory requests and is stuck somewhere other than a bus cycle" - and that inference
#      was WRONG, not merely imprecise. The stall arm used to require `!z_valid`, and a wedge
#      HOLDS z_valid high, so the arm could not fire on a wedge at all and every capture from
#      the card read P. P was then read as progress, and the machine's actual stall stayed
#      hidden for a whole session.
#
# The counter resets on COMPLETION and not arrival: the CPU holds the request valid while it
# waits, so a wedge looks like a request that is always present.
PATH_MEANING = {
    "W": "WEDGED - a request is outstanding and NOTHING completed for 200 ms; the machine is "
         "stuck, and the first uncompleted transaction is where to look",
    "S": "IDLE - no request at all for 200 ms; the CPU is halted or in a long I/O wait, "
         "which is usually healthy",
    "P": "HEARTBEAT - 2 s elapsed with nobody asking the machine to progress; says NOTHING "
         "about whether it is running, and must not be read as success",
}
# The trigger is the record's SECOND-TO-LAST byte, index 349; index 348's field ends in the '='
# and two digits of T=, so the wire carries "T=1B", then the trigger, then the LF that ends the
# line. THAT ORDER IS WHY A REGEX DEMANDING THE BYTE IMMEDIATELY AFTER T=<2hex> FINDS IT: the
# trigger is emitted before the newline, not after it. (In an earlier format the trigger REPLACED the
# record's last byte, so the byte after the trigger was the next record's 'W' and a capture read
# through a tty - ICRNL maps CR to LF - showed the trigger glued to the next record's start.)
# The byte is found by position rather than by a NAME=token because it has no name; the ROM's own
# byte there is '?', so a capture that shows '?' genuinely cannot say which trigger fired.
#
# THE 'T=' MUST BE ANCHORED TO A FIELD BOUNDARY, and this is not cosmetic. Another field is
# named PIT, so the text 'PIT=50' CONTAINS 'T=50'; searching unanchored for T=<2hex> can match
# inside it, and then it consumes the next field's first letter as the trigger. PIT is emitted
# BEFORE the T field that carries the trigger, so search() would take the spurious match first: a
# machine that is spinning (P) would be decoded as wedged (S), which is the exact inversion this
# whole diagnostic exists to prevent. Requiring whitespace or the string start before 'T=' makes
# the match the field and nothing else.
PATH_RE = re.compile(r"(?:^|\s)T=[0-9A-Fa-f]{2}\s*([WSP?])")
# A chunk with no complete T=<2hex> field is a capture cut mid-message, not a message whose
# trigger is missing, and the two must not read the same: the first is our capture being short,
# the second would be a defect in the formatter.
STAGE_RE = re.compile(r"(?:^|\s)T=[0-9A-Fa-f]{2}")

# Frames of the 56.42 Hz raster between trigger intervals, for reading the cadence out of
# vid_frame_cnt when this byte is unavailable. W has no fixed cadence of its own: it is
# emitted at the stall interval, which is a tenth of P's, but only while a request is stuck,
# so it repeats rather than settling into a period.
PATH_CADENCE = {"P": "~113 frames of vid_frame_cnt between samples",
                "S": "~11 frames of vid_frame_cnt between samples",
                "W": "~11 frames while a request is stuck, repeating: the stall interval, and "
                     "the message recurs until the request completes"}


def parse_line(line, fields):
    """Pull 'NAME=hex' tokens in order, tolerating a NUL where an index is unassigned."""
    out = {}
    for name, width, _ in fields:
        m = re.search(r"(?:^|\s)" + re.escape(name) + r"=([0-9A-Fa-f]{%d})" % width, line)
        if m:
            out[name] = int(m.group(1), 16)
    return out


def delta(cur, prev, name):
    """One field's value over the interval. The counters are free-running 32-bit, so the delta is
    taken modulo 2^32: that is the same arithmetic the hardware does and prints nothing special."""
    if name not in cur or name not in prev:
        return None
    return (cur[name] - prev[name]) & 0xFFFF_FFFF


def pct(num, den):
    """A measured percentage, or 'n/a' where the interval gave the denominator no events."""
    if not num or not den:
        return "n/a"
    return "%.1f%%" % (100.0 * num / den)


def rate(num, seconds):
    """Events per second, in thousands, from a cycle count and the interval that carried it."""
    if seconds <= 0:
        return "n/a"
    return "%.1fk/s" % (num / seconds / 1000.0)


def print_prf_derived(cur, prev, gfx, prev_gfx, clk_mhz):
    """THE POINT OF THE TWO ADDITIONS: the arithmetic, per interval, with the record's
    OWN measured denominator.

    Every field here is a delta over CY, so a percentage is a measurement rather than a number
    divided by an assumed interval: MW/CY is how much of the time is spent waiting, and the
    per-operation costs say what each GVRAM walk, EGC operation and GRCG store holds the CPU for.
    """
    cy = delta(cur, prev, "CY")
    print(f"  CY delta {cy:,} cycles ({cy / (clk_mhz * 1e6):.3f} s at {clk_mhz:.3f} MHz)")
    if not cy:
        print("    no interval: the ratios below are undefined over zero cycles")
        return
    seconds = cy / (clk_mhz * 1e6)
    mw = delta(cur, prev, "MW") or 0
    dev = ""
    if gfx and prev_gfx:
        dw = delta(gfx, prev_gfx, "DW")
        if dw is not None:
            dev = f"  (device DW/CY = {pct(dw, cy)}, memory-only {pct(mw - dw, cy)})"
    print(f"    memory wait    MW/CY = {pct(mw, cy)}{dev}")
    rd = delta(cur, prev, "RD") or 0
    wr = delta(cur, prev, "WR") or 0
    s1 = delta(cur, prev, "S1") or 0
    s2 = delta(cur, prev, "S2") or 0
    s3 = delta(cur, prev, "S3") or 0
    w3 = delta(cur, prev, "W3") or 0
    ratio = ("%.2f" % (wr / rd)) if rd else "n/a"
    print(f"    transactions   RD = {rate(rd, seconds)}  WR = {rate(wr, seconds)}"
          f"     (write:read {ratio})")
    print(f"    other ports    font {rate(s1, seconds)}  pcm {rate(s2, seconds)}"
          f"  scan {rate(s3, seconds)}     scanout bus wait W3/CY = {pct(w3, cy)}")
    gw, gc = delta(cur, prev, "GW") or 0, delta(cur, prev, "GC") or 0
    if gw:
        print(f"    GVRAM walk     GW {gw:,} walks, GC {gc:,} cycles = {gc / gw:.1f} clk_sys per "
              f"walk; GC/CY = {pct(gc, cy)} of the interval, and it is charged to the CPU")
    else:
        print("    GVRAM walk     no walks in the interval")
    # The EGC/GRCG operation counts: paired with the graphics record's EG/GR/GT they give
    # cycles-per-transaction and cycles-per-unit, the split between "many operations" and "long
    # operations" that graphics-hold.md section 8 asks for before section 7.1 vs 7.2.
    et, eu, gs = (delta(cur, prev, n) or 0 for n in ("ET", "EU", "GS"))
    if et or eu or gs:
        eu_per = ("%.2f" % (eu / et)) if et else "n/a"
        print(f"    EGC ops        ET {et:,} transactions, EU {eu:,} units "
              f"({eu_per} units/transaction)")
    if gfx and prev_gfx:
        eg = delta(gfx, prev_gfx, "EG")
        gr = delta(gfx, prev_gfx, "GR") or 0
        gt = delta(gfx, prev_gfx, "GT") or 0
        if eg is not None and et and eu:
            print(f"    EGC cost       EG/ET = {eg / et:.1f} clk_sys per transaction, "
                  f"EG/EU = {eg / eu:.1f} clk_sys per unit")
        if gs:
            print(f"    GRCG cost      (GR+GT)/GS = {(gr + gt) / gs:.1f} clk_sys per store")
    # The visible-region pair and the pass gauge. GV/EV are the
    # graphics record's GR+GT / EG restricted to VISIBLE lines: a visible sprite-store cycle is a
    # store the beam can overtake, which is the blackout's own definition. PD is a GAUGE - the most
    # recent frame's sprite pass - and is compared against the 66,462 clk_sys the guest has between
    # the vblank edge (vline 407) and the next frame's first active line.
    gv, ev = delta(cur, prev, "GV") or 0, delta(cur, prev, "EV") or 0
    if gv or ev:
        print(f"    visible spill  GV {gv:,} + EV {ev:,} LANDED ON VISIBLE LINES = "
              f"{pct(gv + ev, cy)} of the interval; a nonzero GV is sprite stores the beam can catch")
    else:
        print("    visible spill  none: no graphics-owned cycle landed on a visible line")
    if cur.get("PD") is not None:
        print(f"    sprite pass    PD = {cur['PD']:,} clk_sys from the vblank edge to the last GRCG "
              f"store (window from vline 407 = 66,462 clk_sys)")
    # The page-coincidence probe. PC is the DECISIVE counter: ZERO means every GRCG store
    # was on the hidden page (correct double-buffering, and the vanish is then on the displayed
    # page's own read - instrument the GRCG RMW read-vs-write ordering next); NONZERO means the
    # stores landed on the page the scanout is reading. SP/AP are the two page bits themselves.
    pc = delta(cur, prev, "PC") or 0
    if pc:
        print(f"    page coincid.   PC {pc:,} = {pct(pc, cy)} of the interval: GVRAM STORES LANDED ON "
              f"THE DISPLAYED PAGE - the access page and the scanout page were EQUAL while an "
              f"array owner (GRCG, EGC or plain window client) held the store "
              f"(SP={cur.get('SP')}, AP={cur.get('AP')})")
    else:
        print("    page coincid.   PC 0: no GVRAM store landed on the displayed page (the two pages "
              "stayed opposite while a store was in flight). NOTE: an older capture's PC cannot "
              "speak for the plain plane-window store - see the PC field's coverage note")
    if cur.get("SP") is not None and cur.get("AP") is not None:
        print(f"    page bits       scan_page_q SP = {cur['SP']}, access_page AP = {cur['AP']}"
              f"  ({'COINCIDENT' if cur['SP'] == cur['AP'] else 'opposite'} at capture)")


def decode(text, clk_mhz=CLK_MHZ_DEFAULT):
    text = text.replace("\x00", "?")  # an unassigned character index shows up as NUL
    # FLATTEN THE WHITESPACE, THEN SPLIT ON THE RECORD START MARKER. The stall record is one
    # line, so the line breaks could frame it - except that the records that follow it (PRF here,
    # GFX) are lines too, and a terminal-wrapped capture breaks the line at 80
    # columns wherever it likes. Flattening every whitespace run to one space and splitting on the
    # start marker makes the framing independent of where the breaks fall: every chunk then holds
    # one stall record, the records emitted after it, and its own "T=<2hex><trigger>".
    flat = re.sub(r"\s+", " ", text)
    msgs = [c for c in re.split(r"(?=W CS=)", flat) if c.strip()]
    if not msgs:
        print("no telemetry message found", file=sys.stderr)
        return 1

    prev_prf = {}
    prev_gfx = {}
    for msg in msgs:
        joined = msg
        # A NUL becomes '?' on the way in. The ONE legitimate '?' is the trigger's own placeholder,
        # which pc9821_system.sv is supposed to overwrite: a '?' anywhere else is a selector arm
        # that is missing, which emits NUL into the middle of a field and shifts everything after
        # it. The two must not read the same - the trigger block below reports the placeholder.
        stage = STAGE_RE.search(joined)
        if "?" in joined and joined.index("?") != (stage.end() if stage else -1):
            idx = joined.index("?")
            print(f"WARNING: unassigned character (NUL) at offset {idx} of the joined "
                  f"text - a case arm is missing in the watchdog formatter. (This is "
                  f"an offset into the re-joined lines, not a message character index.)")
        print("=" * 72)
        w = parse_line(joined, W_FIELDS)
        # THE ORDER IS PART OF THE MAP. A table in emission order only reads a capture correctly
        # if the record carries the fields in that order, and two reordered fields of the same
        # width would still pass every width check in the contract. So the labels are required to
        # appear in the record in the table's order, and the first that does not is named.
        at = [(name, joined.find(" " + name + "=")) for name, _, _ in W_FIELDS]
        seen = [p for _, p in at if p >= 0]
        if seen != sorted(seen):
            print(f"WARNING: the record's fields are NOT in the emission order this decoder "
                  f"reads - the first to disagree is "
                  f"{[n for (n, p), q in zip(at, seen) if p != q][:4]} - so a capture read by "
                  f"index would be mis-mapped")
        for name, _, meaning in W_FIELDS:
            if name in w:
                print(f"  {name:<5} = {w[name]:>10}  {meaning}")
        if "ST" in w:
            st = w["ST"]
            flags = ", ".join(n for n, b in ST_BITS if st & (1 << b))
            print(f"        ST bits  : {flags or 'none'}  (RAM-size code = {st >> 5}"
                  f" = {1 << (st >> 5)} MiB)")
        # ATA is one word {aborts, last command, commands, {4'h0, reason}}, and it is emitted as
        # ONE field, so its parts are printed from it rather than read as four fields.
        if "ATA" in w:
            cmd = w["ATA"]
            reason = cmd & 0xFF
            print(f"  >>> ATA word 0x{cmd:08X}: {cmd >> 24} aborted command(s), last command "
                  f"0x{(cmd >> 16) & 0xFF:02X}, {cmd >> 8 & 0xFF} command(s), abort reason "
                  f"{reason}")
            if reason:
                print(f"      reason {reason} = "
                      f"{ABORT_REASONS.get(reason, 'UNKNOWN - no code has this value')}")
        # FST/FCM/FRS/FCH: the FDC's own diagnostics. The state byte is split out because
        # its two halves answer the two different hangs, and the result word because
        # ST0/ST1 are the failure class a capture must show without arithmetic.
        if "FST" in w:
            fst = w["FST"]
            fcm = w.get("FCM", 0)
            fch = w.get("FCH", 0)
            frs = w.get("FRS", 0)
            print(f"  >>> FDC state 0x{fst:02X}: IRQ={fst >> 7 & 1} DRQ={fst >> 6 & 1} "
                  f"st={fst >> 3 & 7} x_st={fst & 7}, command 0x{fcm:02X}, "
                  f"sector C={fch >> 24 & 0xFF:02X} H={fch >> 16 & 0xFF:02X} "
                  f"R={fch >> 8 & 0xFF:02X} N={fch & 0xFF:02X}")
            print(f"      last result: ST0={frs >> 24 & 0xFF:02X} "
                  f"ST1={frs >> 16 & 0xFF:02X} ST2={frs >> 8 & 0xFF:02X} "
                  f"exec_st0={frs & 0xFF:02X} - 40/04 is a missing sector "
                  f"(ST0 IC0 with ST1 ND), 40/02 a write on the read-only medium")
        # ALB/ASE: the transfer context. Printed even when zero: a transfer stuck at LBA 0
        # is a reading, and zero owed with no error is a completed transfer.
        if "ASE" in w:
            ase = w["ASE"]
            alb = w.get("ALB", 0)
            print(f"  >>> ATA transfer: LBA 0x{alb:07X}, {ase >> 8} sector(s) still owed, "
                  f"error_reg 0x{ase & 0xFF:02X}")
            print("      ALB names the sector the transfer stopped on; error_reg 0x04 with a "
                  "nonzero abort reason in the ATA word above is OUR engine failing (reason 1 "
                  "the block engine, reason 2 the guest asking past the image)")
        if "U" in w:
            u = w["U"]
            # PRINTED EVEN WHEN ZERO. The field this replaced skipped zero, on the reasoning that
            # an unmapped port of 0 meant "never happened" - but zero is a perfectly good reading
            # of a counter, and a counter stuck at zero is exactly the fault being hunted.
            print(f"  >>> ARTIC counter upper half, which 'in ax,0x5E' returns: 0x{u:04X}")
            print("      it should advance every 65536/307200 = 213 ms. If it is IDENTICAL across")
            print("      messages the counter is NOT running - and the firmware's delay() helper at")
            print("      BANK3:0B2A spins on this value until it reaches a deadline, so a counter")
            print("      that never advances is a loop that never exits.")
        # IO/DR/IV: the most recent I/O access. Printed even for a zero port, for the same
        # reason the U block above is: a field stuck at zero is a reading, not an absence.
        if "IO" in w:
            direction = {1: "READ", 2: "WRITE", 0: "none yet"}.get(w.get("DR"), "?")
            print(f"  >>> last I/O port: 0x{w['IO']:04X}  {direction}"
                  f"  data=0x{w.get('IV', 0):02X}")
            print("      The most recent I/O access, latched in pc9821_iobus as the CPU ran it: a "
                  "freeze loop that polls one port shows that port here.")
        m = PATH_RE.search(joined)
        if not m and not STAGE_RE.search(joined):
            print("  >>> trigger: INCOMPLETE MESSAGE - no T=<2hex> field, so this capture was "
                  "cut mid-message. Take a longer capture rather than reading this as a missing "
                  "trigger byte.")
        elif not m:
            print("  >>> trigger: NOT FOUND - the T=<2hex> field is present but no S/P/? byte "
                  "follows it, which is a defect in the formatter's last arm")
        elif m.group(1) == "?":
            print(f"  >>> trigger: UNKNOWN - the formatter's own byte at this position is '?', "
                  f"so nothing substituted the path byte and this capture cannot say which "
                  f"path fired. Read the cadence instead: F advancing "
                  f"{PATH_CADENCE['P']} is the heartbeat path, {PATH_CADENCE['S']} the idle "
                  f"stall, and {PATH_CADENCE['W']}")
        else:
            print(f"  >>> trigger: {m.group(1)} = {PATH_MEANING[m.group(1)]}")
            if m.group(1) == "P":
                print("      NOTE: P is the heartbeat and is NOT evidence of progress. A wedged "
                      "machine reads P if the capture predates the W path, so check the stage "
                      "and EIP stillness before reading this as health.")
        # The PRF record follows the stall record on its own line. The counters are free-running,
        # so the DELTA since the previous record is the interval's cost - which is the number a
        # reader is after - and it is printed beside the raw value when there is a previous record.
        if PRF_START in joined:
            p = parse_line(" " + joined.split(PRF_START, 1)[1], PRF_FIELDS)
            # The GFX record is parsed here rather than below because the PRF derived block
            # reports the DEVICE part of the wait (GFX's DW) when its record is present.
            g = (parse_line(" " + joined.split(GFX_START, 1)[1], GFX_FIELDS)
                 if GFX_START in joined else {})
            if p:
                print("  -- PRF line: subsystem performance, free-running counters --")
            for name, _, meaning in PRF_FIELDS:
                if name in p:
                    # PD is a per-frame GAUGE (the last sprite pass's wall-clock) and SP/AP are
                    # live status bits (the two page levels), not free-running counters, so a
                    # delta across records is not an interval cost and is not printed for them.
                    dtxt = (f"  delta {((p[name] - prev_prf[name]) & 0xFFFF_FFFF)}"
                            if name in prev_prf and name not in ("PD", "SP", "AP") else "")
                    print(f"  {name:<5} = 0x{p[name]:08X} ({p[name]}){dtxt}  {meaning}")
            if p and prev_prf:
                print_prf_derived(p, prev_prf, g, prev_gfx, clk_mhz)
            prev_prf = p
        # The GFX record follows the PRF record, and its counters are free-running too, so it is
        # read the same way: the DELTA since the previous record is the interval's graphics and
        # stall-split cost. It carries NO field name in common with PRF, so the two parses cannot
        # collide even though both records are in the same chunk.
        if GFX_START in joined:
            if g:
                print("  -- GFX line: graphics path + CPU stall split, free-running counters --")
            for name, _, meaning in GFX_FIELDS:
                if name in g:
                    dtxt = (f"  delta {((g[name] - prev_gfx[name]) & 0xFFFF_FFFF)}"
                            if name in prev_gfx else "")
                    print(f"  {name:<5} = 0x{g[name]:08X} ({g[name]}){dtxt}  {meaning}")
            prev_gfx = g
    return 0


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--clk-mhz=")]
    clk_mhz = CLK_MHZ_DEFAULT
    for a in sys.argv[1:]:
        if a.startswith("--clk-mhz="):
            clk_mhz = float(a.split("=", 1)[1])
    if not args:
        print(__doc__)
        sys.exit(2)
    data = sys.stdin.read() if args[0] == "-" else open(args[0], errors="replace").read()
    sys.exit(decode(data, clk_mhz))
