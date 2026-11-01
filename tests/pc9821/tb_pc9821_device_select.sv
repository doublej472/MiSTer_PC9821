`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_DEVICE_SELECT: Every one of the 65,536 port addresses gets the device-bus select vector the decode it replaced produced, plus the PC-9801-118 game port: the whole 10-bit vector is compared against a fixture of the addresses that assert.
// Every one of the 65,536 port addresses gets the same device-bus select vector it got from the decode this module replaced: the whole 9-bit vector is compared against a fixture of the addresses that assert.
//
// THE CLAIM, SPLIT BY WARRANT CLASS (the fixture used to be one
// golden "captured from the expressions this module replaced", which proved refactor
// identity while reading as decode correctness). Each fixture group below carries its
// own class, re-derived against the references this pass:
//   * REFERENCE-CONFORMANT (the decode is right): the groups corroborated by
//     probes/PORTS.TXT and/or NP2kai's iocore_attach table (cited per group at the
//     fixture). These may be cited as conformance.
//   * REFACTOR-PIN (the decode did not CHANGE): the groups whose only warrant is the
//     replaced expressions' own truth table. These pin identity only and must never
//     be cited as "the decode is right".
//   * OPEN QUESTION: filed under the existing hwprobe open questions (see each
//     note) - the ranges no reference above backs.
// A RE-DERIVATION FINDING, named: NP2kai attaches 0x1E8E ("some IDE BIOSes freeze
// without it", cbus/ideio.c:2034-2040) which this decode does NOT assert ata_cs on -
// a port-level divergence from the primary reference, left open (the sweep pins the
// landed decode; closing the gap is a decode change, not a bench change).
//
// The fixture is compact because the decode is sparse: 62 addresses assert
// anything and gdc_cs, which is the complement of the rest, is checked against
// the same fixture. The sweep is exhaustive on purpose: a range predicate
// rewritten as an equality either covers exactly the same addresses or this
// fails on one of them, and it fails by printing it.
//
// The capture is of the decode as pc9821 currently has it, which is F3's base
// plus the claims pc9821 grew while F3 was on its own branch: the built-in
// IDE's second task-file mirror at 0x0740-0x074E (probes/PORTS.TXT `0740 0F ...
// 074A 0F`; F3's original capture had only 0x074C/0x074E and called the rest
// GDC), the PC-9801-86's OPNA at 0x0188-0x018E, which F3 did not decode at all,
// the same card's 86-PCM block at 0xA462-0xA46E, whose seven even ports are
// the ninth select (bit 8 of the vector; the odd partners stay open-bus device
// ports and assert nothing here), and the PC-9801-118's game port at
// 0x1480-0x1487, which is the tenth and belongs to no card this core had
// before. Each is a difference the sweep reports as a failure against the older
// fixture, which is how they were found.

module tb_pc9821_device_select;

  // ==== DUT ====
  reg  [15:0] addr;
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs, ata_cs,
       opna_cs, pcm_cs, gameport_cs, gdc_cs;
  wire mpu_cs;
  wire sdph_cs;
  // The DEVICE-BUS CLAIM: pc9821_iobus's `device_port` is this bit, so it is swept here
  // against the 85-address list iobus held before the claim (dev_bus_fixture below).
  wire dev_bus_cs;
  wire [9:0] mask = {gameport_cs, pcm_cs, pic_master_cs, pic_slave_cs, pit_cs,
                     interrupt_cs, cal_cs, kbd_cs, ata_cs, opna_cs};
  // The whole 11-bit vector, so the MPU-PC98II select is inside the fixture check rather than
  // beside it: with MPU_EN 0 it must be 0 at EVERY one of the 65,536 addresses.
  wire [10:0] mask_full = {mpu_cs, mask};

  pc9821_device_select dut (.*);

  // ==== THE SAME DECODE WITH THE MPU-PC98II PRESENT ====
  // MPU_EN 1 is what build_profile.py's mpu_en builds (every preset but trace). The claim this
  // half pins is the OPT-IN one: the card's two ports are the ONLY difference from the base decode, so at
  // every other address the two instances must agree bit for bit (gdc_cs, the complement,
  // included) - which is the static form of "the base bitstream is unchanged".
  wire pic_master_cs_on, pic_slave_cs_on, pit_cs_on, interrupt_cs_on, cal_cs_on, kbd_cs_on,
       ata_cs_on, opna_cs_on, pcm_cs_on, gameport_cs_on, gdc_cs_on, mpu_cs_on, dev_bus_cs_on;
  wire [9:0] mask_on = {gameport_cs_on, pcm_cs_on, pic_master_cs_on, pic_slave_cs_on, pit_cs_on,
                        interrupt_cs_on, cal_cs_on, kbd_cs_on, ata_cs_on, opna_cs_on};
  pc9821_device_select #(.MPU_EN(1'b1)) dut_on (
      .addr(addr),
      .pic_master_cs(pic_master_cs_on), .pic_slave_cs(pic_slave_cs_on), .pit_cs(pit_cs_on),
      .interrupt_cs(interrupt_cs_on), .cal_cs(cal_cs_on), .kbd_cs(kbd_cs_on),
      .ata_cs(ata_cs_on), .opna_cs(opna_cs_on), .pcm_cs(pcm_cs_on),
      .gameport_cs(gameport_cs_on), .mpu_cs(mpu_cs_on), .sdph_cs(), .dev_bus_cs(dev_bus_cs_on),
      .gdc_cs(gdc_cs_on)
  );

  // ==== THE SAME DECODE WITH THE SDRAM PHASE INSTRUMENT (a test-only build) ====
  // SDRAM_PHASE_DYN 1 adds exactly 0x5FF0/0x5FF2 to the device bus (sdph_cs, taken from the GDC's
  // complement) and changes nothing at any other port; with 0 (the instance above) sdph_cs is 0
  // at every one of the 65,536 ports.
  wire pic_master_cs_sp, pic_slave_cs_sp, pit_cs_sp, interrupt_cs_sp, cal_cs_sp, kbd_cs_sp,
       ata_cs_sp, opna_cs_sp, pcm_cs_sp, gameport_cs_sp, gdc_cs_sp, mpu_cs_sp, dev_bus_cs_sp,
       sdph_cs_sp;
  wire [10:0] mask_sp = {mpu_cs_sp, gameport_cs_sp, pcm_cs_sp, pic_master_cs_sp, pic_slave_cs_sp,
                         pit_cs_sp, interrupt_cs_sp, cal_cs_sp, kbd_cs_sp, ata_cs_sp, opna_cs_sp};
  pc9821_device_select #(.SDRAM_PHASE_DYN(1'b1)) dut_sp (
      .addr(addr),
      .pic_master_cs(pic_master_cs_sp), .pic_slave_cs(pic_slave_cs_sp), .pit_cs(pit_cs_sp),
      .interrupt_cs(interrupt_cs_sp), .cal_cs(cal_cs_sp), .kbd_cs(kbd_cs_sp),
      .ata_cs(ata_cs_sp), .opna_cs(opna_cs_sp), .pcm_cs(pcm_cs_sp),
      .gameport_cs(gameport_cs_sp), .mpu_cs(mpu_cs_sp), .sdph_cs(sdph_cs_sp),
      .dev_bus_cs(dev_bus_cs_sp), .gdc_cs(gdc_cs_sp)
  );
  integer sdph_hits;

  // Addresses that assert anything, with their select vector. Bit 9 is the game
  // port (its eight addresses 0x1480-0x1487), bit 8 is pcm_cs, bit 7 is
  // pic_master_cs, bit 0 is opna_cs. Every other address selects only the GDC.
  // The task file ends at 0x064E, so 0x064F is deliberately absent, the PIT
  // alias is the four ODD ports 0x3FD9..0x3FDF only, and the 86-PCM block is
  // the seven EVEN ports 0xA462..0xA46E.
  //
  // WARRANT CLASS PER GROUP (re-derived against the references):
  //   0x0000/02/08/0A (PIC pair)        REFERENCE-CONFORMANT: NP2kai's 8259 pair
  //                                     (io/i8259.c attach 0x00/02/08/0A)
  //   0x0020/22/0128 (uPD4990 calendar) REFERENCE-CONFORMANT: NP2kai io/calendar.c
  //                                     (0x20/02/128)
  //   0x0041/43 (uPD8251 keyboard)      REFERENCE-CONFORMANT: NP2kai's 8251 attach
  //   0x0071..77 odd (8253 PIT)         REFERENCE-CONFORMANT: NP2kai io/i8253.c
  //   0x3FD9..3FDF odd (PIT alias)      REFACTOR-PIN + OPEN QUESTION (the alias's
  //                                     machine evidence lives in the ioprobe ladder;
  //                                     no NP2kai attach asserts it) - hwprobe open q.
  //   0x0188..8E (PC-9801-86 OPNA)      REFERENCE-CONFORMANT: machine capture
  //                                     (probes/PORTS.TXT)
  //   0x0430/32/33/35 (IDE connection)  REFERENCE-CONFORMANT: NP2kai cbus/ideio.c
  //                                     :2009-2012/:2043-2046 attach EXACTLY these
  //                                     four (verified this pass)
  //   0x0640..6E (ATA task file block)  REFERENCE-CONFORMANT at the registers
  //                                     (NP2kai attaches 0x640 data + the even
  //                                     0x642-64E; probes/PORTS.TXT); the odd-hole
  //                                     CS coverage is the block decode = REFACTOR-PIN
  //   0x0740..7E (task-file mirror)     REFERENCE-CONFORMANT: machine capture
  //                                     (probes/PORTS.TXT `0740 0F ... 074A 0F`);
  //                                     NP2kai attaches only 0x74C/74E (verified)
  //   0x1480..87 (PC-9801-118 game)     REFERENCE-CONFORMANT: NP2kai
  //                                     cbus/board118.c:821-822 (attach loop)
  //   0xA462..6E even (86-PCM)          REFERENCE-CONFORMANT: machine capture
  //                                     (probes/PORTS.TXT) + NP2kai's pcm86 attach
  //   gdc_cs complement                 REFACTOR-PIN (the GDC gets the rest: decode
  //                                     contract identity only)
  localparam [15:0] fixture_addr [0:69] = {
    16'h0000, 16'h0002, 16'h0008, 16'h000A, 16'h0020, 16'h0022, 16'h0041, 16'h0043,
    16'h0071, 16'h0073, 16'h0075, 16'h0077, 16'h0128, 16'h0188, 16'h018A, 16'h018C,
    16'h018E, 16'h0430, 16'h0432, 16'h0433, 16'h0435, 16'h0640, 16'h0641, 16'h0642,
    16'h0643, 16'h0644, 16'h0645, 16'h0646, 16'h0647, 16'h0648, 16'h0649, 16'h064A,
    16'h064B, 16'h064C, 16'h064D, 16'h064E, 16'h0740, 16'h0741, 16'h0742, 16'h0743,
    16'h0744, 16'h0745, 16'h0746, 16'h0747, 16'h0748, 16'h0749, 16'h074A, 16'h074B,
    16'h074C, 16'h074D, 16'h074E, 16'h1480, 16'h1481, 16'h1482, 16'h1483, 16'h1484,
    16'h1485, 16'h1486, 16'h1487, 16'h3FD9, 16'h3FDB, 16'h3FDD, 16'h3FDF, 16'h0A462,
    16'h0A464, 16'h0A466, 16'h0A468, 16'h0A46A, 16'h0A46C, 16'h0A46E
  };
  localparam [9:0] fixture_mask [0:69] = {
    10'h0090, 10'h0090, 10'h0050, 10'h0050, 10'h0008, 10'h0008, 10'h0004, 10'h0004,
    10'h0030, 10'h0030, 10'h0030, 10'h0030, 10'h0008, 10'h0001, 10'h0001, 10'h0001,
    10'h0001, 10'h0002, 10'h0002, 10'h0002, 10'h0002, 10'h0002, 10'h0002, 10'h0002,
    10'h0002, 10'h0002, 10'h0002, 10'h0002, 10'h0002, 10'h0002, 10'h0002, 10'h0002,
    10'h0002, 10'h0002, 10'h0002, 10'h0002, 10'h0002, 10'h0002, 10'h0002, 10'h0002,
    10'h0002, 10'h0002, 10'h0002, 10'h0002, 10'h0002, 10'h0002, 10'h0002, 10'h0002,
    10'h0002, 10'h0002, 10'h0002, 10'h0200, 10'h0200, 10'h0200, 10'h0200, 10'h0200,
    10'h0200, 10'h0200, 10'h0200, 10'h0030, 10'h0030, 10'h0030, 10'h0030, 10'h0100,
    10'h0100, 10'h0100, 10'h0100, 10'h0100, 10'h0100, 10'h0100
  };

  localparam integer NFIX = 70;
  // ==== THE DEVICE-BUS CLAIM: THE OLD iobus LIST, VERBATIM ====
  // These 85 addresses are hit[0]..hit[84] of the pre-claim pc9821_iobus, in its own ascending
  // order, copied from that revision's pc9821_ports_pkg.sv - NOT re-derived from the shapes
  // dev_bus_cs is built from. That is what makes the sweep below a proof of the replacement
  // rather than a tautology: it is the old list's own truth table. Indices 0..82 are the ports
  // that exist with MPU_EN 0; 83/84 are the MPU-PC98II's pair, which only MPU_EN 1 asserts.
  localparam integer NDEV_MPU = 85;
  localparam integer NDEV_BASE = 83;
  localparam [15:0] dev_bus_fixture [0:84] = {
    16'h0000, 16'h0002, 16'h0008, 16'h000A, 16'h0020, 16'h0022, 16'h0041, 16'h0043,
    16'h0060, 16'h0062, 16'h0064, 16'h0068, 16'h006A, 16'h006E, 16'h0070, 16'h0071,
    16'h0072, 16'h0073, 16'h0074, 16'h0075, 16'h0076, 16'h0077, 16'h0078, 16'h007A,
    16'h007C, 16'h007E, 16'h00A0, 16'h00A1, 16'h00A2, 16'h00A3, 16'h00A4, 16'h00A5,
    16'h00A6, 16'h00A8, 16'h00A9, 16'h00AA, 16'h00AC, 16'h00AE, 16'h0128, 16'h0188,
    16'h018A, 16'h018C, 16'h018E, 16'h0430, 16'h0432, 16'h0433, 16'h0435, 16'h0640,
    16'h0641, 16'h0642, 16'h0644, 16'h0646, 16'h0648, 16'h064A, 16'h064C, 16'h064E,
    16'h0740, 16'h0742, 16'h0744, 16'h0746, 16'h0748, 16'h074A, 16'h074C, 16'h074E,
    16'h1480, 16'h1481, 16'h1482, 16'h1483, 16'h1484, 16'h1485, 16'h1486, 16'h1487,
    16'h3FD9, 16'h3FDB, 16'h3FDD, 16'h3FDF, 16'h0A462, 16'h0A464, 16'h0A466, 16'h0A468,
    16'h0A46A, 16'h0A46C, 16'h0A46E, 16'hE0D0, 16'hE0D2
  };
  // The MPU-PC98II's two ports, NP2kai cbus/mpu98ii.c:1177-1179 (the card's base and base|2).
  localparam [15:0] MPU_ADDR_0 = 16'hE0D0;
  localparam [15:0] MPU_ADDR_2 = 16'hE0D2;

  integer i, k;
  reg [9:0] exp;
  integer asserts;
  reg        exp_dev_base, exp_dev_mpu;
  reg        ata_only_lane;
  integer    hot;

  // ==== CHECKS ====
  initial begin
    asserts = 0;
    sdph_hits = 0;
    for (i = 0; i < 65536; i = i + 1) begin
      addr = i[15:0];
      #1;
      exp = 10'd0;
      for (k = 0; k < NFIX; k = k + 1)
        if (fixture_addr[k] == addr) exp = fixture_mask[k];
      if (mask != 10'd0) begin
        asserts = asserts + 1;
        // The capture line: the fixture above is this bench's own output with
        // NFIX at zero, run against the decode this module replaced.
        $display("ASSERT addr=%04x mask=%03x", addr, mask);
      end
      if (mask_full !== {1'b0, exp})
        $fatal(1, "port %04x selects %03x, the decode this module replaced selected %03x", addr, mask_full, {1'b0, exp});
      // gdc_cs is the complement of everything else, so exactly the addresses
      // that select nothing must select the GDC.
      if (gdc_cs !== (exp == 10'd0))
        $fatal(1, "port %04x: gdc_cs=%b with select vector %02x", addr, gdc_cs, exp);

      // ---- THE DEVICE-BUS CLAIM, against the pre-claim iobus list itself -------------------
      // dev_bus_cs is what pc9821_iobus's access FSM reads as `device_port`, so a port it
      // gets wrong is either strobed at a device that does not own it or never stroked at
      // all. The reference is dev_bus_fixture (the old hit[0..84] list, verbatim).
      exp_dev_base = 1'b0;
      exp_dev_mpu  = 1'b0;
      for (k = 0; k < NDEV_MPU; k = k + 1)
        if (dev_bus_fixture[k] == addr) begin
          exp_dev_mpu = 1'b1;
          if (k < NDEV_BASE) exp_dev_base = 1'b1;
        end
      if (dev_bus_cs !== exp_dev_base)
        $fatal(1, "port %04x: dev_bus_cs=%b, the pre-claim bus list says %b",
               addr, dev_bus_cs, exp_dev_base);
      if (dev_bus_cs_on !== exp_dev_mpu)
        $fatal(1, "port %04x: dev_bus_cs with MPU_EN 1 = %b, the pre-claim bus list says %b",
               addr, dev_bus_cs_on, exp_dev_mpu);
      // The defect class this cut closes: a chip select that the bus never strokes
      // ("claimed but never reached"). Every published select must imply the claim - with the
      // ONE recorded divergence this decode has always had: ata_cs's range shape covers the odd
      // task-file lanes 0x643..0x64D and 0x741..0x74D, which the bus never strokes (the ATA acts
      // on the even lanes; 0x641 is the first file's own odd register and IS presented). The claim keeps
      // ata_cs exactly as this fixture pins it and claims only the lanes the bus presents, so
      // those thirteen ports are the one place a select may sit outside the claim.
      ata_only_lane = (((addr[15:4] == 12'h064) && (addr[3:0] != 4'hF) &&
                        (addr[3:1] != 3'b000)) ||
                       ((addr[15:4] == 12'h074) && (addr[3:0] != 4'hF))) && addr[0];
      if ((pic_master_cs || pic_slave_cs || pit_cs || cal_cs || kbd_cs || ata_cs ||
           opna_cs || pcm_cs || gameport_cs || mpu_cs) && !dev_bus_cs && !ata_only_lane)
        $fatal(1, "port %04x: a chip select asserts but the device bus does not claim the port",
               addr);
      if (ata_only_lane && !ata_cs)
        $fatal(1, "port %04x: the recorded ata_cs-only lane lost its chip select", addr);
      // ... and the premise the claim's shape rests on: the leaf selects are ONE-HOT, so
      // the OR that builds dev_bus_cs cannot hide a port with two owners.
      hot = pic_master_cs + pic_slave_cs + pit_cs + cal_cs + kbd_cs + ata_cs + opna_cs +
            pcm_cs + gameport_cs + mpu_cs;
      if (hot > 1)
        $fatal(1, "port %04x: %0d chip selects assert at once", addr, hot);
      if (interrupt_cs !== (pic_master_cs | pic_slave_cs | pit_cs))
        $fatal(1, "port %04x: interrupt_cs is not the 8259/PIT OR", addr);

      // ---- the SDRAM phase instrument: off, nothing; on, exactly its two ports ----------
      if (sdph_cs !== 1'b0)
        $fatal(1, "port %04x: sdph_cs asserts with SDRAM_PHASE_DYN 0", addr);
      if ((addr == 16'h5FF0) || (addr == 16'h5FF2)) begin
        sdph_hits = sdph_hits + 1;
        if (mask_full != 11'd0 || !gdc_cs || dev_bus_cs)
          $fatal(1, "port %04x: the SDRAM phase port is not otherwise unclaimed in the base decode", addr);
        if (sdph_cs_sp !== 1'b1 || mask_sp != 11'd0 || gdc_cs_sp !== 1'b0 || dev_bus_cs_sp !== 1'b1)
          $fatal(1, "port %04x: the SDRAM phase select is not alone on the bus", addr);
      end
      else if (sdph_cs_sp !== 1'b0 || mask_sp !== mask_full || gdc_cs_sp !== gdc_cs ||
               dev_bus_cs_sp !== dev_bus_cs)
        $fatal(1, "port %04x: adding the SDRAM phase instrument changed the decode", addr);

      // ---- and the same decode with the card present --------------------------------
      if ((addr == MPU_ADDR_0) || (addr == MPU_ADDR_2)) begin
        if (mpu_cs_on !== 1'b1)
          $fatal(1, "port %04x: the MPU-PC98II select does not assert", addr);
        if (mask_on != 10'd0)
          $fatal(1, "port %04x: the MPU-PC98II select is not alone (%03x)", addr, mask_on);
        if (gdc_cs_on !== 1'b0)
          $fatal(1, "port %04x: the MPU-PC98II port still selects the GDC", addr);
      end
      else begin
        if (mpu_cs_on !== 1'b0)
          $fatal(1, "port %04x: the MPU-PC98II select asserts off its two ports", addr);
        if (mask_on !== mask)
          $fatal(1, "port %04x: adding the MPU-PC98II changed the base select vector", addr);
        if (gdc_cs_on !== gdc_cs)
          $fatal(1, "port %04x: adding the MPU-PC98II changed gdc_cs", addr);
      end
    end
    if (sdph_hits != 2)
      $fatal(1, "the SDRAM phase instrument's two ports were checked %0d times", sdph_hits);
    if (asserts != NFIX)
      $fatal(1, "%0d addresses assert a device select, the fixture lists %0d", asserts, NFIX);
    $display("DEVICE-SELECT swept=65536 asserting=%0d fixture=%0d mpu=2 devbus=85",
             asserts, NFIX);
    // ==== VERDICT ====
    $display("TB_PC9821_DEVICE_SELECT: PASS");
    $finish;
  end

  // A bench that stops making progress names itself instead of hanging the runner.
  initial begin
    #1_000_000;
    $fatal(1, "the device-select bench did not finish in 1 ms of simulated time");
  end

endmodule
