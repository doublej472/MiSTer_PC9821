`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_SETUP_RECORD: the CG configuration record and the software-DIP mirror follow the
// OSD's SETUP items and are restored by every reset.
//
// THE MANIFEST'S CLAIM, word for word (one line, so the checker's whitespace-normalised match sees it):
// The configuration record and the software-DIP mirror in the CG store carry the OSD's SETUP items: record row 2 (code 0x2056), which SETUP stores as the inverted DIP switch 2 and the ITF writes back inverted into port 0x31, is ~port 0x31: 0x0C at the defaults (GDC 2.5 MHz, 25 lines, initialise) with bit 3 cleared for 20 lines (0x04), bit 4 set for keep (0x1C) and both for both (0x14), and bit 7 set at GDC 5 MHz (the factory 0x8C, BANK3@0x09F0), because SETUP's GDC clock getter reads row 2 bit 7 (BANK3@0x37A3 `call 0x20db / shr al,0x7`, value 1 = 2.5 MHz) and the owner's Xe10, photographed in SETUP, shows 2.5 MHz (docs/bios-setup.md, The Xe10 as found), row 3, DIP switch 3 stored inverted, is 0x80 at the default floppy disk mode auto (1M), the factory 0x81 at 1M and 0x82 / 0x83 at auto (640K) / 640K (bits 1:0 the complement of SETUP's value 3/2/1/0), row 4 is 0xCF in every state (the factory 0xCD with bit 1 set: SETUP's Sound item stored 1 = not used, the owner's Xe10 as found, docs/bios-setup.md, The Xe10 as found, whose 0x881E reads 0x7C in docs/probes/XE10CFG-XE10-CFG0.TXT; the ITF's sound POST reads the bit at BANK4@0x2967), and row A is recomputed so the ITF's sum check over rows 1..0xA stays 0 with the AA55 marker in place (BANK4@0x4677-0x46B5) in every state, with 0xE6 at the defaults (row 2 0x0C, row 3 0x80), 0xE5 / 0xE4 / 0xE3 at 1M / auto (640K) / 640K, 0x66 at GDC 5 MHz and 0x65 at GDC 5 MHz with 1M (the factory 0x67 less row 4's bit 1); a program's write to a record row reads back until the CPU-reset echo clear, then the OSD row again; the bank-A mirror cell the ITF copies into port 0x871E at POST (code 0x0156 row 3, BANK4@0x4439-0x4465) is re-written from setup_cfg by every restore pulse, so a program's write there lasts until the next reset (the machine reset or the guest's 0x534 reboot, pc9821_iobus's sdip_seed_pulse) and the OSD's 0x871E byte is what POST copies, the other mirror cells keeping the measured bytes (0x881E = 0x7C, Sound not used, the capture's byte); the mirror's 0x861E cell (code 0x0156 row 2) is the OSD's floppy-mode byte after every restore, the bytes the Xe10 holds after SETUP stored each mode (F7 / 76 / 75 / F4 at auto (1M) / 1M / auto (640K) / 640K, docs/probes/XE10CFG-XE10-CFG0/CFGF3/CFGF1/CFGF0.TXT). The mirror's 0x851E cell (code 0x0156 row 1) is the port-0x31 image the firmware's own writers store there, not the port's read-back 02: the ITF's re-sync (BANK4@0x4839-0x4849) and SETUP's accessor (BANK3@0x220B-0x221D) take port 0x31 with bit 4 made the odd-parity bit, so after every restore it is E3 at the defaults (port 0x31 F3, docs/probes/XE10CFG-XE10-CFG0.TXT), FB at 20 lines, E3 at keep, FB at both and 73 at GDC 5 MHz (the Xa7C9W capture's own cell, qemu-pc98 roms/pc98bios/memsw.inc `.byte 0x01, 0x01, 0x73`), bit 5 (the internal hard disk, use) set in every state, because the ITF's POST copy writes it to 0x851E, port 0x31 follows that write, and the IDE ROM detaches the hard disks when port 0x31 bit 5 reads 0 (BANK3@0x2F5-0x324). After a restore at the defaults every one of the 24 mirror cells is the byte the ITF's re-sync (BANK4@0x4824-0x486F) stores from the ports the core seeds, which its POST copy (BANK4@0x4439-0x4482) writes back: bank A 7C E3 F7 3E 7C 7F FF BF 7F 7F 49 98 (docs/probes/XE10CFG-XE10-CFG0.TXT SDIPA0 with 0x851E's cell port 0x31's image and 0x861E auto (1M)), bank B 8F then eleven 80 (SDIPB). Fail-first by mutation (tests/pc9821/mutations.json): with the record row or the mirror cell constant, or the checksum not recomputed, the non-default steps fail, with row 2 bit 7 the constant factory 1 (the core before it followed the GDC clock) the defaults fail, with row 4 the factory 0xCD (Sound used) the defaults fail, and with the 0x851E cell the port's read-back 02 (the core before this cell was composed) every row-1 step fails. The ITF's saved-table length (code 0x1056 line 0x20 rows 0/1, the length word of the port table the ITF saves from code 0x5610 up, BANK4@0x2136-0x2192, and does not rewrite while it is non-zero, BANK4@0x1D34-0x1D64) reads 0000 after every restore, the length a core load starts from: the next POST's KANJI CG-RAM test (BANK4@0x0076-0x00F4) zeroes the table's part past code 0x5620 (the Xa7C9W capture's length 0x15A crosses it too, qemu-pc98 roms/pc98bios/memsw.inc), so a kept length made the boot after fail the table check (BANK4@0x4741-0x47AD) and install the factory DIP image (BANK4@0x47B2) - FAIL-FIRST, the replayed length 0183 survived the restore.
//
// THE EVIDENCE (docs/bios-setup.md, "How SETUP stores a setting").
//   - SETUP's accessors store record rows 1-4 INVERTED (`not al` on both sides, the table at
//     BANK3@0x20A5-0x2321) and HOME CLR installs rows 1-9 `c1 8c 81 cd ff 00 00 aa 55`
//     (BANK3@0x09F0-0x0AA0). Row 2 is DIP switch 2: bit 3 text lines (1 = 20 lines, stored
//     0), bit 4 the memory switch (1 = initialise, stored 0). Row 3 is DIP switch 3: bits 1:0
//     the floppy disk mode (0 640K, 1 auto (640K), 2 1M, 3 auto (1M); stored 0x81 = ~2 at
//     the factory 1M, 0x80 = ~3 at the core's default auto (1M)), which the OSD's Floppy mode field carries (setup_cfg [23:16], the
//     0x861E seed byte pc9821_iobus writes; the Xe10's bytes per mode are the captures'
//     SDIPA0 byte 2, docs/probes/XE10CFG-XE10-CFG0/CFGF3/CFGF1/CFGF0.TXT).
//   - The ITF validates the record before it trusts it: rows 8/9 = AA55 and the ten bytes at
//     rows 1..0xA summing to 0 (BANK4@0x4677-0x46B5).
//   - Row 4 bit 1 is SETUP's Sound item (the built-in PCM codec, not the -86 board), stored
//     1 = not used (docs/bios-setup.md, the Sound row). The owner's Xe10 as found has it
//     "not used" (docs/bios-setup.md "The Xe10 as found", photographed), and its 0x881E
//     reads 0x7C (docs/probes/XE10CFG-XE10-CFG0.TXT `SDIPA0 7C 02 76 3E 7C`: bit 5 = not
//     used, against 0xDC in XE10CFG-XE10-CFGSND.TXT with the item "used"). The record does
//     not read through 0xA9 on the machine (the capture's `CG 2056` rows are 00, a probe
//     limitation), so row 4 is the factory 0xCD with that item applied: 0xCF. The ITF reads
//     the bit at BANK4@0x2967 (`in al,0xA9 / and al,0x2 / test al,0x2 / jnz`): set, it
//     writes no IRQ select to the codec and no `out 0xA460,0x73`.
//   - The mirror: the ITF copies code 0x0156 rows 0x00-0x0B into bank A's ports at POST
//     (BANK4@0x4439-0x4465), so the mirror's 0x871E cell must be the byte pc9821_iobus seeds
//     (setup_cfg [15:8]; tb_pc9821_setup_osd pins it).
//   - The mirror's 0x851E cell: the ITF's re-sync stores PORT 0x31 there, not 0x851E
//     (BANK4@0x4839-0x4849 `in al,dx / cmp dh,0x85 / jz` -> `in al,0x31 / test al,0xff / jpo /
//     xor al,0x10 / mov [es:di],al`), and SETUP's 0x851E accessor composes the same byte
//     (BANK3@0x220B-0x221D `in al,0x31 / and ax,0x10ef / or al,ah`, then `and al,0xef / jpo /
//     or al,0x10`). A real machine's cell is that image: the Xa7C9W capture's code 0x01 line
//     0x01 is 0x73 (qemu-pc98 roms/pc98bios/memsw.inc), its port 0x31 at GDC 5 MHz with the
//     parity bit, while the port itself reads 02 (docs/probes/XE10CFG-XE10-CFG0.TXT `SDIPA0 7C
//     02`). The ITF's POST copy (BANK4@0x4439-0x4465) writes the cell to 0x851E, and port 0x31
//     follows a bank-A 0x851E write's bits 7:5 and 3:0 (docs/probes/XE10CFG-XE10-CFGWR.TXT `RT
//     851E was=02 wrote=12 got=12 p31=12`), so the cell's bit 5 becomes port 0x31 bit 5, which
//     the IDE ROM reads as the internal hard disk switch (BANK3@0x2F5 `in al,0x31 / test al,0x20
//     / jnz`; clear, it masks the drives out of 0:055D at BANK3@0x324).

module tb_pc9821_setup_record;

  reg clk_sys = 0;
  always #10 clk_sys = ~clk_sys;
  reg rst_n_sys = 0;

  reg        io_wr = 0, io_rd = 0;
  reg  [7:0] io_addr = 8'hA1, io_din = 8'h00;
  wire [7:0] io_dout;
  reg        cg_record_restore = 0;
  reg        cfg_seed_reload = 0;
  // The OSD configuration from pc9821_iobus: {0x861E seed, 0x871E seed, port 0x31}, at the OSD
  // defaults (Floppy mode Auto (1M): 0x861E = 0xF7, CFGF3's byte).
  reg [23:0] setup_cfg = 24'hF73EF3;

  // ==== DUT ====
  // The scanout and font-loader sides are idle; only the 0xA1/0xA3/0xA5/0xA9 ports move.
  pc9821_cg dut (
      .clk_sys(clk_sys), .rst_n_sys(rst_n_sys), .pixel_ce(1'b0),
      .io_wr(io_wr), .io_rd(io_rd), .io_addr(io_addr), .io_din(io_din), .io_dout(io_dout),
      .cg_win_byte_sel(5'd0), .cg_win_rd(1'b0), .cg_win_dout(), .cg_win_din(8'h00),
      .cg_win_we(1'b0),
      .font_word_valid(1'b0), .font_word_data(32'd0),
      .font_ld_addr(18'd0), .font_ld_data(16'd0), .font_ld_we(1'b0),
      .cg_record_restore(cg_record_restore),
      .setup_cfg(setup_cfg),
      .bios_set(4'd0),
      .cfg_ram_mib(7'd16), .cfg_seed_en(1'b1), .cfg_seed_reload(cfg_seed_reload),
      .ank_rd_addr(11'd0), .jc_rd_bank(2'd0), .jc_rd_cell(7'd0), .jc_rd_word(2'd0),
      .cg_ram_vid_addr(13'd0), .tram_vid_q(8'h20),
      .v_pitch(8'd40), .v_col40(1'b0), .v_sad(16'd0),
      .wk_go(1'b0), .wk_k(10'd0), .wk_bank_in(2'd0), .hdot(10'd0)
  );

  integer errors = 0;
  reg [7:0] value;

  // ==== CHECKS ====
  task automatic fail(input [8*110-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task automatic write_io(input [7:0] portnum, input [7:0] data);
    begin
      @(negedge clk_sys);
      io_addr = portnum; io_din = data; io_wr = 1;
      @(negedge clk_sys); io_wr = 0;
    end
  endtask

  task automatic read_io(input [7:0] portnum, output [7:0] data);
    begin
      @(negedge clk_sys);
      io_addr = portnum; io_rd = 1;
      #1 data = io_dout;
      @(negedge clk_sys); io_rd = 0;
      @(negedge clk_sys);
    end
  endtask

  // A CG cell through the port the ITF uses: A1/A3 the code, A5 the row (bit 5 clear = the
  // cg_lr half the record and bank A's mirror live in), 0xA9 the byte.
  task automatic read_cell(input [7:0] hi, input [7:0] lo, input [7:0] a5, output [7:0] data);
    begin
      write_io(8'hA1, hi);
      write_io(8'hA3, lo);
      write_io(8'hA5, a5);
      read_io(8'hA9, data);
    end
  endtask
  task automatic write_cell(input [7:0] hi, input [7:0] lo, input [7:0] a5, input [7:0] data);
    begin
      write_io(8'hA1, hi);
      write_io(8'hA3, lo);
      write_io(8'hA5, a5);
      write_io(8'hA9, data);
    end
  endtask

  // The record (code 0x2056) row r, and the ITF's own check over it.
  task automatic check_row(input [3:0] row, input [7:0] want, input [8*64-1:0] what);
    begin
      read_cell(8'h20, 8'h56, {4'h0, row}, value);
      if (value !== want) begin
        $display("FAIL: %0s: record row %0d = %02x, want %02x", what, row, value, want);
        errors = errors + 1;
      end else
        $display("  %0s: record row %0d = %02x", what, row, value);
    end
  endtask
  task automatic check_record_valid(input [8*64-1:0] what);
    reg [7:0] sum, hi, lo;
    integer r;
    begin
      read_cell(8'h20, 8'h56, 8'h08, hi);
      read_cell(8'h20, 8'h56, 8'h09, lo);
      if ({hi, lo} !== 16'hAA55) begin
        $display("FAIL: %0s: marker %02x%02x, want AA55", what, hi, lo);
        errors = errors + 1;
      end
      sum = 8'd0;
      for (r = 1; r <= 10; r = r + 1) begin
        read_cell(8'h20, 8'h56, r[7:0], value);
        sum = sum + value;
      end
      if (sum !== 8'd0) begin
        $display("FAIL: %0s: rows 1..0xA sum to %02x, the ITF wants 0", what, sum);
        errors = errors + 1;
      end
    end
  endtask

  // The mirror (code 0x0156) bank-A row r = port 0x84+r's byte.
  task automatic check_mirror(input [3:0] row, input [7:0] want, input [8*64-1:0] what);
    begin
      read_cell(8'h01, 8'h56, {4'h0, row}, value);
      if (value !== want) begin
        $display("FAIL: %0s: mirror bank A row %0d = %02x, want %02x", what, row, value, want);
        errors = errors + 1;
      end else
        $display("  %0s: mirror bank A row %0d = %02x", what, row, value);
    end
  endtask

  // One restore pulse (pc9821_iobus's sdip_seed_pulse) and the 40-step walk after it.
  task automatic restore;
    begin
      @(negedge clk_sys); cg_record_restore = 1'b1;
      @(negedge clk_sys); cg_record_restore = 1'b0;
      repeat (60) @(negedge clk_sys);
    end
  endtask
  task automatic echo_clear;
    begin
      @(negedge clk_sys); cfg_seed_reload = 1'b1;
      @(negedge clk_sys); cfg_seed_reload = 1'b0;
      @(negedge clk_sys);
    end
  endtask

  initial begin
    // The machine reset: the restore walk runs inside it, as pc9821_system's seed does.
    repeat (3) @(negedge clk_sys);
    restore;
    @(negedge clk_sys); rst_n_sys = 1'b1;
    repeat (4) @(negedge clk_sys);

    // (a) The defaults: the factory record and the measured mirror bytes.
    check_row(4'd2, 8'h0C, "(a) defaults: GDC 2.5 MHz, 25 lines, initialise");
    check_row(4'd3, 8'h80, "(a) defaults: auto (1M)");
    check_row(4'd4, 8'hCF, "(a) defaults, row 4: Sound not used (as found)");
    check_row(4'd10, 8'hE6, "(a) defaults, the sum byte (row 2 0x0C, row 3 0x80)");
    check_record_valid("(a) defaults");
    check_mirror(4'd2, 8'hF7, "(a) defaults, 0x861E: auto (1M)");
    check_mirror(4'd3, 8'h3E, "(a) defaults, 0x871E");
    check_mirror(4'd4, 8'h7C, "(a) defaults, 0x881E: Sound not used (as found)");
    check_mirror(4'd1, 8'hE3, "(a) defaults, 0x851E: port 0x31 F3's image");

    // (b) Text lines 20 (port 0x31 0xFB): row 2 bit 3 cleared, the sum still 0.
    setup_cfg = 24'hF73EFB;
    #1;
    check_row(4'd2, 8'h04, "(b) Text lines 20");
    check_record_valid("(b) Text lines 20");

    // (c) Memory switch keep (port 0x31 0xE3, 0x871E 0x9E): row 2 bit 4 set.
    setup_cfg = 24'hF79EE3;
    #1;
    check_row(4'd2, 8'h1C, "(c) keep");
    check_record_valid("(c) keep");

    // (d) Text lines 20 and keep together: both bits, the sum still 0.
    setup_cfg = 24'hF79EEB;
    #1;
    check_row(4'd2, 8'h14, "(d) 20 lines + keep");
    check_row(4'd4, 8'hCF, "(d) 20 lines + keep, row 4 unmoved");
    check_record_valid("(d) 20 lines + keep");

    // (e) A program writes a record row (SETUP storing "20 lines"): the read echoes it until
    //     the CPU reset's echo clear, then the OSD row answers again.
    setup_cfg = 24'hF73EF3;
    #1;
    write_cell(8'h20, 8'h56, 8'h02, 8'h04);
    check_row(4'd2, 8'h04, "(e) a program's record write reads back");
    echo_clear;
    check_row(4'd2, 8'h0C, "(e) after the CPU reset, the OSD row");

    // (f) The mirror: a program's write lasts until the next restore, which writes the OSD's
    //     byte (here keep) into the cell POST copies into the port.
    write_cell(8'h01, 8'h56, 8'h03, 8'h1E);
    check_mirror(4'd3, 8'h1E, "(f) a program's mirror write reads back");
    echo_clear;
    check_mirror(4'd3, 8'h1E, "(f) the mirror is store, not seed: it survives the echo clear");
    setup_cfg = 24'hF79EE3;
    restore;
    check_mirror(4'd2, 8'hF7, "(f) after the restore, 0x861E from the OSD");
    check_mirror(4'd3, 8'h9E, "(f) after the restore, 0x871E from the OSD");
    check_mirror(4'd0, 8'h7C, "(f) after the restore, 0x841E the measured byte");
    setup_cfg = 24'hF73EF3;
    restore;
    check_mirror(4'd2, 8'hF7, "(f) defaults restored, 0x861E");
    check_mirror(4'd3, 8'h3E, "(f) defaults restored, 0x871E");

    // (g) The floppy disk mode: record row 3 bits 1:0 are SETUP's value inverted, the sum stays
    //     0, and the restore writes the OSD's 0x861E byte into the mirror cell POST copies.
    setup_cfg = 24'h763EF3;                         // 1M (the factory value), CFG0's 0x861E
    #1;
    check_row(4'd3, 8'h81, "(g) 1M, the factory row");
    check_row(4'd10, 8'hE5, "(g) 1M, the sum byte");
    check_row(4'd4, 8'hCF, "(g) 1M, row 4 unmoved");
    check_record_valid("(g) 1M");
    restore;
    check_mirror(4'd2, 8'h76, "(g) 1M, 0x861E the measured byte");
    setup_cfg = 24'h753EF3;                         // auto (640K), CFGF1's 0x861E
    #1;
    check_row(4'd3, 8'h82, "(g) auto (640K)");
    check_row(4'd10, 8'hE4, "(g) auto (640K), the sum byte");
    check_row(4'd4, 8'hCF, "(g) auto (640K), row 4 unmoved");
    check_record_valid("(g) auto (640K)");
    restore;
    check_mirror(4'd2, 8'h75, "(g) auto (640K), 0x861E");
    setup_cfg = 24'hF43EF3;                         // 640K, CFGF0's 0x861E
    #1;
    check_row(4'd3, 8'h83, "(g) 640K");
    check_row(4'd10, 8'hE3, "(g) 640K, the sum byte");
    check_row(4'd4, 8'hCF, "(g) 640K, row 4 unmoved");
    check_record_valid("(g) 640K");
    restore;
    check_mirror(4'd2, 8'hF4, "(g) 640K, 0x861E");
    check_mirror(4'd3, 8'h3E, "(g) 640K, 0x871E unchanged");
    setup_cfg = 24'hF73EF3;
    #1;
    restore;
    check_row(4'd3, 8'h80, "(g) back to the default auto (1M)");
    check_mirror(4'd2, 8'hF7, "(g) back to auto (1M), 0x861E");

    // (h) The mirror's 0x851E cell: port 0x31's image with bit 4 the odd-parity bit, as the
    //     ITF's re-sync composes it (BANK4@0x4841-0x4849), in every OSD state; bit 5 (the
    //     internal hard disk) stays set. A program's write lasts until the next restore.
    setup_cfg = 24'hF73EFB;                         // 20 lines: port 0x31 FB
    restore;
    check_mirror(4'd1, 8'hFB, "(h) 20 lines, 0x851E");
    setup_cfg = 24'hF79EE3;                         // keep: port 0x31 E3
    restore;
    check_mirror(4'd1, 8'hE3, "(h) keep, 0x851E");
    setup_cfg = 24'hF79EEB;                         // 20 lines + keep: port 0x31 EB
    restore;
    check_mirror(4'd1, 8'hFB, "(h) 20 lines + keep, 0x851E");
    setup_cfg = 24'hF73E73;                         // GDC 5 MHz: port 0x31 73
    restore;
    check_mirror(4'd1, 8'h73, "(h) GDC 5 MHz, 0x851E: the Xa7C9W capture's cell");
    write_cell(8'h01, 8'h56, 8'h01, 8'h02);
    check_mirror(4'd1, 8'h02, "(h) a program's write to the 0x851E cell reads back");
    setup_cfg = 24'hF73EF3;
    restore;
    check_mirror(4'd1, 8'hE3, "(h) defaults restored, 0x851E");

    // (i) The GDC clock: row 2 bit 7 is the complement of port 0x31 bit 7, as SETUP's GDC clock
    //     getter reads it (BANK3@0x37A3 `call 0x20db / shr al,0x7`, value 1 = 2.5 MHz) - clear
    //     at the default 2.5 MHz (the Xe10 as found, photographed in SETUP), set at 5 MHz, where
    //     row 2 is the factory 0x8C and, at 1M, rows 1..0xA are the Xe10 ITF's own table
    //     (BANK4@0x4924 `c1 8c 81 cd ff 00 00 aa 55 67`) with row 4's Sound bit: sum byte 0x65.
    setup_cfg = 24'hF73E73;                         // GDC 5 MHz: port 0x31 73
    #1;
    check_row(4'd2, 8'h8C, "(i) GDC 5 MHz, the factory row");
    check_row(4'd10, 8'h66, "(i) GDC 5 MHz, the sum byte (row 3 0x80)");
    check_record_valid("(i) GDC 5 MHz");
    setup_cfg = 24'h763E73;                         // GDC 5 MHz and 1M: the factory items
    #1;
    check_row(4'd2, 8'h8C, "(i) GDC 5 MHz + 1M, row 2");
    check_row(4'd3, 8'h81, "(i) GDC 5 MHz + 1M, row 3");
    check_row(4'd10, 8'h65, "(i) GDC 5 MHz + 1M, the sum byte (0x67 less bit 1)");
    check_record_valid("(i) GDC 5 MHz + 1M");
    setup_cfg = 24'h763EF3;                         // the measured machine: 2.5 MHz, 1M
    #1;
    check_row(4'd2, 8'h0C, "(i) GDC 2.5 MHz + 1M (the Xe10 as found), row 2");
    check_row(4'd10, 8'hE5, "(i) GDC 2.5 MHz + 1M, the sum byte");
    check_record_valid("(i) GDC 2.5 MHz + 1M");
    setup_cfg = 24'hF73EF3;
    #1;
    check_row(4'd2, 8'h0C, "(i) back to the defaults, row 2");

    // (j) Every mirror cell after a restore at the defaults: what the ITF's re-sync stores from
    //     the ports (BANK4@0x4824-0x486F: bank A from 0x841E..0x8F1E with 0x851E's cell taken from
    //     port 0x31, bank B from the same ports with 0x8F1F = C0), i.e. the Xe10's port bytes
    //     (docs/probes/XE10CFG-XE10-CFG0.TXT `SDIPA0 7C 02 76 3E 7C 7F FF BF 7F 7F 49 98` and
    //     `SDIPB 8F 80 80 80 80 80 80 80 80 80 80 80`) with 0x851E's cell port 0x31 F3's image E3
    //     and 0x861E the OSD's default auto (1M) F7 (XE10CFG-XE10-CFGF3.TXT). The ITF's POST copy
    //     (BANK4@0x4439-0x4482) writes these back into the ports, so each must be the byte the
    //     port reset walk seeds, or the copy moves a port.
    begin : all_cells
      reg [7:0] want_a [0:11];
      reg [7:0] want_b;
      integer c;
      want_a[0] = 8'h7C; want_a[1] = 8'hE3; want_a[2] = 8'hF7;  want_a[3] = 8'h3E;
      want_a[4] = 8'h7C; want_a[5] = 8'h7F; want_a[6] = 8'hFF;  want_a[7] = 8'hBF;
      want_a[8] = 8'h7F; want_a[9] = 8'h7F; want_a[10] = 8'h49; want_a[11] = 8'h98;
      setup_cfg = 24'hF73EF3;
      restore;
      for (c = 0; c < 12; c = c + 1) check_mirror(c[3:0], want_a[c], "(j) defaults, bank A");
      for (c = 0; c < 12; c = c + 1) begin
        want_b = (c == 0) ? 8'h8F : 8'h80;
        read_cell(8'h01, 8'h56, 8'h20 | c[7:0], value);
        if (value !== want_b) begin
          $display("FAIL: (j) defaults: mirror bank B row %0d = %02x, want %02x", c, value, want_b);
          errors = errors + 1;
        end else
          $display("  (j) defaults: mirror bank B row %0d = %02x", c, value);
      end
    end

    // (k) The ITF's saved-table length is no table after a restore. The ITF saves a table of its
    //     port settings from code 0x5610 line 0x20 up, length word first (BANK4@0x2136-0x2192,
    //     code map BANK4@0x2195-0x21CA), and never rewrites it while the length is non-zero
    //     (BANK4@0x1D34-0x1D64); the next POST's KANJI CG-RAM test leaves 00 over codes
    //     0x5620-0x567F (BANK4@0x0076-0x00F4), which the table crosses (0x183 bytes here; the
    //     Xa7C9W capture's length is 0x15A, qemu-pc98 roms/pc98bios/memsw.inc), so the boot after
    //     failed the table's sum check (BANK4@0x4741-0x47AD) and installed the factory DIP image
    //     (BANK4@0x47B2). Replayed: the save's length 0x0183 and a tail byte at code 0x5620, the
    //     test's 00 over that byte, then a machine reset; the check's first test (`or ax,ax / jz
    //     0x47af`) must see 0, the length a core load starts from.
    begin : table_len
      reg [7:0] lo, hi, tail;
      write_cell(8'h10, 8'h56, 8'h20, 8'h83);   // length low  (BANK4@0x2151-0x2156, si = 0)
      write_cell(8'h10, 8'h56, 8'h21, 8'h01);   // length high
      write_cell(8'h20, 8'h56, 8'h20, 8'hBF);   // si = 0x100: the first byte past code 0x561F
      read_cell(8'h10, 8'h56, 8'h20, lo);
      read_cell(8'h10, 8'h56, 8'h21, hi);
      if ({hi, lo} !== 16'h0183) begin
        $display("FAIL: (k) vacuous: the replayed table length reads %02x%02x, want 0183", hi, lo);
        errors = errors + 1;
      end
      write_cell(8'h20, 8'h56, 8'h20, 8'h00);   // the KANJI test's last pattern over the tail
      restore;
      read_cell(8'h10, 8'h56, 8'h20, lo);
      read_cell(8'h10, 8'h56, 8'h21, hi);
      read_cell(8'h20, 8'h56, 8'h20, tail);
      if ({hi, lo} !== 16'h0000) begin
        $display("FAIL: (k) after a restore the ITF's saved-table length is %02x%02x, want 0000 (BANK4@0x4741 would sum a wiped table)", hi, lo);
        errors = errors + 1;
      end else
        $display("  (k) after a restore: table length 0000 (tail cell %02x, the KANJI test's)", tail);
    end

  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_SETUP_RECORD: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_SETUP_RECORD: FAIL (%0d errors)", errors);
  end

  initial begin
    #5_000_000;
    $fatal(1, "TB_PC9821_SETUP_RECORD: TIMEOUT");
  end

endmodule
