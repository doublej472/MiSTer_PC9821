`timescale 1ns/1ps

// The SDRAM chip model, in ONE home: `sdram_chip_model` is instantiated by every bench that
// drives src/memory/sdram.v against a device and needs the pins to mean something. It was
// extracted from tb_pc9821_sdram.sv when the TDM bench (tb_pc9821_sdram_tdm.sv) became the
// second consumer, so the two cannot drift about what a READ returns or when.
//
// Its first job is data consistency: the same pins address the same location on a write and a
// read. Its second is the device's command protocol, checked with $fatal on every bench:
// a READ or WRITE to a bank with no open row, an ACTIVATE to an open bank, an AUTO REFRESH or a
// MODE REGISTER SET while a bank is open, and a WRITE issued while this chip drives DQ with read
// data (bus contention). Its third, when the bench passes FREQ_HZ, is the AC timing of the
// supported module's datasheet (Alliance AS4C32M16SB datasheet Rev 1.4, Table 16, the -6 or -7
// column by GRADE), derived from nanoseconds at the bench's own clock rather than from the
// controller's cycle constants: tRCD, tRP (from the real start of each precharge), tRAS (for an
// explicit PRECHARGE and for both auto-precharge forms), tRC, tRRD, tRFC and tMRD. The datasheet
// promises no tRAS lockout for auto-precharge, so the model places the implied precharge where
// the datasheet does: a READ with auto-precharge begins it one clock (the burst length, 1) after
// the READ ("any subsequent command cannot occur within a time delay of {tRP(min.) + burst
// length}"), a WRITE with auto-precharge tWR after its data ("{(burst length -1) + tWR +
// tRP(min.)}"); tWR is taken in nanoseconds, the earliest the device may begin.
//
// A 128 MB module is two chips on complementary chip selects (docs/sdram.md): a bench models it
// with two instances, CHIP_SEL 0 (selected by nCS low) and CHIP_SEL 1 (selected by nCS high).

module sdram_chip_model #(
    // The chip's own CAS latency, in cycles. JEDEC SDR: the read data of a READ command
    // appears CAS (the latency the MRS programmed) clocks after the command, on the pins,
    // independent of when the controller samples it. Two is what sdram.v declares below
    // 100 MHz (CAS_I = 2 below 100 MHz, 3 at 100 MHz and up): a bench at 100 MHz or more
    // passes 3.
    parameter integer CAS = 2,
    // The transfer appears CAS cycles after the controller asserts the READ command.
    // The model tracks the pipeline depth implied by that datasheet statement (one in-flight
    // transfer per CAS stage) and no more: if the controller ever samples at the wrong edge,
    // the data will not be there and the BENCH fails -- the model must not be fitted to the
    // controller's sampling point (it previously was, and that is how F1-class bugs hide).
    parameter integer LATENCY = CAS,
    // tRP / tWR in cycles for the cycle-count precharge check, which runs ONLY when FREQ_HZ is 0
    // (no datasheet AC checks). A bench that passes FREQ_HZ is judged on tRP from nanoseconds
    // instead (pre_done), and these are ignored: a fixed cycle count cannot follow the clock
    // (two clocks of tWR is 40 ns at 50 MHz, against the datasheet's 14 ns), so at a low clock it
    // rejects an ACT that Table 16 allows.
    parameter integer T_RP = 2,
    parameter integer T_WR = 2,
    // Longest tolerated gap, in cycles, between AutoRefresh commands seen on the pins.
    // 0 disables the check. tREFI is 64ms/8192 rows; a dropped refresh shows up
    // as a gap of a whole counter wrap past the next attempt.
    parameter integer REFRESH_INTERVAL = 0,
    // The bench's clock in Hz. 0 leaves the datasheet AC checks off (the protocol checks above
    // always run); a bench that passes its clock gets every one of them.
    parameter integer FREQ_HZ = 0,
    // The speed grade whose Table 16 column the AC checks use: 6 or 7.
    parameter integer GRADE = 7,
    // The chip select level that selects this chip: 0 = nCS low (a single chip, or chip 0 of a
    // 128 MB module), 1 = nCS high (chip 1, whose CS is the inverse of chip 0's on the board).
    parameter integer CHIP_SEL = 0
) (
    input               clk,
    inout      [15:0]   DQ,
    input      [12:0]   A,
    input      [1:0]    BA,
    input               nRAS,
    input               nCAS,
    input               nWE,
    input               nCS
);
    // A consistent store keyed by the pins the controller drives (its data is not a device's
    // analog behaviour; the header lists the protocol and AC rules it does check).
    localparam [2:0] CMD_MRS = 3'b000,
                     CMD_REF = 3'b001,
                     CMD_PRE = 3'b010,
                     CMD_ACT = 3'b011,
                     CMD_WR  = 3'b100,
                     CMD_RD  = 3'b101,
                     CMD_NOP = 3'b111;

    wire       chip_sel = (CHIP_SEL != 0) ? nCS : !nCS;
    wire [2:0] cmd = chip_sel ? {nRAS, nCAS, nWE} : CMD_NOP;

    // ---- Datasheet AC parameters (Alliance AS4C32M16SB datasheet Rev 1.4, Table 16) ----
    // ns, minimum, -6 / -7: tRC 60/63, tRFC 60/63, tRCD 18/21, tRP 18/21, tRRD 12/14,
    // tMRD 12/14, tRAS 42/42, tWR 12/14.
    localparam integer DS_TRC  = (GRADE == 6) ? 60 : 63;
    localparam integer DS_TRFC = (GRADE == 6) ? 60 : 63;
    localparam integer DS_TRCD = (GRADE == 6) ? 18 : 21;
    localparam integer DS_TRP  = (GRADE == 6) ? 18 : 21;
    localparam integer DS_TRRD = (GRADE == 6) ? 12 : 14;
    localparam integer DS_TMRD = (GRADE == 6) ? 12 : 14;
    localparam integer DS_TRAS = 42;
    localparam integer DS_TWR  = (GRADE == 6) ? 12 : 14;
    localparam bit     AC_ON   = (FREQ_HZ > 0);
    initial if ((GRADE != 6) && (GRADE != 7))
        $fatal(1, "sdram_chip_model: GRADE is %0d; Table 16 has the -6 and -7 columns only", GRADE);
    // `cycles` clocks at FREQ_HZ last at least `ns` nanoseconds: cycles / FREQ_HZ >= ns * 1e-9,
    // compared exactly in integers (no rounded clock period).
    function automatic bit ac_ok(input longint cycles, input integer ns);
        ac_ok = (cycles * 64'd1_000_000_000) >= (longint'(ns) * longint'(FREQ_HZ));
    endfunction
    // Clocks since an event, counted on this chip's own clk (`now` is this edge).
    longint now = 0;
    always @(posedge clk) now <= now + 1;
    longint act_at   [0:3];             // the bank's last ACTIVATE
    longint pre_at   [0:3];             // when the bank's precharge BEGINS (see pre_kind)
    integer pre_kind [0:3];             // 0 none, 1 PRECHARGE/READ-A (pre_at is that clock), 2 WRITE-A (pre_at + tWR)
    longint act_any  = -64'd1000;       // the chip's last ACTIVATE, any bank (tRRD)
    longint ref_at   = -64'd1000;       // the last AUTO REFRESH (tRFC)
    longint mrs_at   = -64'd1000;       // the last MODE REGISTER SET (tMRD)
    // The bank's precharge has completed by `t`: tRP after the clock it began, or, for a WRITE
    // with auto-precharge, tWR + tRP after the WRITE.
    function automatic bit pre_done(input integer b, input longint t);
        if (pre_kind[b] == 0)      pre_done = 1'b1;
        else if (pre_kind[b] == 2) pre_done = ac_ok(t - pre_at[b], DS_TWR + DS_TRP);
        else                       pre_done = ac_ok(t - pre_at[b], DS_TRP);
    endfunction

    // The MiSTer/XSDS tie: the chip's LDQM/UDQM are wired to the connector's A[11]/A[12]
    // (docs/sdram.md, "DQM wiring"). A WRITE captures the mask with its data, so the model samples
    // A[12:11] on the WRITE command edge; a masked-off byte keeps its stored value. Reads are
    // never masked by this core (A[12:11]=00 on READ), so the read side needs no DQM here.
    wire [1:0] wr_dqm = A[12:11];   // {UDQM, LDQM}, active high

    reg [4095:0] seen_bank;                     // banks the model has activated
    reg [15:0]   mem [0:33554431];
    // Set when the controller issues a MODE REGISTER SET. CAS latency and burst type come
    // from that register, so a controller that skipped it would be running on the device's
    // power-on default while every timing check in this bench still passed.
    reg          mrs_seen = 0;

    // The row open PER BANK, as a real device holds it: an ACTIVATE opens one bank's row and
    // it stays open until a PRECHARGE closes it. The earlier single latch held only the last
    // ACTIVATE, which was correct only while the controller auto-precharged every access --
    // exactly what the predicted open-row policy stops doing. An ACTIVATE to a bank
    // whose row is still open with no precharge is a protocol violation and is fatal.
    reg [12:0] row_a [0:3];
    reg  [3:0] row_v = 4'b0000;                 // this bank holds an open row

    // Per-bank precharge countdown (the tRP check). A PRECHARGE / auto-precharge starts the
    // bank's internal precharge; while this is non-zero the bank is PRECHARGING and an ACT to
    // it is fatal -- JEDEC tRP is a hard PRE-to-ACT minimum per bank. Loaded to (duration-1)
    // so the countdown reads 0 on the first cycle the bank is legally ready again:
    //   READ-A  : the internal precharge starts CAS-1 after the READ command (it overlaps the
    //             burst's data-out), so the bank is ready (CAS-1)+tRP after it.
    //   WRITE-A : tWR after the last data-in (BL=1: the WRITE command edge itself), then tRP.
    //   PRE     : tRP after the PRECHARGE command.
    // The controller's own row-split ACT path encodes the same read rule (it waits for full
    // data drain -- the read-data-completion reading is one cycle stricter still -- before its
    // second ACT), which is exactly what a pre-ACT guard missing it fails to do.
    // With FREQ_HZ set this countdown is not checked: pre_done (tRP from the precharge's real
    // start, in nanoseconds) is the datasheet's rule and replaces it.
    reg  [4:0] pre_left [0:3];
    localparam [31:0] PRE_TICKS_RD   = (CAS - 1) + T_RP - 1;
    localparam [31:0] PRE_TICKS_WR   = T_WR + T_RP - 1;
    localparam [31:0] PRE_TICKS_PRE  = T_RP - 1;
    integer  p;
    initial begin
        for (p = 0; p < 4; p = p + 1) pre_left[p] = 5'd0;
        for (p = 0; p < 4; p = p + 1) begin
            act_at[p] = -64'd1000; pre_at[p] = -64'd1000; pre_kind[p] = 0;
        end
        ref_gap  = 32'd0;
        ref_seen = 1'b0;
        cbr_seen = 0;
    end

    // AutoRefresh interval bookkeeping. ref_gap counts the cycles since
    // the previous AutoRefresh on this chip; a gap over REFRESH_INTERVAL means a pending
    // refresh was dropped or starved past the device's retention interval. cbr_seen counts
    // every AutoRefresh ever seen, because the INIT ones are a requirement of their own:
    // AS4C32M16SB datasheet Rev 1.4 Note 11 (Power up Sequence) -- "A minimum of 2 Auto-Refresh
    // dummy cycles must be required to stabilize the internal circuitry", with the Mode Register
    // Set in the same sequence. A controller that under-inits passes every DATA check and then
    // misbehaves only on real silicon, so the first ACTIVATE closes the account: fewer than 2
    // refreshes, or no MODE REGISTER SET, before it is fatal here (per chip select).
    reg [31:0] ref_gap;
    reg        ref_seen;
    integer    cbr_seen;

    // Read pipeline: each READ command returns exactly one 16-bit half, CAS cycles
    // later. sdram.v's READ comment is explicit: "Issue length-1 READ commands every
    // cycle after T_RCD. Each READ returns one 16-bit half."
    reg      rd_v [0:LATENCY-1];
    reg [15:0] rd_word [0:LATENCY-1];
    integer  i;

    reg [15:0] dq_out_r;
    reg [15:0] bus_data;
    reg        dq_oen_r;

    // A reduction over an UNPACKED array is not legal, so the burst-active term is
    // computed explicitly: the bus is driven while ANY transfer is in flight.
    integer  k;
    reg      any_rd;
    always @* begin
        any_rd = 1'b0;
        for (k = 0; k < LATENCY; k = k + 1) any_rd = any_rd | rd_v[k];
    end
    // bus_data latches the newest transfer, so the last one stays valid while the
    // pipeline drains instead of the bus going to zero under a late sample.
    // Combinational drive: a device holds DQ for the whole burst, and the registered
    // version added a cycle that neither the device nor the controller's dq_r
    // accounting has -- which the cycle-by-cycle trace showed as the high half
    // being captured as the completion of the previous word.
    assign DQ = any_rd ? (rd_v[LATENCY-1] ? rd_word[LATENCY-1] : bus_data) : 16'hZZZZ;

    // The location, as an injective function of (row, bank, column) where column is the
    // low 10 bits A carries during an access -- the field both the write and the read
    // put there. The upper A bits during an access are auto-precharge and the burst's
    // last-half flag, not address.
    wire [24:0] key_w = {BA, row_a[BA], A[9:0]};
    // THE KEY WIDTH IS LOAD-BEARING. This was stored as mem[key_w[15:0]], which throws
    // away the top 8 bits -- BOTH BANK BITS and the top 6 row bits -- so two addresses
    // differing only in their bank aliased to one cell. That is not a tidiness problem:
    // it is exactly the field the geometry decode moves, so with the truncation in place
    // NO check could tell a correct decode from a wrong one, which is why the geometry
    // has been 'reported, not asserted' since this bench was written. The comment above
    // already claimed injectivity; the index now delivers it. 32MB of simulation memory
    // is a fair price for being able to test aliasing at all. It then took a SECOND
    // truncation: key_w dropped row_a[BA][12] of the 13-bit row, so rows 0x000 and 0x1000
    // aliased and a controller that wrapped its row counter at 12 bits shared the model's
    // blind spot and read back 'correctly' (bench-circularity audit entry 5). The key is
    // now the FULL (bank, row, column) triple -- 25 bits -- so no geometry-decode or
    // row-carry bug can hide inside the fixture's own aliasing.

    always @(posedge clk) begin
        // Shift the read pipeline; the command seen this cycle emerges CAS later.
        for (i = LATENCY-1; i > 0; i = i - 1) begin
            rd_v[i]    <= rd_v[i-1];
            rd_word[i] <= rd_word[i-1];
        end
        rd_v[0]    <= 1'b0;
        rd_word[0] <= 16'h0000;

        // Age every bank's precharge countdown; a command's load below overrides this.
        for (i = 0; i < 4; i = i + 1)
            if (pre_left[i] != 5'd0) pre_left[i] <= pre_left[i] - 5'd1;

        // tMRD: no command until the mode register write has completed (Table 16 tMRD; the
        // datasheet's MRS description: "Two clock cycles are required to complete the write").
        if (AC_ON && (cmd != CMD_NOP) && !ac_ok(now - mrs_at, DS_TMRD))
            $fatal(1, "sdram_chip_model%0d: command %b %0d clock(s) after MODE REGISTER SET (tMRD %0d ns)",
                   CHIP_SEL, cmd, now - mrs_at, DS_TMRD);
        // tRFC: no ACTIVATE, AUTO REFRESH or MODE REGISTER SET inside a refresh cycle.
        if (AC_ON && ((cmd == CMD_ACT) || (cmd == CMD_REF) || (cmd == CMD_MRS)) && !ac_ok(now - ref_at, DS_TRFC))
            $fatal(1, "sdram_chip_model%0d: command %b %0d clock(s) after AUTO REFRESH (tRFC %0d ns)",
                   CHIP_SEL, cmd, now - ref_at, DS_TRFC);

        if (cmd == CMD_ACT) begin
            if (cbr_seen < 2)
                $fatal(1, "sdram_chip_model%0d: ACTIVATE after only %0d init AUTO REFRESH cycles (AS4C32M16SB datasheet Note 11 requires >= 2)",
                       CHIP_SEL, cbr_seen);
            if (!mrs_seen)
                $fatal(1, "sdram_chip_model%0d: ACTIVATE before any MODE REGISTER SET (AS4C32M16SB datasheet Note 11)", CHIP_SEL);
            if (row_v[BA])
                $fatal(1, "sdram_chip_model: ACTIVATE to bank %0d whose row is still open (a precharge was skipped)", BA);
            if (!AC_ON && (pre_left[BA] != 5'd0))
                $fatal(1, "sdram_chip_model: ACTIVATE to bank %0d %0d cycle(s) before its precharge completed (tRP violated)",
                       BA, pre_left[BA]);
            if (AC_ON && !pre_done(BA, now))
                $fatal(1, "sdram_chip_model%0d: ACTIVATE to bank %0d before its precharge completed (tRP %0d ns from the precharge's start)",
                       CHIP_SEL, BA, DS_TRP);
            if (AC_ON && !ac_ok(now - act_at[BA], DS_TRC))
                $fatal(1, "sdram_chip_model%0d: ACTIVATE to bank %0d %0d clock(s) after its previous ACTIVATE (tRC %0d ns)",
                       CHIP_SEL, BA, now - act_at[BA], DS_TRC);
            if (AC_ON && !ac_ok(now - act_any, DS_TRRD))
                $fatal(1, "sdram_chip_model%0d: ACTIVATE %0d clock(s) after another bank's ACTIVATE (tRRD %0d ns)",
                       CHIP_SEL, now - act_any, DS_TRRD);
            seen_bank[BA] <= 1'b1;
            row_a[BA]     <= A;
            row_v[BA]     <= 1'b1;
            act_at[BA]    = now;
            act_any       = now;
        end else if (cmd == CMD_PRE) begin
            // tRAS on an explicit PRECHARGE of an open bank: "This command can be asserted
            // anytime after tRAS(min.) is satisfied from the BankActivate command".
            // Every bank it names starts tRP here ("Precharge to refresh/row activate command").
            for (i = 0; i < 4; i = i + 1)
                if (A[10] || (BA == i[1:0])) begin
                    if (AC_ON && row_v[i] && !ac_ok(now - act_at[i], DS_TRAS))
                        $fatal(1, "sdram_chip_model%0d: PRECHARGE of bank %0d %0d clock(s) after its ACTIVATE (tRAS %0d ns)",
                               CHIP_SEL, i, now - act_at[i], DS_TRAS);
                    pre_at[i] = now; pre_kind[i] = 1;
                end
            if (A[10]) begin
                row_v <= 4'b0000;               // precharge every bank
                for (i = 0; i < 4; i = i + 1) pre_left[i] <= PRE_TICKS_PRE[4:0];
            end else begin
                row_v[BA]    <= 1'b0;           // precharge the selected bank
                pre_left[BA] <= PRE_TICKS_PRE[4:0];
            end
        end else if (cmd == CMD_WR) begin
            if (!row_v[BA])
                $fatal(1, "sdram_chip_model%0d: WRITE to bank %0d, which has no open row", CHIP_SEL, BA);
            if (AC_ON && !ac_ok(now - act_at[BA], DS_TRCD))
                $fatal(1, "sdram_chip_model%0d: WRITE to bank %0d %0d clock(s) after its ACTIVATE (tRCD %0d ns)",
                       CHIP_SEL, BA, now - act_at[BA], DS_TRCD);
            // DQ contention: the controller drives the write data on this edge, so this chip must
            // not be outputting read data now or have any still to come.
            if (any_rd)
                $fatal(1, "sdram_chip_model%0d: WRITE while this chip still drives (or will drive) read data on DQ (bus contention)",
                       CHIP_SEL);
            // Apply the byte mask carried on A[12:11] (active high): a masked byte keeps its
            // stored value, an unmasked byte takes DQ. With A[12:11]=00 this is a full word write,
            // which is what the DQM-less RMW and gather paths drive.
            mem[key_w] <= {wr_dqm[1] ? mem[key_w][15:8] : DQ[15:8],
                           wr_dqm[0] ? mem[key_w][7:0]  : DQ[7:0]};
            if (A[10]) begin
                // tRAS: the implied precharge begins tWR after this data ("{(burst length -1) +
                // tWR + tRP(min.)}"), and the datasheet promises no tRAS lockout for it.
                if (AC_ON && !ac_ok(now - act_at[BA], DS_TRAS - DS_TWR))
                    $fatal(1, "sdram_chip_model%0d: WRITE with auto-precharge to bank %0d %0d clock(s) after its ACTIVATE: the precharge would begin tWR (%0d ns) later, inside tRAS (%0d ns)",
                           CHIP_SEL, BA, now - act_at[BA], DS_TWR, DS_TRAS);
                row_v[BA]    <= 1'b0;           // auto-precharge on the last half closes it
                pre_left[BA] <= PRE_TICKS_WR[4:0];   // ... and starts tWR + tRP
                pre_at[BA] = now; pre_kind[BA] = 2;
            end
        end else if (cmd == CMD_RD) begin
            if (!row_v[BA])
                $fatal(1, "sdram_chip_model%0d: READ of bank %0d, which has no open row", CHIP_SEL, BA);
            if (AC_ON && !ac_ok(now - act_at[BA], DS_TRCD))
                $fatal(1, "sdram_chip_model%0d: READ of bank %0d %0d clock(s) after its ACTIVATE (tRCD %0d ns)",
                       CHIP_SEL, BA, now - act_at[BA], DS_TRCD);
            rd_v[0]    <= 1'b1;
            rd_word[0] <= mem[key_w];
            if (A[10]) begin
                // tRAS: the implied precharge begins one clock (the burst length) after the READ
                // ("{tRP(min.) + burst length}"), with no tRAS lockout.
                if (AC_ON && !ac_ok(now + 1 - act_at[BA], DS_TRAS))
                    $fatal(1, "sdram_chip_model%0d: READ with auto-precharge of bank %0d %0d clock(s) after its ACTIVATE: the precharge would begin inside tRAS (%0d ns)",
                           CHIP_SEL, BA, now - act_at[BA], DS_TRAS);
                row_v[BA]    <= 1'b0;
                pre_left[BA] <= PRE_TICKS_RD[4:0];   // read auto-precharge: starts CAS-1 later
                pre_at[BA] = now + 1; pre_kind[BA] = 1;
            end
        end else if (cmd == CMD_MRS) begin
            if (row_v != 4'b0000)
                $fatal(1, "sdram_chip_model%0d: MODE REGISTER SET while bank(s) %b are open", CHIP_SEL, row_v);
            for (i = 0; i < 4; i = i + 1)
                if (AC_ON && !pre_done(i, now))
                    $fatal(1, "sdram_chip_model%0d: MODE REGISTER SET before bank %0d's precharge completed (tRP)", CHIP_SEL, i);
            mrs_seen <= 1'b1;
            mrs_at   = now;
        end else if (cmd == CMD_REF) begin
            // "AUTO REFRESH while one or more banks are active" is illegal, and the banks'
            // precharges must have completed (tRP before a refresh, Table 16's tRP).
            if (row_v != 4'b0000)
                $fatal(1, "sdram_chip_model%0d: AUTO REFRESH while bank(s) %b are open", CHIP_SEL, row_v);
            for (i = 0; i < 4; i = i + 1)
                if (AC_ON && !pre_done(i, now))
                    $fatal(1, "sdram_chip_model%0d: AUTO REFRESH before bank %0d's precharge completed (tRP %0d ns)",
                           CHIP_SEL, i, DS_TRP);
            ref_at = now;
        end

        // The AutoRefresh interval: a device needs one refresh per row per 64ms,
        // i.e. one AutoRefresh every tREFI on average. A gap over REFRESH_INTERVAL means the
        // controller dropped or starved a pending refresh.
        if (cmd == CMD_REF) begin
            if (ref_seen && (REFRESH_INTERVAL > 0) && (ref_gap > REFRESH_INTERVAL))
                $fatal(1, "sdram_chip_model: %0d cycles since the last AutoRefresh (limit %0d): a pending refresh was dropped or starved",
                       ref_gap, REFRESH_INTERVAL);
            ref_seen  <= 1'b1;
            ref_gap   <= 32'd1;
            cbr_seen  <= cbr_seen + 1;
        end else if (ref_seen) begin
            ref_gap <= ref_gap + 32'd1;
        end

        // Drive the pins the way a device does: DQ is valid from CAS cycles after each
        // READ and STAYS valid until the burst is over. A real SDRAM does not pulse the
        // bus for one cycle per transfer, and sdram.v samples through a registered dq_r,
        // so a one-cycle pulse loses every second half -- which is exactly the symptom
        // the first draft produced (a written word read back as 5a5a0000).
        if (rd_v[LATENCY-1]) bus_data <= rd_word[LATENCY-1];
    end
endmodule
