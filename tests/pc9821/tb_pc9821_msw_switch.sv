`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_MSW_SWITCH: the OSD's ONE remaining HARDWARE-SWITCH field (Boot order) is latched
// on the machine-reset strobe and WRITTEN INTO the text-VRAM switch cell then, so the board's
// boot/FDD switch stops being a snapshot of one machine - and the 0xA3FEA BASE-MEMORY cell
// stays HARDCODED at 640 KB, because the real machine has no way to change it.
//
// THE CELLS AND WHY THE FDD NIBBLE IS A SWITCH AND THE BASE MEMORY IS NOT. The eight
// memory-switch cells at 0xA3FE2 + i*4 are the board's physical switch bank mirrored into the
// text-VRAM tail (NP2kai bios/biosmem.h MEMB_MSW1..8). The authentic firmware reads the two
// fields this bench drives and writes neither of them:
//
//   0xA3FF2 bits 7:4  the boot/FDD nibble, read by the BIOS's own boot helper and handed
//                     to port 0x00BE (the FDC's channel-group register):
//                     BANK7@0x598C-0x59A9  mov bx,0xa000 / mov es,bx / mov ah,[es:0x3ff2]
//                                          / and ah,0xF0 / jz -> keep / cmp ah,0x20 -> 0
//                                          / cmp ah,0x40 -> 3 / out 0xBE,al
//                     NP2kai bios.c:254   `boot = mem[MEMB_MSW5] & 0xf0; if (boot != 0x20)
//                                         { // 1MB } else { // 640KB }`
//                     NP2kai bios1b.c:883-926, the boot-device reading of the same nibble:
//                                         0x00 normal / 0x20 640KB FDD / 0x40 1.2MB FDD /
//                                         0x60 MO / 0xa0 SASI 1 / 0xb0 SASI 2 / 0xc0 SCSI
//                     The measured machine's byte is 0x01, i.e. nibble 0 - the `jz` class, the
//                     one where the BIOS keeps the mode the controller itself reports.
//
//   0xA3FEA bits 2:0  the base-memory size, read by the ITF's own memory walk as a count of
//                     64 KB units and by NP2kai's info paths as (n+1)*128 KB:
//                     BANK4@0x5C33-0x5C46 mov al,[es:0x3fea] / and al,7 / inc al / shl al,1
//                                          / cmp dh,al
//                     NP2kai generic/np2info.c:113-120  `memsize = np2cfg.memsw[2] & 7;
//                                          if (memsize < 6) memsize = (memsize+1) * 128;`
//                     The measured machine's byte is 0x0C, i.e. bits 2:0 = 4 = 640 KB - and
//                     this is the ONLY conventional size the machine can have: its SETUP menu
//                     carries no base-memory item (the complete item list was decoded),
//                     and NP2kai takes the value from
//                     the memory-switch cell, not from a guest setting. The core therefore
//                     HARDCODES it (pc9821_crtc's MSW_BASEM_CODE = 4) and this bench asserts
//                     the cell stays 0x0C at every reset, whatever the FDD field does.
//
// NO WRITER EXISTS IN THE ROM SET: the only writes to those two cells are the ITF's
// `or byte es:[0x3FEA],8` marker (BANK4@0x1D15) and the dormant PCI bank's
// `and byte [es:0x3FF2],0x0F` (BANK0@0x1205), both OUTSIDE the fields above. A switch the
// guest cannot set is a switch the core has to set at reset, which is what this bench pins.
//
// THE CONTRACT, step by step:
//   (a) entry 0 - the FDD nibble 0, which is exactly what a card with no config file passes -
//       seeds 0xA3FF2 with 0x01 (byte for byte the pc9821_dpram INIT_BYTES literal already
//       carries) and leaves 0xA3FEA at its hardcoded 0x0C (640 KB);
//   (b) a machine reset with the FDD field moved seeds the nibble the references name:
//       FDD position 1 -> the 0x20 the BIOS compares against (top nibble 2, the low nibble 1
//       the dormant PCI bank's mask preserves), and 0xA3FEA stays 0x0C - the hardcode holds;
//   (c) A MID-RUN CHANGE MOVES NOTHING: with the strobe released, the port flipped to a
//       different selection leaves 0xA3FF2 at the byte step (b) left and 0xA3FEA at 0x0C,
//       cycle after cycle;
//   (d) the NEXT machine reset applies the FDD selection (0x41) and 0xA3FEA is still 0x0C;
//   (e) a reset back on entry 0 restores the measured bytes - the field is not sticky;
//   (f) EVERY LEGAL ENCODING ROUND-TRIPS: positions 0..6 seed the nibble the references name
//       for each - 0x0 the measured board (BANK7@0x5999 `jz`), 0x20/0x40 the two values the
//       authentic BIOS's boot helper compares against (BANK7@0x599B/0x59A0), 0x60/0xa0/0xb0/
//       0xc0 NP2kai bios1b.c:883-926's boot-device codes (MO / SASI 1 / SASI 2 / SCSI) - and
//       the one position the CONF_STR list does NOT offer (FDD 7) decodes to the measured
//       machine, so a hand-edited config file cannot ask for a machine nobody captured. At
//       every one of these, 0xA3FEA is asserted 0x0C - the hardcoded base memory;
//   (g) the seed is a reset-time WRITE, not a read override: with MODE FF1 bit 6 set (the
//       cells' own write enable, pc9821_text_mem's tram_msw_cell gate) a guest write still lands
//       and reads back.
//
// THE BOOT-DEVICE CODES ARE NP2kai's, AND THE MACHINE DIVERGES - STATED, NOT IMPLIED. The
// real Xe10 firmware does not select a boot device from this nibble: its boot helper compares
// only 0x20/0x40 and keeps the FDC's own reported mode otherwise (BANK7@0x599B-0x59A3), and
// NP2kai's own switch comment (bios1b.c:883 `うぐぅ…本当はALレジスタの値から`) says the value
// should really arrive in the AL register - on real hardware the caller passes the boot device
// in AL/AH (bios1b.c:843-875). The bench pins the SEED - the switch position and the byte the
// firmware finds in the cell - not a claim that a captured Xe10 boots MO/SASI/SCSI from it.
//
// FAIL-FIRST: on the wiring before this change the cell is the fixed INIT_BYTES snapshot and
// the port reaches nothing, so step (b) reads 0x01 instead of 0x21 and the bench fails there
// by name. On the THREE-ENTRY decode this change replaces (positions 3..6 unmapped, the field
// two bits wide) the round-trip loop at step (f) fails: positions 3-6 seed the measured 0x01
// where the references' boot-device codes 0x61/0xA1/0xB1/0xC1 belong.
//
// THE MANIFEST'S CLAIM, word for word (one line, so the checker's whitespace-normalised match sees it):
// The OSD's ONE hardware-switch field of the P1 DIP Switch page (Boot order = the memory-switch cell 0xA3FF2's high nibble) arrives as a LIST POSITION, is latched inside pc9821_crtc on the same machine-reset strobe the machine-ID and GDC-clock straps use, and is WRITTEN into that text-VRAM cell then, while the 0xA3FEA base-memory cell is HARDCODED to the measured 640 KB (code 4) and stays 0x0C at every reset: position 0 is the MEASURED machine - the 0x00 FDD nibble, which the authentic BIOS's boot helper treats as its `jz` class (BANK7@0x598C-0x5999) - and it seeds 0x3FF2 = 0x01 and 0x3FEA = 0x0C, byte for byte the INIT_BYTES literal a config-less card already got, while every legal Boot order encoding round-trips to the nibble the references name: position 1 = the 0x20 the authentic BIOS compares against at BANK7@0x599B, 2 = the 0x40 of BANK7@0x59A0, 3/4/5/6 = NP2kai bios1b.c:883-926's boot-device codes 0x60/0xa0/0xb0/0xc0 (MO / SASI 1 / SASI 2 / SCSI), seeding 0x21/0x41/0x61/0xA1/0xB1/0xC1 with the non-field bits preserved (0x3FF2's low nibble, which the dormant PCI bank's `and byte [es:0x3ff2],0x0F` at BANK0@0x1205 keeps), and 0x3FEA's hardcoded 0x0C keeps its bit 3 (the ITF's own `or byte es:[0x3FEA],8` marker at BANK4@0x1D15); a MID-RUN change to the port moves neither cell - the FDD cell keeps the latched nibble and the base-memory cell keeps 0x0C across any number of cycles, because the field is latched on the strobe and applied at reset, so the board's switch cannot move under the running firmware - and only the next machine reset applies the new selection (position 2 -> 0x41), with a reset back on entry 0 restoring 0x01/0x0C; a position the CONF_STR list does NOT offer (FDD 7) decodes to that measured machine rather than to one nobody captured; and the seed is a reset-time WRITE and not a read-side override, so a guest write still lands when the cells' own write enable (MODE FF1 bit 6, pc9821_text_mem's tram_msw_cell gate) is set. Fail-first: on the fixed-snapshot wiring the cell never leaves the INIT byte and the bench fails at step (b), and on the three-entry decode the round-trip loop at step (f) fails - positions 3-6 seed the measured 0x01 where the boot-device codes belong.

module tb_pc9821_msw_switch;
  reg clk_sys = 0;
  always #5 clk_sys = ~clk_sys;

  // The machine-reset / reload strobe: pc9821_system drives pc9821_crtc's rst_n_sys with
  // `!(reset || !cpu_run)`, which is the same event pc9821_iobus latches the straps on.
  reg  rst_n_sys = 1'b0;
  // The ONE OSD field as the core passes it: the LIST POSITION, not the encoded switch value
  // (pc9821_crtc decodes). Entry 0 is the measured machine - the 0x00 FDD nibble - which is
  // what this bench starts on and what an undriven port means. The base memory is hardcoded
  // to 640 KB inside pc9821_crtc, so it has no port and no position.
  reg [2:0] cfg_fdd_mode = 3'd0;

  // The TRAM's CPU port, driven directly: this bench addresses the two cells and nothing else.
  reg  [13:0] tram_cpu_addr = 14'd0;
  reg  [ 7:0] tram_cpu_din  = 8'h00;
  reg         tram_cpu_we   = 1'b0;
  wire [ 7:0] tram_cpu_dout;

  // The GDC write port, used only for the cells' own write enable (MODE FF1 bit 6).
  reg  [7:0] io_addr = 8'h00;
  reg  [7:0] io_din  = 8'h00;
  reg        io_wr   = 1'b0;
  wire [7:0] io_dout;

  localparam [13:0] MSW_FDD   = 14'h3FF2;   // memsw[4]: bits 7:4 = the FDD/boot mode nibble
  localparam [13:0] MSW_BASEM = 14'h3FEA;   // memsw[2]: bits 2:0 = the hardcoded base memory

  // ==== DUT ====
  // The real pc9821_crtc + pc9821_gdc2 + pc9821_cg with one clock. The TRAM's CPU port is
  // driven directly, which is the port the two switch cells sit on.
  pc9821_gdc_text_dut u_gdc (
      .clk_sys(clk_sys), .rst_n_sys(rst_n_sys), .pixel_ce(1'b1),
      .io_wr(io_wr), .io_rd(1'b0), .io_addr(io_addr), .io_din(io_din), .io_dout(io_dout),
      .tram_cpu_addr(tram_cpu_addr), .tram_cpu_din(tram_cpu_din),
      .tram_cpu_we(tram_cpu_we), .tram_cpu_dout(tram_cpu_dout),
      .cfg_fdd_mode(cfg_fdd_mode),
      .cfg_seed_reload(1'b0)
  );

  integer errors = 0;

  task automatic machine_reset;
    begin
      @(negedge clk_sys);
      rst_n_sys = 1'b0;
      repeat (8) @(posedge clk_sys);
      @(negedge clk_sys);
      rst_n_sys = 1'b1;
      repeat (4) @(posedge clk_sys);
    end
  endtask

  // The cell through the TRAM's own CPU port. It is a registered read (pc9821_dpram's q_a), so
  // one clock after the address is presented the byte is on the wire.
  task automatic read_cell(input [13:0] addr, output [7:0] data);
    begin
      @(negedge clk_sys);
      tram_cpu_addr = addr;
      tram_cpu_we   = 1'b0;
      @(posedge clk_sys);
      #1;
      data = tram_cpu_dout;
    end
  endtask

  task automatic write_cell(input [13:0] addr, input [7:0] data);
    begin
      @(negedge clk_sys);
      tram_cpu_addr = addr;
      tram_cpu_din  = data;
      tram_cpu_we   = 1'b1;
      @(posedge clk_sys);
      @(negedge clk_sys);
      tram_cpu_we   = 1'b0;
      tram_cpu_din  = 8'h00;
    end
  endtask

  task automatic write_io(input [7:0] portnum, input [7:0] data);
    begin
      @(negedge clk_sys);
      io_addr = portnum;
      io_din  = data;
      io_wr   = 1'b1;
      @(negedge clk_sys);
      io_wr   = 1'b0;
    end
  endtask

  reg [7:0] fdd_byte, base_byte;

  // THE REFERENCE'S OWN NIBBLE PER POSITION - never derived from the RTL: 0x0/0x2/0x4 are
  // the ITF's own compared values (BANK7@0x5999 `jz` keep / BANK7@0x599B `cmp ah,0x20` /
  // BANK7@0x59A0 `cmp ah,0x40`) and 0x6/0xa/0xb/0xc are NP2kai bios1b.c:883-926's
  // boot-device switch codes (`case 0x60: // MO`, `case 0xa0: // SASI 1`, `case 0xb0:
  // // SASI 2`, `case 0xc0: // SCSI`).
  function automatic [3:0] fdd_ref_nib(input [2:0] pos);
    case (pos)
      3'd0:    fdd_ref_nib = 4'd0;
      3'd1:    fdd_ref_nib = 4'd2;
      3'd2:    fdd_ref_nib = 4'd4;
      3'd3:    fdd_ref_nib = 4'd6;
      3'd4:    fdd_ref_nib = 4'd10;
      3'd5:    fdd_ref_nib = 4'd11;
      default: fdd_ref_nib = 4'd12;
    endcase
  endfunction

  task automatic expect_cells(input [7:0] want_fdd, input [7:0] want_base,
                              input [1023:0] where);
    begin
      read_cell(MSW_FDD, fdd_byte);
      read_cell(MSW_BASEM, base_byte);
      if (fdd_byte !== want_fdd) begin
        $display("FAIL %0s: 0xA3FF2 reads 0x%02x, want 0x%02x", where, fdd_byte, want_fdd);
        errors = errors + 1;
      end
      if (base_byte !== want_base) begin
        $display("FAIL %0s: 0xA3FEA reads 0x%02x, want 0x%02x (640 KB is hardcoded)", where, base_byte, want_base);
        errors = errors + 1;
      end
    end
  endtask

  integer i;

  // ==== CHECKS ====
  initial begin
    // ---- (a) entry 0, the config-less card: the MEASURED FDD byte and the HARDCODED base ----
    machine_reset;
    expect_cells(8'h01, 8'h0C, "(a) entry 0 must seed the measured FDD byte and keep the hardcoded base");
    $display("  (a) entry 0: 0xA3FF2 = 0x%02x (the machine's own switch byte), 0xA3FEA = 0x%02x (bits 2:0 = 4 = 640 KB, hardcoded)",
             fdd_byte, base_byte);

    // ---- (b) a machine reset applies the OSD selection; the base memory does not move ----
    // Boot order position 1 -> nibble 0x20, the value the authentic BIOS compares against.
    // 0xA3FEA must stay 0x0C: the base memory is hardcoded, not an OSD field.
    cfg_fdd_mode = 3'd1;
    machine_reset;
    expect_cells(8'h21, 8'h0C, "(b) the reset must seed the OSD's switch value and keep the hardcoded base");
    $display("  (b) Boot order 1 (0x20): 0xA3FF2 = 0x%02x, 0xA3FEA = 0x%02x (still 640 KB)",
             fdd_byte, base_byte);

    // ---- (c) a MID-RUN change must move nothing ----
    // This is the contract the two straps already live under: the firmware reads a switch once
    // and a switch that moved under it would change the machine mid-boot.
    cfg_fdd_mode = 3'd2;
    for (i = 0; i < 64; i = i + 1) @(posedge clk_sys);
    expect_cells(8'h21, 8'h0C, "(c) a mid-run change must not move the cells");
    $display("  (c) mid-run change to Boot order 2: cells unchanged (0x%02x/0x%02x)",
             fdd_byte, base_byte);

    // ---- (d) the NEXT machine reset applies it ----
    // 0x40 -> the other nibble the authentic BIOS compares against; the base stays 0x0C.
    machine_reset;
    expect_cells(8'h41, 8'h0C, "(d) the next reset must apply the new selection and keep the hardcoded base");
    $display("  (d) after the reset: 0xA3FF2 = 0x%02x, 0xA3FEA = 0x%02x (still 640 KB)",
             fdd_byte, base_byte);

    // ---- (e) back on entry 0 the measured bytes come back ----
    cfg_fdd_mode = 3'd0;
    machine_reset;
    expect_cells(8'h01, 8'h0C, "(e) a reset on entry 0 must restore the measured bytes");
    $display("  (e) back on entry 0: 0x%02x/0x%02x", fdd_byte, base_byte);

    // ---- (f) every legal encoding round-trips, and an unoffered position means the measured machine ----
    // The nibble per position is the REFERENCE's own (fdd_ref_nib above), never the RTL's:
    // 0x0/0x2/0x4 the ITF's compared values (BANK7@0x5999/0x599B/0x59A0) and 0x6/0xa/0xb/0xc
    // NP2kai bios1b.c:883-926's boot-device codes. The list offers exactly seven positions; the
    // eighth (FDD 7) must land on the captured machine, so a hand-edited config file cannot
    // ask for a machine nobody captured. At every position the base memory is asserted 0x0C -
    // the hardcode survives the FDD walk.
    for (i = 0; i < 7; i = i + 1) begin
      cfg_fdd_mode = i[2:0];
      machine_reset;
      expect_cells({fdd_ref_nib(i[2:0]), 4'h1}, 8'h0C, "(f) every legal encoding must round-trip");
    end
    $display("  (f) all seven encodings round-trip: 0x01/0x21/0x41/0x61/0xA1/0xB1/0xC1, base always 0x0C");
    cfg_fdd_mode = 3'd7;      // not offered (the list has seven entries)
    machine_reset;
    expect_cells(8'h01, 8'h0C, "(f) an unoffered position must describe the measured machine");
    $display("  (f) the unoffered FDD position (7) decodes to the measured 0x01/0x0C");

    // ---- (g) the seed is a write, not a read override ----
    // MODE FF1 bit 6 is the cells' write enable (pc9821_text_mem's tram_msw_cell gate); with it
    // set, the guest's own write lands. A read-side override could not pass this.
    write_io(8'h68, 8'h0D);
    write_cell(MSW_BASEM, 8'h55);
    read_cell(MSW_BASEM, base_byte);
    if (base_byte !== 8'h55) begin
      $display("FAIL (g): the guest's write to 0xA3FEA read back 0x%02x, want 0x55 - the seed must be a reset-time write, not a read override",
               base_byte);
      errors = errors + 1;
    end else
      $display("  (g) guest write with MODE FF1 bit 6 set: 0xA3FEA = 0x55");

  // ==== VERDICT ====
    // ---- verdict ----
    if (errors == 0) begin
      $display("TB_PC9821_MSW_SWITCH: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_MSW_SWITCH: FAIL (%0d errors)", errors);
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_MSW_SWITCH: TIMEOUT");
  end

endmodule
