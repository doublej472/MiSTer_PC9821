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

78. **PC-9801-86 PCM: the `0xA46A` write guard and the Policenauts IRQ re-assert.**
    **UNVERIFIED (INFERRED).** Two NP2kai workarounds in `src/pcm86/pc9821_pcm86.sv` rest on NP2kai
    alone: the `0xA46A` DAC-control write is dropped when its low nibble is `0xF` (NP2kai
    `cbus/pcm86io.c` `pcm86_oa46a`, "WORKAROUND: WinNT 3.5"), and a gated subset of NP2kai's
    Policenauts IRQ re-assert (`cbus/pcm86io.c:122-127`). The `0xA46A` reset value `0x32` is
    inferred too: the machine reads `B0` (`docs/probes/KIT1-XE10-CFG0.TXT:34`, the core `32`), but
    at a DOS prompt, after the BIOS or a driver wrote it. (`0xA466`'s volume rule is not part of
    this: NP2kai and qemu agree on it.) **Done when:** a probe that writes every `0xA46A` value
    with `0xA468` bit 5 clear, reads each back, and reads `0xA466`, `0xA468` and `0xA46A` straight after a cold reset (not at a DOS
    prompt) is captured on the Xe10,
    and the guard and the reset value follow it with fail-first rows.

155. **OPNA BUSY, write loss and the 0x188 read details.** **CAPTURE-PENDING** (the read details). The real Xe10's
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
    difference is shown. **Decided and done (owner, 2026-11-01):** (a) the 25% BUSY tail is NOT
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
    `opna_settimer`), and kit 2's `/OPNA4` confirms (b) on hardware
    (`docs/probes/KIT2-XE10-OPNA4.TXT`, `docs/probes/core/KIT2-CORE-OPNA4.TXT`): a 1-count Timer A
    start after 0, 8, 32, 64 and 128 BUSY-polled FM writes reaches its flag 30.5-35.4 us (median)
    after the write on the machine at every burst length and 11.8-18.3 us on the core, likewise
    flat, about 20 us earlier (the decoder's "within" verdict for the core only checks the upper
    bound). Each BUSY-polled data write in a burst takes 31.6-32.2 us on the machine and 2.1 us on
    the core at n = 8 rising to 25.4 us at n = 128 as the queue fills: the documented leniency.
    **Open, for lack of a rule:** the +0 status bits 6-2 (`X IDC st=27`, B2B_SSG `st=A3/A7/A5/A9`,
    B2B_TMR `st=29`, while FR_TMRA reads `st0=01`) and the as-found +2 read (00 on the machine, 0F on
    the core: the select and data the boot path left); `docs/user/troubleshooting.md` lists them
    under Known issues meanwhile.
    Also not modelled, by choice: the die's select synchronizer (a data write under about 1.5 us
    after its select becomes the address) and its pending level/key word, dropped by ANY select
    within one 9 us turn (XE10T `/OPNA3`, YM2608-LLE; `docs/pc9821-port-status.md` "Write timing
    at the YM2608"): the queue's 27 us rhythm drain keeps every write a BUSY-honouring driver
    makes, and only out-of-spec sequences differ. The LLE-predicted `/OPNA3` follow-ups (a timer-B
    select race read on the PIT; the 0x18-data to 0x19-select gap swept 1-16 us) would pin it.
    **Done when:** a capture of the +0 status at known chip states and of +2 straight after
    power-up gives the read details a rule and the core follows it with fail-first rows, or the
    owner accepts the Known issues line as final.

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
    exit row as `ack=--` (or, if it ACKs, the owner revisits the decision), and DOOM's and Farland Story's
    MIDI music, played on a card in the MiSTer game check with the MIDI UART output captured, decodes
    with 0 errors through `mputest_decode.py --wire`.

174. **MIDI wire capture of the MPU card.** **CAPTURE-PENDING.** The MPUTEST runs on the Xe10's
    original MPU-PC98 played correctly into an SC-88 Pro (owner's listening check, every labelled
    section as described), but what reached MIDI OUT was not recorded. Open: whether 0xFF and 0x3F
    send the all-notes-off bursts NP2kai's MPU-PC98II model sends (the capture's long wait after a
    UART-mode 0xFF is the unACKed exit's ACK-poll timeout, item 173, not a busy period, so nothing
    in it shows a burst), how many of the 200 blind `/RAW` bytes reach MIDI OUT, and whether the
    running-status 0xD0 stream is byte-exact. Evidence about the older card only (item 173).
    **Done when:** `amidi -p hw:N,0,0 -a -c -r` captures `mputest /BYTES` and `/RAW` on the card's
    MIDI OUT and `mputest_decode.py --wire` reads it.

255. **MPU status port: the idle byte by card model.** **CAPTURE-PENDING.** `pc9821_mpu.sv` and
    `tb_pc9821_mpu`, `tb_pc9821_mpu_system` and the `mputest_decode.py` selftest read the status
    port as NP2kai's MPU-PC98II (`ret = mpu98.status`: idle 0x80, bits 5-0 clear). The Xe10's own
    card, the older MPU-PC98, reads 0xBF idle and 0xFF while busy
    (`docs/probes/MPUTEST-XE10-BYTES.TXT:24` `PORT base=E0D0 st=BF dat=FE`, and its FIFOST rows),
    as the Roland MPU-401 sets bits 5-0. The core models the MPU-PC98II, which has not been
    measured (items 173 and 174). **Done when:** an MPUTEST run on an MPU-PC98II (or MPU-401)
    records the idle and busy status bytes, and the RTL and benches follow it (or the benches mask
    the status to bits 7-6 and the claim says the low six bits are NP2kai's).

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

200. **MPU-PC98 clock-to-host: where the 4-phase dither stands at each 0xE7 row.** **CAPTURE-PENDING.**
    The dither is 4-phase on the card (the probe XE10Z's MPU section: every dithered row of
    `docs/probes/XE10Z-XE10.TXT:224-230` is a rotation of NP2kai's hclk_step1 row) and `pc9821_mpu.sv` now runs it
    (`tb_pc9821_mpu_hclk`). Its ORIGIN is open: the six dithered rows start at rotations 0, 1|3,
    3, 3, 0|2, 2, so neither 0xE7 nor 0x95 restarts it, and the core keeps NP2kai's counter (one
    phase per interval, reset only at power-on, kept across 0xE7/0x95/0xFF), whose rotation from
    row to row (with the core's immediate 0x95 tick) is not the card's. Whether the card's phase
    counts intervals begun (33 or 34 per row) or keeps running while the clock is off is not
    settled by one run. **Done when:** a probe repeats one 0xE7 rate several times with 0x95
    after different idle times (and with a fixed one), and the core's phase rule follows the
    rotations it reads.

211. **YM2608 0x29 bits 4:2 and the ADPCM-B interrupts.** **UNVERIFIED (INFERRED).** The vendored
    `jt12_top.v` drops the 0x29 gate from the Timer A/B interrupt terms (a LOCAL CHANGE: the Xe10
    interrupts on both timers at 0x29 = 00 and 02, `docs/probes/YM29-XE10.TXT`, `YM29B-XE10.TXT`),
    but its `irq_mask[4:2]` still gates the ADPCM-B EOS/BRDY/ZERO flags, which no capture covers;
    NEC's SOUND.ROM writes 0x29 = 00, so a guest that then waits for an ADPCM-B interrupt gets none
    from the core. **Done when:** a ym29-style probe with ADPCM-B started and a window per 0x29
    value (00, 04, 08, 10, 1F) runs on the Xe10 and the core, and the core's IRQ12 count matches for
    every value (the gate removed as a marked LOCAL CHANGE with a fail-first bench if the machine
    does not gate, or the capture cited in the comment if it does).

243. **Speak Board (Idol Japan) as a selectable sound board.** **WORK** (after the current release).
    The board is a YM2608 at 0x188 (0x088 alternative) on INT5 with 256 KB of ADPCM-B sample RAM, a
    16 KiB option ROM at 0xCC000-0xCFFFF and one joystick port on the OPNA's I/O ports, and no
    86-PCM FIFO (MAME `src/devices/bus/pc98_cbus/speakboard.cpp`; NP2kai `cbus/boardspb.c`
    `boardspb_reset`, `boardspb_bind`). Titles with support listed by MAME: Hyper Play (PMD), Gao
    Gao 1, Ground Seed, Metal Force (its MDZS.COM driver detects the card by probing the ADPCM RAM).
    Design: an OSD choice between the PC-9801-86 and the Speak Board, one active at a time, sharing
    the one OPNA block; the ADPCM-B RAM shares the SDRAM port and region that holds the 86-PCM
    buffer (`pc9821_pcm86_buf`, the memory controller's third port), the region growing from 32 KiB
    to 256 KiB; the 86-only parts (the 0xA460-0xA46E PCM and ID ports) are off while the Speak Board
    is selected; the option ROM comes from the user's dump in the pack. The -86 plus Speak Board
    combination (two OPNAs) is out of scope. A board thought to be a reproduction is available for
    captures, once what it reproduces is confirmed. **Done when:** the board is selectable, ADPCM-B
    record/playback through registers 0x08/0x10 matches MAME/ymfm and a capture from the
    reproduction board with fail-first benches, a listed title plays its ADPCM on a card, and the
    fit holds timing.

271. **OPNA: the select latch after a 0xA460 bit-0 drop.** **WORK** (after the release). The
    key-off injected on a 0xA460 bit-0 fall (`pc9821_opna.sv` LOCAL CHANGE (B-4): select 0x10, then
    data 0xFF through the register queue) leaves the chip's address latch at 0x10, while the
    wrapper's `sel_lo` (read-back, SSG shadow, timer and flag-class decode) still holds the guest's
    last select. A data write to 0x18A with no fresh select then reaches rhythm register 0x10 on
    the chip. NP2kai's `extendchannel(0)` writes the rhythm unit directly and never touches the
    OPNA latch (`cbus/board86.c:79-94`). Rare and low severity. **Done when:** a third injected
    word re-sends `sel_lo` through address port 00 (or the bank-1 select when that was the last),
    kept inside the marked LOCAL CHANGE block and its entry in the file's list of local changes
    (`tools/check_opna_vendor_diff.py`), and a new `tb_pc9821_opna_extend` row (select 0x28, drop
    0xA460 bit 0, write data, expect chip register 0x28) fails before the change and passes after,
    with a mutation entry.
