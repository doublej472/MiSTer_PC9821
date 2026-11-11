`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// The FDC model is driven through its own three ports against NP2kai io/fdc.c with a PC-9821's two drives equipped and no diskette inserted, and each command's dispatch (which opcodes take parameters and how many), its status (ST0/ST1/ST3), its interrupt, the SENSE INTERRUPT STATUS drain and the DOR read-back are compared byte for byte. The real register bugs the model had are ASSERTED and fixed: the drive/unit is parameter 0 (not the last byte), RECALIBRATE/SEEK completion is the PER-STATE class -- an equipped drive with no diskette answers SE|NR = 0x28 to RECALIBRATE, which the BIOS's drive-present probe counts as PRESENT, and a unit whose READY is never asserted answers SE|IC0|NR = 0x68 and is not counted, with the guest's forced-ready strap adding EC (SE|IC0|EC = 0x70|unit for an unequipped unit, SE = 0x20 for an equipped one), while SEEK has NP2kai FDC_Seek's single not-ready class SE|IC0|NR = 0x68|unit even under forced ready -- a data command on a drive with no diskette answers the seven-byte result with its interrupt and ST0 = IC0|NR (0x48|u, READ ID included, where NP2kai's READ ID answers ND) after an MSR of CB alone with no drive-busy bit - the real Xe10's NRID/NRRD rows (docs/probes/XE10T-XE10-FDC2C.TXT) - and SENSE INTERRUPT STATUS then answers 80, the SENSE DRIVE STATUS ST3 bits are TS/T0/HD for an equipped drive and the fault bit 0x80 for a unit the PC-9821 does not equip (drives 2/3), its WP bit is the MOUNTED MEDIUM's protect state -- the D88 header's bit 4 OR the mount's read-only flag, never "media is present" -- the parameter-phase MSR is RQM|CB, the DOR read is NP2kai's computed 0x44, and the 0x92 idle byte is the MACHINE's 0x80 (R10.TXT/PORTS.TXT), not NP2kai's zeroed lastdata. The reference deviations this model KEEPS by design are printed as WAIVED, not asserted: the seven eight-parameter commands no target game issues (0x02/0x05/0x09/0x0C and the three SCANs 0x11/0x19/0x1D), its explicit ST_EXEC MSR for FORMAT, and the absent media/data phase. The MSR read-back is pinned bit for bit against fdc.status (fdc_i90 returns it verbatim): the low nibble carries one drive-busy bit per unit from the command's claim to the result drain (set fdc.c:562-563/300-302/111-113, cleared fdc.c:907-909) and bit 5 NDM tracks the SPECIFY ND latch (fdc.c:265) over a data command's transfer window (fdc.c:450-454) -- FAIL-FIRST: the model answered 0x90/0xD0/0x80 only and 7 of the 12 new cases mismatched.
//
// The FDC model is driven through its own three ports against NP2kai io/fdc.c with a PC-9821's two drives equipped and no diskette inserted, and each command's dispatch (which opcodes take parameters and how many), its status (ST0/ST1/ST3), its interrupt, the SENSE INTERRUPT STATUS drain and the DOR read-back are compared byte for byte. The real register bugs the model had are ASSERTED and fixed: the drive/unit is parameter 0 (not the last byte), RECALIBRATE/SEEK completion is SE|IC0|NR (0x68) -- the drive-not-ready class qemu's PC-98 handler answers when no diskette is inserted -- so the BIOS's probe does not count an unusable drive, a data command on a drive with no diskette answers the seven-byte result with its interrupt and ST0 = IC0|NR (0x48|u, READ ID included, where NP2kai's READ ID answers ND) after an MSR of CB alone with no drive-busy bit - the real Xe10's NRID/NRRD rows (docs/probes/XE10T-XE10-FDC2C.TXT) - and SENSE INTERRUPT STATUS then answers 80, the SENSE DRIVE STATUS ST3 bits are TS/T0/HD for an equipped drive and the fault bit 0x80 for a unit the PC-9821 does not equip (drives 2/3), the parameter-phase MSR is RQM|CB, the DOR read is NP2kai's computed 0x44, and the 0x92 idle byte is the MACHINE's 0x80 (R10.TXT/PORTS.TXT), not NP2kai's zeroed lastdata. The reference deviations this model KEEPS by design are printed as WAIVED, not asserted: the seven eight-parameter commands no target game issues (0x02/0x05/0x09/0x0C and the three SCANs 0x11/0x19/0x1D), its explicit ST_EXEC MSR for FORMAT, and the absent media/data phase. The MSR read-back is pinned bit for bit against fdc.status (fdc_i90 returns it verbatim): the low nibble carries one drive-busy bit per unit from the command's claim to the result drain (fdc.c:562-563/300-302/111-113 set, 907-909 clear) and bit 5 NDM tracks the SPECIFY ND latch (fdc.c:265) over a data command's transfer window (fdc.c:450-454).

module tb_pc9821_fdc_conform;

  // ==== DUT ====
  reg clk = 0;
  always #5 clk = ~clk;   // 100 MHz, the same clk_sys the fit uses
  reg reset = 1;
  reg cs = 0, wr = 0, rd = 0;
  reg [1:0] addr = 0;
  reg [7:0] din = 0;
  wire [7:0] dout;
  wire irq;
  wire       strap_2hd;

  pc9821_fdc dut (
      .clk(clk), .reset(reset), .cs(cs), .addr(addr),
      // Module-level: every access below is the 2HD window (0x90-0x94), so
      // win_2dd = 0; the strap output is watched, not driven.
      .win_2dd(1'b0), .strap_2hd(strap_2hd),
      .wr(wr), .rd(rd), .din(din), .dout(dout), .irq(irq),
      .media_present(2'b00), .writeprotect(wp),
      // No media-change tag: this bench's mounts are not ready changes (pc9821_fdc's media_chg).
      .media_chg(4'd0), .frame_tick(1'b0),
      .media_req(), .media_req_hdr(), .media_unit(),
      .media_c(), .media_h(), .media_tc(), .media_hd(), .media_mf(), .media_2hd(), .media_rpm(), .media_r(), .media_n(), .media_idx(),
      .media_ready(1'b1), .media_rdy(1'b0), .media_hdrv(1'b0), .media_err(1'b0),
      .media_dout(8'h00), .media_hr(8'h00), .media_hn(8'h00), .media_hs(8'h00),
      .media_adv(), .dma_drq(), .dma_dack(1'b0), .dma_stb(1'b0), .dma_tc(1'b0),
      .dma_dout()
  );

  integer errors = 0, cases = 0, waivers = 0;
  integer i, n;
  reg [7:0] g_msr, g_b0, g_b1, g_sis0, g_sis1, g_dor;
  reg [3:0] wp = 4'b0000;    // the mounted medium's write-protect state (an FDC input)
  integer g_len, g_irq, g_sislen, g_data;
  reg [7:0] rb [0:7];

  // The bound: a stuck DUT cannot outlast this, and the run block $finishes well inside it.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_FDC_CONFORM: TIMEOUT");
  end

  // ==== STIMULUS ====
  // NP2kai io/fdc.c is the oracle; every expectation names its handler below. The
  // reference configuration is the PC-9821 one: fdc.equip has both drives, no diskette
  // is inserted (fdd_diskready() false), chgreg=3 (2HD) and ctrlreg has no force-ready
  // bit (0x40). qemu hw/block/pc98-fdc.c is cited where it agrees or differs.

  task automatic wr8(input [1:0] a, input [7:0] d);
    begin
      @(negedge clk); cs = 1; addr = a; wr = 1; rd = 0; din = d;
      @(posedge clk);
      @(negedge clk); cs = 0; wr = 0;
    end
  endtask

  // Sample while rd is asserted: the model's read data is combinational from the
  // result index, and the posedge advances that index (the iobus S_BYTE contract).
  task automatic rd8(input [1:0] a, output [7:0] d);
    begin
      @(negedge clk); cs = 1; addr = a; wr = 0; rd = 1;
      #1 d = dout;
      @(posedge clk);
      @(negedge clk); cs = 0; rd = 0;
    end
  endtask

  task automatic reset_dut;
    begin
      reset = 1; repeat (4) @(negedge clk);
      reset = 0; repeat (2) @(negedge clk);
    end
  endtask

  task automatic get_msr; begin rd8(2'd0, g_msr); end endtask
  task automatic get_dor; begin rd8(2'd2, g_dor); end endtask
  task automatic cmd(input [7:0] op); begin wr8(2'd1, op); end endtask
  task automatic param(input [7:0] p); begin wr8(2'd1, p); end endtask

  // Drain the COMMAND's own result phase (DIO set after the command), not SIS.
  task automatic get_result;
    begin
      g_len = 0;
      for (i = 0; i < 8; i = i + 1) rb[i] = 8'hFF;
      rd8(2'd0, g_msr);
      while (((g_msr & 8'h40) != 0) && (g_len < 8)) begin
        rd8(2'd1, rb[g_len]);
        g_len = g_len + 1;
        rd8(2'd0, g_msr);
      end
      g_b0 = rb[0]; g_b1 = rb[1];
    end
  endtask

  // SENSE INTERRUPT STATUS: write 0x08 and drain its one or two bytes.
  task automatic get_sis;
    begin
      g_sislen = 0; g_sis0 = 8'hFF; g_sis1 = 8'hFF;
      cmd(8'h08);
      rd8(2'd0, g_msr);
      while (((g_msr & 8'h40) != 0) && (g_sislen < 2)) begin
        if (g_sislen == 0) rd8(2'd1, g_sis0); else rd8(2'd1, g_sis1);
        g_sislen = g_sislen + 1;
        rd8(2'd0, g_msr);
      end
    end
  endtask

  task automatic wait_irq(input integer maxc);
    begin
      g_irq = 0; n = 0;
      while (!irq && n < maxc) begin @(negedge clk); n = n + 1; end
      if (irq) g_irq = 1;
    end
  endtask

  // NP2kai FDCCMD_TABLE[op]: the parameter bytes each opcode's dispatcher waits for.
  // An entry of 0 means the opcode runs at once (invalid -> 0x80 result, or SIS).
  function automatic [3:0] ref_params(input [4:0] op);
    begin
      case (op)
        5'h02: ref_params = 4'd8;   // FDC_Ope[2]=FDC_ReadData, table 8 (qemu READ TRACK, 8)
        5'h03: ref_params = 4'd2;   // SPECIFY
        5'h04: ref_params = 4'd1;   // SENSE DRIVE STATUS
        5'h05: ref_params = 4'd8;   // WRITE DATA
        5'h06: ref_params = 4'd8;   // READ DATA
        5'h07: ref_params = 4'd1;   // RECALIBRATE
        5'h09: ref_params = 4'd8;   // WRITE DELETED DATA (FDC_WriteData)
        5'h0A: ref_params = 4'd1;   // READ ID
        5'h0C: ref_params = 4'd8;   // READ DELETED DATA (FDC_ReadData)
        5'h0D: ref_params = 4'd5;   // WRITE ID / FORMAT
        5'h0F: ref_params = 4'd2;   // SEEK
        5'h11: ref_params = 4'd8;   // SCAN EQUAL (SUPPORT_KAI_IMAGES; qemu 8)
        5'h19: ref_params = 4'd8;   // SCAN LOW OR EQUAL (qemu 8)
        5'h1D: ref_params = 4'd8;   // SCAN HIGH OR EQUAL (qemu 8)
        default: ref_params = 4'd0;
      endcase
    end
  endfunction

  // The reference dispatchers this model deliberately does NOT implement: no target game
  // issues them (READ TRACK 0x02, WRITE DELETED 0x09, READ DELETED 0x0C, SCAN 0x11/0x19/
  // 0x1D; WRITE DATA 0x05 is NP2kai's FDC_WriteData). They answer the one-byte invalid
  // result like any other unimplemented opcode, so their bench cases are WAIVED.
  function automatic ref_unimplemented(input [4:0] op);
    begin
      case (op)
        5'h02, 5'h05, 5'h09, 5'h0C,
        5'h11, 5'h19, 5'h1D: ref_unimplemented = 1'b1;
        default: ref_unimplemented = 1'b0;
      endcase
    end
  endfunction

  // ==== CHECKS ====
  task automatic check(input [8*34-1:0] name, input [7:0] got, input [7:0] want);
    begin
      cases = cases + 1;
      if (got !== want) begin
        $display("MISMATCH %0s: rtl=0x%02x np2kai=0x%02x", name, got, want);
        errors = errors + 1;
      end else $display("ok       %0s = 0x%02x", name, got);
    end
  endtask

  task automatic check_dispatch(input [5:0] op, input [7:0] got, input [7:0] want);
    begin
      cases = cases + 1;
      if (got !== want) begin
        $display("MISMATCH dispatch_%02x: rtl=%0d np2kai=%0d", op, got, want);
        errors = errors + 1;
      end else $display("ok       dispatch_%02x = %0d", op, got);
    end
  endtask

  // A reference value this model does not adopt by design: PRINT it and count a waiver.
  // There is nothing to assert when the shape is intentionally different.
  task automatic waive(input [8*34-1:0] name, input [7:0] got, input [7:0] want);
    begin
      cases = cases + 1;
      waivers = waivers + 1;
      $display("WAIVED   %0s: rtl=0x%02x np2kai=0x%02x", name, got, want);
    end
  endtask

  task automatic waive_dispatch(input [5:0] op, input [7:0] got, input [7:0] want);
    begin
      cases = cases + 1;
      waivers = waivers + 1;
      $display("WAIVED   dispatch_%02x: rtl=%0d np2kai=%0d (unimplemented opcode)", op, got, want);
    end
  endtask

  initial begin
    // ---- reset/idle: fdcstatusreset() leaves RQM; fdc_i94 answers a computed 0x44 ----
    reset_dut();
    get_msr;  check("msr_reset", g_msr, 8'h80);
    // 0x92 idle: the MACHINE reads 0x80 (R10.TXT five snapshots, PORTS.TXT, EMS.TXT);
    // NP2kai's fdc_i92 returns its ZeroMemory'd lastdata = 0x00. The capture is the
    // reference here, so the expectation is 0x80.
    rd8(2'd1, g_b0); check("data_reset", g_b0, 8'h80);
    get_dor;  check("dor_reset", g_dor, 8'h44);

    // ---- command dispatch: does the opcode wait for parameters? -------------------
    // NP2kai's fdc_datawrite sets CB and, when FDCCMD_TABLE[data & 0x1f] is nonzero,
    // enters FDCEVENT_CMDRECV waiting for that many parameter bytes. This model's
    // cmd_params() decides the same thing. DIO clear after the opcode means "waiting".
    for (i = 0; i < 32; i = i + 1) begin
      reset_dut();
      cmd(i[7:0]);
      get_msr;
      if (ref_unimplemented(i[4:0]))
        waive_dispatch(i[5:0], ((g_msr & 8'h40) == 0) ? 8'd1 : 8'd0,
                       (ref_params(i[4:0]) != 4'd0) ? 8'd1 : 8'd0);
      else
        check_dispatch(i[5:0], ((g_msr & 8'h40) == 0) ? 8'd1 : 8'd0,
                       (ref_params(i[4:0]) != 4'd0) ? 8'd1 : 8'd0);
    end

    // ---- SPECIFY (0x03): FDC_Specify takes 2 parameters, then is NEUTRAL, no IRQ ----
    reset_dut();
    cmd(8'h03); get_msr; check("specify_msr_param", g_msr, 8'h90);
    param(8'hAF); param(8'h03);
    wait_irq(200);
    get_msr; check("specify_msr_after", g_msr, 8'h80);
    check("specify_irq", g_irq, 8'd0);

    // ---- SENSE DRIVE STATUS (0x04): FDC_SenseDeviceStatus -> ST3 ------------------
    // equip bit set: |0x08 TS, |0x10 T0 when treg==0, |0x20 RDY only when
    // fdd_diskready() (or ctrlreg force-ready), |0x40 WP; dis-equipped -> |0x80.
    // ST3 answers the DRIVE-STATE question (present / not ready / fault), NOT the
    // last command's termination question ST0 answers: 0x18 here alongside ST0's
    // 0x68 is the documented two-register contract (see the RECALIBRATE block's
    // "ST0 vs ST3" note), not a contradiction.
    reset_dut();
    cmd(8'h04); param(8'h00);
    get_result;
    check("st3_len", g_len[7:0], 8'd1);
    check("st3_drive0", g_b0, 8'h18);
    wait_irq(200); check("st3_irq", g_irq, 8'd0);

    reset_dut();
    cmd(8'h04); param(8'h01); get_result;
    check("st3_drive1", g_b0, 8'h19);

    reset_dut();
    cmd(8'h04); param(8'h04); get_result;         // head 1, drive 0
    check("st3_head1_drive0", g_b0, 8'h1C);

    // ST3's WP BIT IS THE MEDIUM'S PROTECT STATE, not "media is present" (Stage A: the D88
    // header's bit 4 OR the mount's read-only flag, NP2kai io/fdc.c:370-372). FAIL-FIRST:
    // while WP came from media_present this byte was 0x18 with no media either way, so these
    // two arms are what separate "writable medium" from "protected medium" - and the second
    // one pins that the flag is PER DRIVE, not a global.
    reset_dut();
    wp = 4'b0001;                                   // unit 0's medium is write-protected
    cmd(8'h04); param(8'h00); get_result;
    check("st3_wp_unit0", g_b0, 8'h58);           // TS|T0 | WP
    reset_dut();
    wp = 4'b0010;                                   // the OTHER drive's flag
    cmd(8'h04); param(8'h00); get_result;
    check("st3_wp_other_unit", g_b0, 8'h18);      // unit 0 is writable
    reset_dut();
    wp = 4'b0000;                                   // writable medium: WP clear
    cmd(8'h04); param(8'h00); get_result;
    check("st3_wp_clear", g_b0, 8'h18);

    // The machine's strap equips drives 0/1 only. A unit that is not there answers
    // the ST3 fault bit 0x80 instead of TS/T0 (NP2kai fdc.c:281-283, qemu
    // hw/block/pc98-fdc.c:2234) -- the byte that stops the BIOS's probe marking a
    // phantom drive present (BANK7 0xFF716 tests ST0's 0xC0, not this, but the
    // media check reads ST3 per drive).
    reset_dut();
    cmd(8'h04); param(8'h02); get_result;
    check("st3_unequipped_drive2", g_b0, 8'h82);
    reset_dut();
    cmd(8'h04); param(8'h03); get_result;
    check("st3_unequipped_drive3", g_b0, 8'h83);

    // RECALIBRATE (0x07): 1 parameter, deferred interrupt, SIS reports ST0 ------
    // THE PER-STATE ST0 (the plan's W1/W2), NP2kai FDC_Recalibrate, io/fdc.c:592-628:
    //   an equipped drive with no diskette -> SE|NR = 0x28 (or SE = 0x20 under the
    //     guest's forced-ready strap, :613-621);
    //   a unit whose READY is never asserted -> SE|IC0|NR = 0x68|unit (or SE|IC0|EC =
    //     0x70|unit under the forced-ready strap, :604-611).
    // The IC bits are what the PC-98 BIOS's drive-present probe tests, so 0x28 MARKS a
    // drive present and 0x68 does not: `test byte [0x564+unit*8],0xC0` -> `or
    // [0x55C],al` (BANK7 0xFF716), 0x55C accumulating one bit per unit.
    //
    // BOTH EQUIPPED DRIVES ANSWER 0x28|unit WHEN EMPTY (NP2kai :613-621).
    // The Xe10 captures' [0x55C] = 0x01 (docs/probes/itf-paired-7287bed6/*/
    // D2{COLD,WARM}.TXT) were taken with drive 1 UNPOWERED, so they measure a dead
    // drive and are not the expected value here; a powered re-capture is todo item 59.
    //
    // ST0 vs ST3 IS NOT A CONTRADICTION once the two registers' questions are kept
    // apart (the row C2 named): ST0 reports the COMMAND's termination class
    // (IC0 = abnormal, SE = ready changed, NR = not ready), while ST3 reports the
    // DRIVE's physical state (present / not ready / no fault, and the fault bit 0x80
    // for a unit the machine does not equip). An equipped drive with no diskette is
    // physically present and faultless (ST3 TS/T0/HD, no 0x80) AND its RECALIBRATE
    // reports NR; a phantom unit reports ST3 0x80 and ST0 0x68|unit.
    reset_dut();
    cmd(8'h07); get_msr; check("recal_msr_param", g_msr, 8'h90);
    param(8'h00);
    // The waive is the ST_EXEC byte class (F8); the 0x81 want carries NP2kai's
    // drive-busy bit (fdc.c:562-563), which the busy-nibble block below asserts.
    get_msr; waive("recal_msr_after", g_msr, 8'h81);
    wait_irq(3000); check("recal_irq", g_irq, 8'd1);
    get_sis;
    check("recal_sis_len", g_sislen[7:0], 8'd2);
    check("recal_st0", g_sis0, 8'h28);          // unit 0: SE|NR, IC clear
    check("recal_st1", g_sis1, 8'h00);

    // Unit 1, equipped and empty: the same SE|NR class as unit 0 (NP2kai :613-621), so the
    // BIOS's probe marks it present.
    reset_dut();
    cmd(8'h07); param(8'h01);
    wait_irq(3000); check("recal_unit1_irq", g_irq, 8'd1);
    get_sis;
    check("recal_unit1_st0", g_sis0, 8'h29);     // unit 1: SE|NR, IC clear

    // RECALIBRATE to a unit that is not there: both references answer SE|IC0|NR
    // (NP2kai fdc.c:520-526, qemu pc98-fdc.c:2259) = 0x68|unit, so the BIOS's probe
    // sees the 0xC0 bits set and does NOT mark it present (BANK7 0xFF716).
    reset_dut();
    cmd(8'h07); param(8'h02);
    wait_irq(3000); check("recal_unequipped_irq", g_irq, 8'd1);
    get_sis;
    check("recal_unequipped_st0", g_sis0, 8'h6A);
    check("recal_unequipped_st1", g_sis1, 8'h00);

    // THE PRESENT MASK THE PROBE BUILDS, from all four units' answers in one session
    // (BANK7 0xFF70E-0xFF728): OR in 1<<unit only when BOTH IC bits are clear. The
    // four bytes are 0x2N for units 0-1 and 0x6N for units 2-3, so the mask is 0x03 -
    // NP2kai's two-drive byte, and the acceptance test for this whole block. Each
    // byte is checked and folded into the mask IMMEDIATELY, because get_sis uses
    // g_sis0/g_sis1/g_msr as its own scratch and the next call clobbers them.
    reset_dut();
    g_dor = 8'h00;
    cmd(8'h07); param(8'h00); wait_irq(3000); get_sis;
    check("mask_unit0_st0", g_sis0, 8'h28);
    if (g_sis0[7:6] == 2'b00) g_dor = g_dor | 8'h01;
    cmd(8'h07); param(8'h01); wait_irq(3000); get_sis;
    check("mask_unit1_st0", g_sis0, 8'h29);
    if (g_sis0[7:6] == 2'b00) g_dor = g_dor | 8'h02;
    cmd(8'h07); param(8'h02); wait_irq(3000); get_sis;
    check("mask_unit2_st0", g_sis0, 8'h6a);
    if (g_sis0[7:6] == 2'b00) g_dor = g_dor | 8'h04;
    cmd(8'h07); param(8'h03); wait_irq(3000); get_sis;
    check("mask_unit3_st0", g_sis0, 8'h6b);
    if (g_sis0[7:6] == 2'b00) g_dor = g_dor | 8'h08;
    check("present_mask_55C", g_dor, 8'h03);

    // THE GUEST'S FORCED-READY STRAP (`fdc.ctrlreg & 0x40`, the DOR's bit 6 - NP2kai
    // fdc.c:367 and the two arms above). An UNEQUIPPED unit then answers SE|IC0|EC =
    // 0x70|unit - EC, not NR - and an EQUIPPED one takes the success path (SE = 0x20).
    reset_dut();
    wr8(2'd2, 8'h40);                             // no reset: bit 4 unmoved, bit 7 not a 0->1
    cmd(8'h07); param(8'h02);
    wait_irq(3000); check("recal_forced_unequipped_irq", g_irq, 8'd1);
    get_sis;
    check("recal_forced_unequipped_st0", g_sis0, 8'h72);   // us|SE|IC0|EC
    reset_dut();
    wr8(2'd2, 8'h40);
    cmd(8'h07); param(8'h00);
    wait_irq(3000); check("recal_forced_equipped_irq", g_irq, 8'd1);
    get_sis;
    check("recal_forced_equipped_st0", g_sis0, 8'h20);     // us|SE, no NR (:613-621)

    // ---- SEEK (0x0F): 2 parameters, no media -> the same per-state classes -------
    reset_dut();
    cmd(8'h0F); param(8'h00); param(8'h28);
    get_msr; waive("seek_msr_after", g_msr, 8'h81);   // 0x81 = 0x80 | (1<<us), fdc.c:773-779
    wait_irq(3000); check("seek_irq", g_irq, 8'd1);
    get_sis;
    // unit 0: SE|IC0|NR. NP2kai FDC_Seek: `if (!fdd_diskready(fdc.us))
    // fdc.int_stat[fdc.us] |= FDCRLT_IC0 | FDCRLT_NR;` - no equip / forced-ready arms (those
    // are FDC_Recalibrate's; the old 0x28 here cited Recalibrate's lines).
    check("seek_st0", g_sis0, 8'h68);
    check("seek_st1", g_sis1, 8'h00);

    // The drive is parameter 0 (get_hdus); the NCN is parameter 1. Driving the low
    // bits of NCN as the unit exposes a dispatcher that takes the unit from the last
    // byte instead.
    reset_dut();
    cmd(8'h0F); param(8'h00); param(8'h2A);
    wait_irq(3000);
    get_sis;
    check("seek_st0_ncn2a", g_sis0, 8'h68);
    // ... and to unit 1, equipped and empty: the same SE|IC0|NR class (FDC_Seek).
    reset_dut();
    cmd(8'h0F); param(8'h01); param(8'h2A);
    wait_irq(3000);
    get_sis;
    check("seek_st0_unit1", g_sis0, 8'h69);
    // ... and with the guest's forced-ready strap: FDC_Seek has no forced-ready arm, so an
    // equipped empty drive is still SE|IC0|NR and its track register does not move.
    reset_dut();
    wr8(2'd2, 8'h40);
    cmd(8'h0F); param(8'h00); param(8'h2A);
    wait_irq(3000);
    get_sis;
    check("seek_forced_equipped_st0", g_sis0, 8'h68);
    check("seek_forced_equipped_pcn", g_sis1, 8'h00);

    // ---- A BYTE WRITTEN WHILE MSR SAYS "RQM, host to FDC" IS TAKEN ------------------
    // The uPD765 handshake: the host may write the data register whenever MSR shows RQM=1
    // with DIO=0, and the byte is then the FDC's. NP2kai ends SEEK/RECALIBRATE's command
    // phase at once (FDC_Seek: `fdc.status |= FDCSTAT_RQM; fdc.status &= ~FDCSTAT_CB;`) and
    // takes the next command. A driver that issues SEEK and then a SENSE INTERRUPT STATUS on
    // the first (MSR & 0xC0) == 0x80 must get a result phase - never a silently dropped byte.
    reset_dut();
    cmd(8'h0F); param(8'h00); param(8'h2A);
    n = 0;
    get_msr;
    while (((g_msr & 8'hC0) != 8'h80) && n < 5000) begin get_msr; n = n + 1; end
    cmd(8'h08);                                   // on the first RQM-and-host-to-FDC MSR
    n = 0;
    get_msr;
    while (((g_msr & 8'h40) == 0) && n < 5000) begin get_msr; n = n + 1; end
    check("seek_then_sis_result_phase", g_msr & 8'hC0, 8'hC0);
    if ((g_msr & 8'h40) != 0) begin
      rd8(2'd1, g_sis0);
      check("seek_then_sis_st0", g_sis0, 8'h68);
      rd8(2'd1, g_sis1);
    end

    // ---- SENSE INTERRUPT STATUS with nothing pending: one byte, 0x80, no interrupt ---
    reset_dut();
    get_sis;
    check("sis_empty_len", g_sislen[7:0], 8'd1);
    check("sis_empty_byte", g_sis0, 8'h80);
    check("sis_empty_irq", irq, 8'd0);

    // ---- READ DATA (0x06): FDC_ReadData, 8 parameters -----------------------------
    // No media: FDC_DriveCheck fails -> stat = IC0|NR|hd<<2|us = 0x48, then
    // fdcsend_error7 delivers a SEVEN-byte result {ST0,ST1,ST2,C,H,R,N} and raises
    // the interrupt. THE MACHINE agrees on the shape and the bytes, and its MSR reads CB alone
    // (10, no busy bit) before the result's D0: docs/probes/XE10T-XE10-FDC2C.TXT:59 (`NRRD
    // da=90 ... msr0=10 msr_end=D0 ... sis=80 dmacnt=03FF nres=7 st0=48 st1=00`), so the MSR is
    // the machine's here, not NP2kai's D1.
    reset_dut();
    cmd(8'h06); get_msr; check("read_data_msr_param", g_msr, 8'h90);
    for (i = 0; i < 8; i = i + 1) param(i == 3 ? 8'h01 : (i == 4 ? 8'h02 :
                                          (i == 5 ? 8'h08 : (i == 6 ? 8'h1B :
                                          (i == 7 ? 8'hFF : 8'h00)))));
    get_msr; check("read_data_msr_after_params", g_msr, 8'h10);    // NRRD msr0=10
    wait_irq(3000); check("read_data_irq", g_irq, 8'd1);
    get_result;
    check("read_data_result_len", g_len[7:0], 8'd7);
    check("read_data_st0", g_b0, 8'h48);
    check("read_data_st1", g_b1, 8'h00);
    get_sis;
    check("read_data_sis_len", g_sislen[7:0], 8'd1);
    check("read_data_sis0", g_sis0, 8'h80);

    // READ DATA with MF=1 (0x46): the low-five-bit local fix, still 8 parameters.
    reset_dut();
    cmd(8'h46); get_msr; check("read_data_mf_msr_param", g_msr, 8'h90);
    for (i = 0; i < 8; i = i + 1) param(8'h00);
    wait_irq(3000); check("read_data_mf_irq", g_irq, 8'd1);

    // ---- READ ID (0x0A): FDC_ReadID, 1 parameter ---------------------------------
    // NP2kai: fdd_readid() fails with no image -> stat = us|(hd<<2)|IC0|ND (ND is ST1 bit 2),
    // error7 -> 7-byte result {0x40,0x04,0x00,C,H,R,N} plus interrupt. THE MACHINE keeps the
    // shape but answers the not-ready class, ST0 = IC0|NR = 0x48|u with ST1 = 0, after an MSR of
    // CB alone: docs/probes/XE10T-XE10-FDC2C.TXT:57 (`NRID da=90 ... msr0=10 msr_end=D0 ... sis=80
    // dmacnt=FFFF nres=7 st0=48 st1=00`); the capture outranks NP2kai's bytes.
    reset_dut();
    cmd(8'h0A); param(8'h00);
    get_msr; check("readid_msr_after_params", g_msr, 8'h10);   // NRID msr0=10
    wait_irq(3000); check("readid_irq", g_irq, 8'd1);
    get_result;
    check("readid_result_len", g_len[7:0], 8'd7);
    check("readid_st0", g_b0, 8'h48);                          // NRID st0=48 (NP2kai 0x40)
    check("readid_st1", g_b1, 8'h00);                          // NRID st1=00 (NP2kai 0x04)
    get_sis;
    check("readid_sis_len", g_sislen[7:0], 8'd1);
    check("readid_sis0", g_sis0, 8'h80);

    // ---- FORMAT / WRITE ID (0x0D): FDC_WriteID, 5 parameters ----------------------
    // get_hdus reads parameter 0; parameter 4 is the filler byte D. No media ->
    // FDC_DriveCheck(true) fails -> error7, 7-byte result {0x48,0,0,C,H,R,N}.
    reset_dut();
    cmd(8'h0D); get_msr; check("format_msr_param", g_msr, 8'h90);
    param(8'h00); param(8'h02); param(8'h09); param(8'h00); param(8'hE5);
    get_msr; waive("format_msr_after_params", g_msr, 8'hD1);   // error7 result, fdc.c:111-113
    wait_irq(3000); check("format_irq", g_irq, 8'd1);
    get_result;
    check("format_result_len", g_len[7:0], 8'd7);
    check("format_st0", g_b0, 8'h48);
    get_sis;
    check("format_sis_len", g_sislen[7:0], 8'd1);
    check("format_sis0", g_sis0, 8'h80);

    // The FORMAT data phase: with media, FDC_WriteID enters FDCEVENT_BUFRECV and the
    // guest feeds a 4-byte {C,H,R,N} block per sector (fdd_formating), SC of them. No
    // media path and no sector block exist here.
    reset_dut();
    waive("format_sector_block_bytes", 8'd0, 8'd4);
    waive("write_data_data_phase", 8'd0, 8'd1);

    // ---- WRITE DATA (0x05): FDC_WriteData, 8 parameters ---------------------------
    // A reference command no target game issues: the model answers the invalid result,
    // so the reference's FDC_DriveCheck/eight-parameter/error7 shape is WAIVED.
    reset_dut();
    cmd(8'h05);
    get_msr; waive("write_msr_after_opcode", g_msr, 8'h90);
    get_result;
    waive("write_result_len", g_len[7:0], 8'd7);
    waive("write_result_st0", g_b0, 8'h48);
    wait_irq(3000); waive("write_irq", g_irq, 8'd1);

    // ---- an unimplemented opcode answers 0x80 with no interrupt (both agree) --------
    reset_dut();
    cmd(8'h00);
    get_msr; check("invalid00_msr", g_msr, 8'hD0);
    get_result; check("invalid00_byte", g_b0, 8'h80);
    wait_irq(200); check("invalid00_irq", g_irq, 8'd0);

    // ---- DOR/0x94: NP2kai fdc_i94 computes its answer, it does not read a latch ----
    reset_dut();
    wr8(2'd2, 8'h00);
    get_dor; check("dor_after_write", g_dor, 8'h44);

    // ---- the interrupt is level and clears when SIS drains the pending status -------
    reset_dut();
    cmd(8'h07); param(8'h00);
    wait_irq(3000);
    get_sis;
    check("irq_clears_on_sis", irq, 8'd0);

    // ---- the MSR low nibble: one drive-busy bit per unit ------
    // NP2kai's fdc.status carries (1 << us) from the command's claim point until
    // the result that carries the status drains: RECALIBRATE/SEEK set it at their
    // CMDRECV arm (fdc.c:562-563, 773-774), SENSE DRIVE STATUS at its result
    // build (fdc.c:300-302) and the interrupt sends at theirs (fdc.c:111-113,
    // 148-150); fdc_dataread's BUFSEND drain clears it (fdc.c:907-909). The MSR
    // read returns fdc.status verbatim (fdc.c:1035-1043), so those bits are the
    // MSR low nibble. FAIL-FIRST: the model answered 0x90/0xD0/0x80 only.
    reset_dut();
    cmd(8'h07); param(8'h00);
    wait_irq(3000); check("busy_recal_irq", g_irq, 8'd1);
    get_msr; check("busy_msr_completed", g_msr, 8'h81);       // 0x80 | (1<<0): fdc.c:562-563, 572-573
    cmd(8'h08); get_msr; check("busy_msr_sis_result", g_msr, 8'hD1);  // the nibble survives &= 0x0f (fdc.c:583-584)
    rd8(2'd1, g_b0); rd8(2'd1, g_b1);                          // drain ST0, PCN
    get_msr; check("busy_msr_after_drain", g_msr, 8'h80);      // fdc.c:907-909

    // The bit is (1 << us) even for a unit the machine does not equip: RECAL to
    // unit 2 sets bit 2 (fdc.c:562-563 takes fdc.us unconditionally).
    reset_dut();
    cmd(8'h07); param(8'h02);
    wait_irq(3000); check("busy_recal_u2_irq", g_irq, 8'd1);
    get_msr; check("busy_msr_recal_u2", g_msr, 8'h84);
    get_sis;
    get_msr; check("busy_msr_u2_drained", g_msr, 8'h80);

    // SENSE DRIVE STATUS claims its drive for the ST3 result (fdc.c:300-302)
    // and the one-byte result's drain releases it (fdc.c:907-909).
    reset_dut();
    cmd(8'h04); param(8'h01);
    get_msr; check("busy_msr_sds_result", g_msr, 8'hD2);       // 0xD0 | (1<<1)
    rd8(2'd1, g_b0);
    get_msr; check("busy_msr_sds_drained", g_msr, 8'h80);

    // NP2kai's fdcsend_error7 sets the drive's bit for a not-ready data command
    // (fdc.c:111-112). THE MACHINE sets none for READ ID (or READ DATA): its MSR reads 10, not
    // 11, straight after the command and D0 with the result (XE10T-XE10-FDC2C.TXT:57, `NRID da=90
    // ... msr0=10 msr_end=D0`), the uPD765A datasheet's busy bits being seek-mode only.
    reset_dut();
    cmd(8'h0A); param(8'h00);
    get_msr; check("busy_readid_accept_nib", {4'b0, g_msr[3:0]}, 8'h00);

    // ---- MSR bit 5 NDM: the SPECIFY ND latch ------------------
    // NP2kai latches ND from SPECIFY's second parameter (fdc.c:265) and ORs
    // FDCSTAT_NDM into fdc.status EXACTLY while a data command transfers in
    // non-DMA mode (fdc.c:362-366 write, 450-454 read, 686-690 format: `if
    // (fdc.nd) fdc.status |= FDCSTAT_NDM`), clearing it at every command/result
    // boundary (fdc.c:270-271, 907-909). ND=0 transfers never set it. The
    // model's execution state is where that transfer window lives, so NDM is
    // asserted there for READ DATA/FORMAT only - RECALIBRATE/SEEK have no
    // transfer window in NP2kai and never carry NDM (fdc.c:562-573), and after
    // SPECIFY itself MSR stays 0x80 (fdc.c:270-271, already pinned above).
    reset_dut();
    cmd(8'h03); param(8'hAF); param(8'h02);                     // SPECIFY, ND=0
    cmd(8'h06); for (i = 0; i < 8; i = i + 1) param(8'h00);
    get_msr; check("ndm_read_data_nd0", {7'b0, g_msr[5]}, 8'd0);
    reset_dut();
    cmd(8'h03); param(8'hAF); param(8'h03);                     // SPECIFY, ND=1
    cmd(8'h06); for (i = 0; i < 8; i = i + 1) param(8'h00);
    get_msr; check("ndm_read_data_nd1", {7'b0, g_msr[5]}, 8'd1);
    reset_dut();
    cmd(8'h03); param(8'hAF); param(8'h03);
    cmd(8'h0D); param(8'h00); param(8'h02); param(8'h09); param(8'h00); param(8'hE5);
    get_msr; check("ndm_format_nd1", {7'b0, g_msr[5]}, 8'd1);
    reset_dut();
    cmd(8'h03); param(8'hAF); param(8'h03);
    cmd(8'h07); param(8'h00);
    get_msr; check("ndm_recal_absent", {7'b0, g_msr[5]}, 8'd0);

    // ==== VERDICT ====
    $display("NOTE fdc_conform: %0d cases, %0d mismatched, %0d waived",
             cases, errors, waivers);
    if (errors == 0) begin
      $display("TB_PC9821_FDC_CONFORM: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_FDC_CONFORM: FAIL (%0d of %0d cases)", errors, cases);
  end
endmodule
