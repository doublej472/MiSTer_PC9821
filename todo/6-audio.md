# 6. Audio: OPNA/SSG/ADPCM

18. **OPNA extended read-back: `0x18E` with 0x18C = 0F.** **UNVERIFIED (INFERRED).** The `0x110`
    flag masks are implemented for both timers: `pc9821_opna.sv` `tmr_mask_a`/`tmr_mask_b` hold the
    Timer A/B flag reset through the flag-reset seam while 0x110 bit 0/1 stands, as the real Xe10
    does (`docs/probes/KIT1-XE10-OPNA.TXT` STATUS3, `docs/probes/KIT2-XE10-OPNA4.TXT:168-173` S3A;
    `tb_pc9821_opna_kit1`). Still open: `0x18E` with 0x18C = 0F moves between runs (`00 00` in
    `docs/probes/OPNA.TXT`, `7F 7F` in `KIT1-XE10-OPNA.TXT`; the marker 5A never reads back): the
    A/D register's live input, inconclusive, so the core's `00` stands. The machine's 0x188 also
    carries bit 3 (and once bit 5, `st188=29`) with the flag, and bit 7 right after a 0x110 write
    (`st188=88`): the +0 status bits item 155 lists. **Done when:** the 0x18E answer has a rule or
    moves to the known issues (`docs/user/troubleshooting.md`).

78. **OPNA `0xA466` DAC-control handling.** **UNVERIFIED (INFERRED).** The core adopts NP2kai's
    Policenauts/WinNT workaround, which is not hardware evidence. **Done when:** a capture or a
    datasheet justifies (or replaces) it.

150. **Sync `sys/` with Template_MiSTer.** **NEEDS RE-VERIFICATION.** `sys/` is now a verbatim
    copy of upstream 76dd8f5 (2026-10-28; was 3ea1134, 2026-08-26): 6 files, +72/-16. It brings
    afd7808 (registered analog/I2S audio outputs and a debounced I/O-board mode bit, against
    glitches on the 3.5 mm output), 9c8eadb (five `LFB_*` emu inputs, now declared unused in
    `module emu`), 5dda373 (YC timing; the core sets `MISTER_DISABLE_YC`) and 76dd8f5 (force
    feedback; FFB stays 0 and the six `joystick_N_ffb` inputs are tied to 0). The static checks
    and an analysis-and-synthesis compile pass on it. A `sys/` change moves `pll_hdmi` placement,
    so what remains is hardware-side: the 6-seed sweep with the `pll_hdmi` floor and the SDRAM
    I/O gate, the 10-load screen, the scripted regression, and an ear check of the 3.5 mm output
    on a card with an I/O board. **Done when:** those pass on the synced tree.

155. **OPNA BUSY, write loss and the 0x188 read details.** **UNVERIFIED (INFERRED).** The real Xe10's
    XE10T `/OPNA2` run (`docs/probes/XE10T-XE10-OPNA2.TXT`; the same binary on the core:
    `docs/probes/core/XE10T-CORE-rc6-s3-OPNA2.TXT`, `XE10T-CORE-opnasafe-OPNA2.TXT` and
    `-run2.TXT`) measures the BUSY rule over 128 write phases per class. An ADDRESS write is
    never busy (first poll clear 128/128). Every DATA class is bimodal: FM 0x30/0x40/0xA0/0xB0,
    key 0x28, SSG 0x08, rhythm 0x10/0x11, ADPCM-B 0x100 and extended FM 0x130 read clear at the
    first poll in 72.7-82.0% of trials (about 75%), and otherwise stay busy for 28-29 polls,
    28.5-30.1 us from the write (about 25 us of BUSY, the YM2608's 192-master-clock busy; ymfm
    ym2608::write_data `ymfm_set_busy_end(32 * m_fm.clock_prescale())`). A write made DURING
    BUSY is lost on the machine: B2B_TMR/B2B_TMR3 (timer A loads 0x24/0x25, and on B2B_TMR3 the
    0x27 start, with no BUSY poll) lost one or both loads in 7/8 and 8/8 trials and the start in
    6/8. The core shows BUSY only once its 128-word write queue is half full (`pc9821_opna.sv`
    `wrq_busy`, `tb_pc9821_opna_busy`), so it is never busy in these rows (first poll clear
    100%, faster than the machine's 25% tail) and never loses a write (the queue): more lenient
    by design, so a guest that writes during BUSY works on the core and can lose writes on the
    machine. The flags stay coherent with the queue's lag: the timer flag reset acts at the
    guest's write (`host_clr_tmr`), and a status read waits while a queued IRQ-enable or
    ADPCM-B control/flag write has not reached the chip (`io_rd_hold`, `tb_pc9821_opna_flagsync`;
    the stall is `docs/trade-candidates.md` T77, accepted). The machine needs 2-3 status reads
    (6.51 us median) after a 0x27 reset before the flag reads clear (FR_TMRA/FR_TMRB
    `reads=2/3/3`); the core's first read is clear (2.03 us): faster, left. IRQ12 now leaves the
    slave IRR when the flag reset lowers the line (`tb_pc9821_opna_xe10_rows`). The probe's
    TMRB_FF start-to-flag (42.7 us on the machine, 89.9 us on opnasafe) is the free-running /16
    timer-B prescaler's phase, which the probe's own loop locks (the machine's i=2..7 sit at
    101-105 PIT): the core's loop is shorter because it never waits on BUSY, so the next step is
    farther away; the start itself acts within the machine's slowest trial
    (`tb_pc9821_opna_xe10_rows` TMRA_3FF/TMRB_FF). Timer A's rate: the decoder's 1-64-count fit
    reads 17.941 us/count on the machine against 18.03-18.08 on the core, but the machine's
    1024-count B2B trials take 18.48-18.52 ms (18.05 us/count, nominal 18.029), so no rate
    difference is shown. **Decided (owner, 2026-11-01):** (a) the 25% BUSY tail is NOT
    modelled: the core keeps the common case and stays faster, never slower (`docs/policies.md`
    "Fixed design decisions"); (b) the timer registers act at the guest's write, not behind the
    write queue: 0x24, 0x25, 0x26 and 0x27 bits 3-0 (loads and enables) are latched by the glue on
    the accepted write and drive jt12's timers through the flag-reset seam (`pc9821_opna.sv`
    `host_tmr`, `src/opna/LICENSE-SCOPE.md`), as the flag resets already did, while 0x27 bits 7-6
    (the CH3 mode) stay in the queued copy, ordered with the FM writes ahead of them. Before
    this, a 1-count start behind a polling driver's loaded queue reached its flag 845 us (A) and
    1139 us (B) after the write; now 14.2 us and 283.8 us, inside the machine's slowest
    TMRA_3FF/TMRB_FF trials (`tb_pc9821_opna_xe10_rows` TMRQ; TMRQ_RUN keeps the chip's
    reload-at-overflow rule for a load written while running, TMRQ_MODE the CH3-mode order).
    The timer-at-write rule is the references' (ymfm `engine_mode_write`, NP2kai
    `opna_settimer`); no capture times a start written straight after an FM burst. Not
    modelled, for lack of a rule: the +0 status bits 6-2 (`X IDC st=27`, B2B_SSG `st=A3/A7/A5/A9`, B2B_TMR `st=29`,
    while FR_TMRA reads `st0=01`) and the as-found +2 read (00 on the machine, 0F on the core: the
    select and data the boot path left).
    Also not modelled, by choice: the die's select synchronizer (a data write under about 1.5 us
    after its select becomes the address) and its pending level/key word, dropped by ANY select
    within one 9 us turn (XE10T `/OPNA3`, YM2608-LLE; `docs/pc9821-port-status.md` "Write timing
    at the YM2608"): the queue's 27 us rhythm drain keeps every write a BUSY-honouring driver
    makes, and only out-of-spec sequences differ. The LLE-predicted `/OPNA3` follow-ups (a timer-B
    select race read on the PIT; the 0x18-data to 0x19-select gap swept 1-16 us) would pin it.
    **Done when:** an XE10T row that writes a timer start right after a burst of FM data writes
    (BUSY-polled, as PMD's opnset44) reads its 1-count flag within the TMRA_3FF/TMRB_FF bounds on
    the machine and on the core, confirming (b) on hardware, and the read details above have a
    rule or are moved to the known issues (`docs/user/troubleshooting.md`). Kit 2's `/OPNA4` (`docs/probes/KIT2-XE10-OPNA4.TXT`)
    is that row: a 1-count Timer A start after 0, 8, 32, 64 and 128 BUSY-polled FM writes reaches its
    flag 30.5-35.4 us (median) after the write on the machine at every burst length, so a polled burst
    does not delay a start on hardware, which confirms (b); the core reaches it 11.8-18.3 us after the
    write, likewise flat (`docs/probes/core/KIT2-CORE-OPNA4.TXT`; the decoder's "within" verdict for
    the core only checks the upper bound), about 20 us earlier than the machine, as kit 1's n = 0 row
    already showed. Each BUSY-polled data write in a burst takes 31.6-32.2 us on the machine at every
    n (every write meets the previous one's BUSY), and 2.1 us on the core at n = 8 rising to 25.4 us
    at n = 128 as the queue fills: the documented leniency. Timer B's start-to-flag follows the
    free-running prescaler's phase on both.

173. **The UART-mode exit (0xFF) is not ACKed: confirm it on an MPU-PC98II.** **UNVERIFIED
    (INFERRED).** Owner decision, implemented: the 0xFF that leaves UART mode still returns the
    card to intelligent mode, but queues no ACK byte and raises no IRQ6 (`pc9821_mpu.sv`
    `cmd_ack`; `tb_pc9821_mpu` section 10a, `tb_pc9821_mpu_probe` through the `manual` model of
    `mputest_decode.py`). Every other command's ACK, the intelligent-mode 0xFF's included, is
    unchanged, and so is the all-notes-off burst question (item 174). Evidence: the Roland MPU-401
    Technical Reference Manual (section 5.3, "The MPU-401 will not return an ACK ($FE) in this one
    case."; section 4.1), DOSBox-X (`mpu401.cpp`, `return;	//do not send ack in UART mode`), and
    the owner's older MPU-PC98 (0 ACKs in 4 of 4, `docs/probes/MPUTEST-XE10.TXT`,
    `MPUTEST-XE10-BYTES.TXT`). NP2kai ACKs it. The owner's condition was that programs still work:
    the UART-mode drivers checked all bound or skip the wait (DOOM's DMX code polls at most 0x10000
    and 0x7D00 status reads, FMP3 3.05 reads the data port once without waiting, MMD's install-time
    0xFF waits a bounded time and ignores the result). The card the core models, the MPU-PC98II,
    has not been measured. **Done when:** an MPU-PC98II (or MPU-401) MPUTEST capture shows the
    exit row as `ack=--` (or, if it ACKs, the owner revisits the decision), and the hardware check
    of DOOM's and Farland Story's MIDI music on a card decodes with 0 errors.

174. **MIDI wire capture of the MPU card.** **CAPTURE-PENDING.** The MPUTEST runs on the Xe10's
    original MPU-PC98 played correctly into an SC-88 Pro (owner's listening check, every labelled
    section as described), but what reached MIDI OUT was not recorded. Open: whether 0xFF and 0x3F
    send the all-notes-off bursts NP2kai's MPU-PC98II model sends (the ~20 ms busy after an ACKed
    0xFF hints at one), how many of the 200 blind `/RAW` bytes reach MIDI OUT, and whether the
    running-status 0xD0 stream is byte-exact. Evidence about the older card only (item 173).
    **Done when:** `amidi -p hw:N,0,0 -a -c -r` captures `mputest /BYTES` and `/RAW` on the card's
    MIDI OUT and `mputest_decode.py --wire` reads it.

187. **YM2608 register read map: the lost-interrupt state of the kit-1 YM29 run.** **CAPTURE-PENDING.**
    The read map both kits measured is implemented (`pc9821_opna.sv` `reads_ff_closed`: with
    0xA460 bit 0 clear 0x10-0x1F, 0x22, 0x29 and 0xB4-0xB7 read FF and every other select from 0x20
    to 0xFE echoes, 0x00-0x0D 00, 0x0E/0x0F FF, 0xFF 01; with it open every select 0x10-0xFE
    echoes; `docs/probes/KIT1-XE10-YM29.TXT` READMAP/RD29, `docs/probes/KIT2-XE10-OPNA4.TXT:126-166`;
    `tb_pc9821_opna_kit1`). Still open: in the kit-1 YM29 run the timer interrupt came once and then
    never again for every 0x29 value while the flags kept rising (slave IRR bit 4 never set), after
    OPNAPRO and PEGCRD ran in the same boot; the fresh-boot v2 run (`docs/probes/YM29B-XE10.TXT`)
    took 21 per window, and the core's run of the same kit lost them only at 0x29 = 1F. **Done
    when:** the lost-interrupt state is reproduced on the machine with the status and 0x110 read
    before the windows.

