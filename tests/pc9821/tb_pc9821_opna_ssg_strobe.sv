`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The OPNA SSG write strobe (psg_wr_n) deasserts on the host clock, not the FM clk_en: with cen held inactive so clk_en never fires, an SSG-data-write-then-FM-select sequence leaves SSG register 1 at its power-on reset 0x00 instead of the stale data byte the ~37-host-clock strobe wrote into the newly-selected register, matching the die's level-gated SSG write (fmopna_impl.c:301-302, 2144-2190) that the level-sensitive jt49 (write = !wr_n && !cs_n) applies every host clock the strobe is low.
//
// Why this is the fail-first for P2:
// the vendored jt12_mmr asserts psg_wr_n on an SSG data write (the `8'h0?` case)
// but only deasserts it inside `else if(clk_en)`, so with the FM master enable held
// off the strobe stays low for ~37 host clocks. The next register-select write then
// changes psg_addr (selected_register[3:0]) while the strobe is still low, and the
// level-sensitive jt49 writes the stale psg_data into the newly-selected register.
// The die gates the SSG register write to the data-write bus cycle
// (../refs/YM2608-LLE/fmopna_impl.c:301-302 latches ssg_write1 level-gated to the
// A0=1 data write, and :2144-2190 applies the write only while that level is high),
// so a one-host-clock strobe is the faithful form. The expected value here is that
// register 1 keeps its power-on reset byte (0x00) after the sequence, not that any
// particular stale byte landed - sourced from the LLE path, not from our RTL.

// ==== DUT ====
module tb_pc9821_opna_ssg_strobe;

  reg clk = 0;
  always #5 clk = ~clk;

  reg        rst = 1'b0;
  reg        cen = 1'b0;   // held INACTIVE: clk_en never fires, which is what makes the old RTL fail
  reg  [7:0] din = 8'h00;
  reg        write = 1'b0;
  reg  [1:0] addr = 2'd0;
  reg  [7:0] debug_bus = 8'h00;

  wire [3:0] psg_addr;
  wire [7:0] psg_data;
  wire       psg_wr_n;

  // The memory-mapped-register block of the OPNA, configured exactly as jt08.v:78-80
  // drives jt12_top (use_ssg=1, num_ch=6, use_pcm=0, use_adpcm=2, use_chipid=1).
  jt12_mmr #(
      .use_ssg   (1'b1),
      .num_ch    (6),
      .use_pcm   (1'b0),
      .use_adpcm (2),
      .mask_div  (1'b1),
      .use_chipid(1'b1)
  ) u_mmr (
      .rst          (rst),
      .clk          (clk),
      .cen          (cen),
      .din          (din),
      .write        (write),
      .addr         (addr),
      .flag_A       (1'b0),
      .overflow_A   (1'b0),
      .debug_bus    (debug_bus),
      .psg_addr     (psg_addr),
      .psg_data     (psg_data),
      .psg_wr_n     (psg_wr_n),
      .clk_en       (),
      .clk_en_2     (),
      .clk_en_ssg   (),
      .clk_en_666   (),
      .clk_en_111   (),
      .clk_en_55    (),
      .busy         (),
      .ch6op        (),
      .cur_ch       (),
      .cur_op       (),
      .lfo_freq     (),
      .lfo_en       (),
      .value_A      (),
      .value_B      (),
      .load_A       (),
      .load_B       (),
      .enable_irq_A (),
      .enable_irq_B (),
      .clr_flag_A   (),
      .clr_flag_B   (),
      .fast_timers  (),
      .div_setting  (),
      .irq_mask     (),
      .pcm          (),
      .pcm_en       (),
      .pcm_wr       (),
      .aon_a        (),
      .atl_a        (),
      .addr_a       (),
      .lracl        (),
      .up_start     (),
      .up_end       (),
      .up_addr      (),
      .up_lracl     (),
      .up_aon       (),
      .acmd_on_b    (),
      .acmd_rep_b   (),
      .acmd_rst_b   (),
      .acmd_up_b    (),
      .acmd_rec_b   (),
      .acmd_mem_b   (),
      .acmd_spk_b   (),
      .acmd_smp_b   (),
      .acmd_dac_b   (),
      .acmd_x8_b    (),
      .acmd_rom_b   (),
      .alr_b        (),
      .astart_b     (),
      .aend_b       (),
      .adeltan_b    (),
      .aeg_b        (),
      .flag_ctl     (),
      .flag_mask    (),
      .pscale_b     (),
      .alimit_b     (),
      .xuse_prevprev1(),
      .xuse_internal(),
      .yuse_internal(),
      .xuse_prev2   (),
      .yuse_prev1   (),
      .yuse_prev2   (),
      .fnum_I       (),
      .block_I      (),
      .pg_stop      (),
      .rl           (),
      .fb_II        (),
      .alg_I        (),
      .pms_I        (),
      .ams_IV       (),
      .amsen_IV     (),
      .dt1_I        (),
      .mul_II       (),
      .tl_IV        (),
      .eg_stop      (),
      .ar_I         (),
      .d1r_I        (),
      .d2r_I        (),
      .rr_I         (),
      .sl_I         (),
      .ks_II        (),
      .ssg_en_I     (),
      .ssg_eg_I     (),
      .keyon_I      (),
      .zero         (),
      .s1_enters    (),
      .s2_enters    (),
      .s3_enters    (),
      .s4_enters    (),
      .sel_chipid   (),
      .sel_ram_dat  (),
      .sel_dac_dat  ()
  );

  // The SSG consumer, wired exactly as jt12_top.v:689-703 (`.cs_n ( 1'b0 )`, so write = !wr_n).
  jt49 u_psg (
      .rst_n  (~rst),
      .clk    (clk),
      .clk_en (1'b1),
      .addr   (psg_addr),
      .cs_n   (1'b0),
      .wr_n   (psg_wr_n),
      .din    (psg_data),
      .sel    (1'b1),
      .dout   (),
      .sound  (),
      .A      (),
      .B      (),
      .C      (),
      .sample (),
      .IOA_in (8'hFF),
      .IOA_out(),
      .IOA_oe (),
      .IOB_in (8'hFF),
      .IOB_out(),
      .IOB_oe ()
  );

  integer errors = 0;

  task automatic fail(input [8*96-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // ==== STIMULUS ====
  // One register-cycle on the chip bus: the write is sampled on the posedge between
  // the first two negedges, and the following idle (write=0) on the posedge between
  // the second and third. That trailing idle is where the wide strobe's corruption
  // lands: jt49 samples psg_wr_n / psg_addr / psg_data on the same posedge that
  // jt12_mmr updates them, so the freshly-changed psg_addr is seen one clock later.
  task automatic bus_write(input [1:0] a, input [7:0] d);
    begin
      @(negedge clk);
      write = 1'b1; addr = a; din = d;
      @(negedge clk);
      write = 1'b0; din = 8'h00;
      @(negedge clk);
    end
  endtask

  // ==== CHECKS ====
  initial begin
    // reset, then release
    rst = 1'b1;
    repeat (8) @(negedge clk);
    rst = 1'b0;
    repeat (8) @(negedge clk);

    // (1) The reachable corruption:
    // select SSG reg 7, write its data, then select FM reg 0xB1 (whose low nibble is
    // SSG register 1). With the wide strobe the trailing idle writes 0xA5 into
    // regarray[1]; with the one-host-clock strobe regarray[1] keeps its reset 0x00.
    bus_write(2'd0, 8'h07);   // select SSG reg 7
    bus_write(2'd1, 8'hA5);   // data -> reg 7 (asserts psg_wr_n)
    bus_write(2'd0, 8'hB1);   // select FM reg 0xB1 (psg_addr -> 1)

    if (u_psg.regarray[1] !== 8'h00) begin
      fail("SSG register 1 was corrupted to a stale data byte (want power-on reset 0x00)");
      $display("  regarray[1] = %02x, psg_wr_n = %0b, psg_addr = %0d, psg_data = %02x",
               u_psg.regarray[1], psg_wr_n, psg_addr, psg_data);
    end

    // (2) Positive control: the observation path is live - a real SSG write to
    // register 1 still lands (proves the check above would have seen a corrupted byte).
    bus_write(2'd0, 8'h01);   // select SSG reg 1
    bus_write(2'd1, 8'h5A);   // data -> reg 1
    if (u_psg.regarray[1] !== 8'h5A) begin
      fail("a direct SSG write to register 1 did not land (instrumentation broken)");
      $display("  regarray[1] = %02x, psg_wr_n = %0b, psg_addr = %0d, psg_data = %02x",
               u_psg.regarray[1], psg_wr_n, psg_addr, psg_data);
    end

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_OPNA_SSG_STROBE: PASS");
    end else begin
      $display("  FAIL: %0d errors", errors);
      $fatal(1, "TB_PC9821_OPNA_SSG_STROBE: FAIL (%0d errors)", errors);
    end
    $finish;
  end

  initial begin
    #10_000_000;
    $fatal(1, "TB_PC9821_OPNA_SSG_STROBE: TIMEOUT");
  end

endmodule
