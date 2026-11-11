`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_OSD:
// The OSD's two stored selections, decoded: all eight RAM Size list positions select the guest size their label names, the list rotated so position 0 - what a card with no config file passes - is 16 MB instead of the 1 MB that cannot boot the firmware, with every size in the set still reachable exactly once; Floppy mode passes its list position through unchanged (0 = Auto (1M), the default, to 3 = 640K; pc9821_iobus decodes it). Keyboard position 0 is the US host layout and position 1 JIS. The two SETUP items: Text lines position 0 is 25 lines and position 1 20 (port 0x31 bit 3), Memory switch position 0 Initialise and position 1 Keep, each position 0 the measured Xe10 (0x31 = 0xF3).
//
// WHY THIS BENCH EXISTS AT ALL. The mapping used to be a function inside z486_mister.sv, which
// no bench in this tree can reach, because they are unit benches and none of them elaborates the
// top level. So the contract between the OSD list and the core was untested, and it broke in the
// field: a card with no .CFG passes 0 for every field, 0 meant 1 MB of RAM, and a 1 MB guest
// cannot run the Xe10 BIOS - it froze with nothing on screen. The mapping now lives in
// pc9821_osd.sv precisely so that this can be checked.

module tb_pc9821_osd;

  // ==== DUT ====
  reg  [2:0] osd_ram_size = 3'd0;
  reg        osd_text_lines = 1'b0;
  reg        osd_msw_keep = 1'b0;
  wire       text_lines_20, msw_keep;
  reg  [1:0] osd_floppy_mode = 2'd0;
  reg        osd_kbd_layout = 1'b0;
  wire       kbd_layout_jis;
  wire [2:0] ram_size_code;
  wire [1:0] floppy_mode;

  pc9821_osd dut (
    .osd_ram_size (osd_ram_size),
    .osd_text_lines(osd_text_lines),
    .osd_msw_keep (osd_msw_keep),
    .osd_gdc_clock(1'b0),
    .osd_floppy_mode(osd_floppy_mode),
    .floppy_mode  (floppy_mode),
    .ram_size_code(ram_size_code),
    .text_lines_20(text_lines_20),
    .msw_keep     (msw_keep),
    .gdc_clock_5m (),
    
    .osd_kbd_layout(osd_kbd_layout),
    .kbd_layout_jis(kbd_layout_jis),
    .osd_cd_volume(3'd0),        // the CD audio volume field: tb_pc9821_osd_cd_volume
    .cd_volume_code()
  );

  integer errors = 0;

  // The other half of the contract: a size CODE to the guest size it means. This is
  // pc9821_system.sv's own code-to-bytes table (src/pc9821/core/pc9821_system.sv,
  // the `case (ram_size_sel)` block), spelled out here ON PURPOSE so that this bench
  // pins both ends - the list position that picks a code, and the code that means a
  // size. If either end moves without the other, one of the two checks below fails,
  // and that is the drift this bench exists to catch.
  function automatic integer code_mib(input [2:0] code);
    case (code)
      3'd0:    code_mib = 1;
      3'd1:    code_mib = 2;
      3'd2:    code_mib = 4;
      3'd3:    code_mib = 8;
      3'd4:    code_mib = 16;
      3'd5:    code_mib = 32;
      3'd6:    code_mib = 64;
      default: code_mib = 96;   // the design's deliberate ceiling, not a power of two
    endcase
  endfunction

  // ==== CHECKS ====
  //
  // The contract, as the OSD list in z486_mister.sv spells it. Read the two together:
  // the list's LABELS are these sizes in this order, and the RTL cases below are the
  // codes they select. A rotation of the list that is not mirrored here, or the
  // reverse, is exactly the failure this bench is for.
  reg [2:0] want_code [0:7];
  integer   want_mib  [0:7];
  reg [2:0] seen      [0:7];
  integer   i, j;
  integer   dup;

  initial begin
    //   "O[63:61],RAM Size,16M,32M,64M,96M,1M,2M,4M,8M;"
    want_code[0] = 3'd4; want_mib[0] = 16;   // entry 0 = 16M <- the DEFAULT, and the point
    want_code[1] = 3'd5; want_mib[1] = 32;   // entry 1 = 32M
    want_code[2] = 3'd6; want_mib[2] = 64;   // entry 2 = 64M
    want_code[3] = 3'd7; want_mib[3] = 96;   // entry 3 = 96M
    want_code[4] = 3'd0; want_mib[4] = 1;    // entry 4 = 1M
    want_code[5] = 3'd1; want_mib[5] = 2;    // entry 5 = 2M
    want_code[6] = 3'd2; want_mib[6] = 4;    // entry 6 = 4M
    want_code[7] = 3'd3; want_mib[7] = 8;    // entry 7 = 8M

    // 1. Every list position selects the size code its label names, and that code
    //    means the size the label says.
    for (i = 0; i < 8; i = i + 1) begin
      osd_ram_size = i[2:0];
      #1;
      if (ram_size_code !== want_code[i]) begin
        $display("FAIL RAM Size entry %0d selects size code %0d, want %0d (its label says %0d MB)",
                 i, ram_size_code, want_code[i], want_mib[i]);
        errors = errors + 1;
      end
      else if (code_mib(ram_size_code) != want_mib[i]) begin
        $display("FAIL RAM Size entry %0d -> code %0d -> %0d MB, but its label says %0d MB",
                 i, ram_size_code, code_mib(ram_size_code), want_mib[i]);
        errors = errors + 1;
      end
      seen[i] = ram_size_code;
    end

    // 2. The rotation is a PERMUTATION: every size in the offered set stays reachable,
    //    exactly once. A rotation that dropped a size, or mapped two entries to one,
    //    would pass check 1 for the entries it happened to get right.
    for (i = 0; i < 8; i = i + 1) begin
      dup = 0;
      for (j = 0; j < 8; j = j + 1)
        if (seen[j] == seen[i]) dup = dup + 1;
      if (dup != 1) begin
        $display("FAIL size code %0d is reachable from %0d list positions, want exactly 1",
                 seen[i], dup);
        errors = errors + 1;
      end
    end

    // 3. THE BUG THIS EXISTS FOR, named so a failure is unmistakable. A card with no
    //    stored config passes 0 for every field, so position 0 is what such a card
    //    boots - and it must not be the 1 MB that cannot run the firmware.
    osd_ram_size = 3'd0;
    #1;
    if (code_mib(ram_size_code) != 16) begin
      $display("FAIL a card with no stored config boots %0d MB, want 16 (this is the default)",
               code_mib(ram_size_code));
      errors = errors + 1;
    end
    if (code_mib(ram_size_code) == 1) begin
      $display("FAIL the default is 1 MB, which cannot boot the Xe10 firmware at all");
      errors = errors + 1;
    end

    // 4. The SETUP items. Position 0 of each is the measured Xe10 and SETUP's factory value
    //    (port 0x31 = 0xF3: bit 3 clear = 25 lines, bit 4 set = initialise, docs/probes/
    //    MEMSW.TXT `0031=F3`).
    osd_text_lines = 1'b0; osd_msw_keep = 1'b0;
    #1;
    if (text_lines_20 !== 1'b0 || msw_keep !== 1'b0) begin
      $display("FAIL SETUP items entry 0 (25 lines, Initialise) decode as %0b%0b",
               text_lines_20, msw_keep);
      errors = errors + 1;
    end
    osd_text_lines = 1'b1;
    #1;
    if (text_lines_20 !== 1'b1 || msw_keep !== 1'b0) begin
      $display("FAIL Text lines entry 1 is 20 lines alone, decode %0b%0b", text_lines_20, msw_keep);
      errors = errors + 1;
    end
    osd_text_lines = 1'b0; osd_msw_keep = 1'b1;
    #1;
    if (text_lines_20 !== 1'b0 || msw_keep !== 1'b1) begin
      $display("FAIL Memory switch entry 1 is Keep alone, decode %0b%0b", text_lines_20, msw_keep);
      errors = errors + 1;
    end
    osd_msw_keep = 1'b0;

    // 5. Floppy mode. The position goes through as a position (0 = Auto (1M), the default), so an
    //    undriven port downstream is the default; pc9821_iobus's fdmode_setup decodes it.
    for (integer fm = 0; fm < 4; fm = fm + 1) begin
      osd_floppy_mode = fm[1:0];
      #1;
      if (floppy_mode !== fm[1:0]) begin
        $display("FAIL Floppy mode position %0d reads %0d", fm, floppy_mode);
        errors = errors + 1;
      end
    end

    // 6. Keyboard. Position 0 is US (the layout the core translated the backslash key in
    //    before the option existed), position 1 JIS; pc9821_kbd reads layout_jis.
    osd_kbd_layout = 1'b0;
    #1;
    if (kbd_layout_jis !== 1'b0) begin
      $display("FAIL Keyboard entry 0 is US, but kbd_layout_jis=%0b", kbd_layout_jis);
      errors = errors + 1;
    end
    osd_kbd_layout = 1'b1;
    #1;
    if (kbd_layout_jis !== 1'b1) begin
      $display("FAIL Keyboard entry 1 is JIS, but kbd_layout_jis=%0b", kbd_layout_jis);
      errors = errors + 1;
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_OSD: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_OSD: FAIL (%0d errors)", errors);
  end

  // In-bench watchdog. The runner also bounds wall time and greps the PASS marker,
  // but this bench is combinational and must never hang.
  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_OSD: TIMEOUT");
  end

endmodule
