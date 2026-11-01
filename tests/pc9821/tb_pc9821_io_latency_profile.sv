`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The compile-time I/O-latency profile, measured end to end through the real pc9821_iobus: with IO_LATENCY_PROFILE 0 the bus is the min table - the smallest waits the firmware needs - where every class but 0x005F and the 8253 WRITE is the FSM floor IO_MIN_HOLD = 4, 0x005F takes the machine's item-41 1621 ns as ONE value in both directions (because a `wr`-dependent value at 0x005F trips a Quartus fitter internal error; see pc9821_iobus.sv) because the BIOS POST's timer-interrupt test (BANK4@0x487) polls with `out 0x5f`, and the 8253 READ is the floor too - and with IO_LATENCY_PROFILE 2 it prices the machine's own measured access TIMES from docs/probes/IO.TXT (its `abs_ns` column, the 2026-09-24 Xe10 capture) per DIRECTION - so the default class costs 823 ns on a read and 862 ns on a write, 0x005F costs 826 ns on a read and the item-41 1621 ns anchor on a write (the same 1621 ns the min profile charges, but min charges it to the read too where faithful prices the read at 826 ns), the EGC/GRCG write class is 356-359 ns, the text GDC is 444 ns, the graphics GDC is 676 ns, and the EGC register file 0x4A0-0x4AF splits by ADDRESS PARITY: 9290 ns on an even read (the capture's 8.6-9.4 us class), 823 ns on an odd read, 356 ns on a write; and the two measured-FAST ports the default arm used to over-charge are priced at the capture's own times, 0x09A0 at 391 ns - 2.1x over the default - and 0x0FAA at 295.6 ns, 2.8x over it and the fastest port the capture prices. Because every class is derived from SYS_CLOCK_HZ with the ceil idiom the two firmware floors already use, one access is the same REAL TIME at every profile clock. FAIL-FIRST: profile 2's faithfulness contradicts profile 0's, so the same assertions cannot hold before the faithful table lands (profile 2 would measure profile 0's 4/30/82/21 cycles). The sub-knob is pinned too: IO_LATENCY_PROFILE 1 is profile 2 with the unresolved-mechanism EGC-file parity class held back, so its even 0x4A0 read is the default read class and not 9290 ns. The min profile's 0x005F is asserted at the machine's 1621 ns in BOTH directions (the POST timer test needs the write; the read pays the same because a `wr`-dependent value there trips a Quartus fitter internal error - see pc9821_iobus.sv; 0x5F reads are unused by the firmware, 0 `in 0x5F` against 391 `out 0x5F`), and the boot golden is unchanged because the diagnostic pack never touches 0x005F; the 8253's read direction IS the floor, because its floor is the ITF self-test's write requirement and the capture reads 8253 count registers at the default class.

`default_nettype none

module tb_pc9821_io_latency_profile;

  localparam integer CLK_HZ = 50_000_000;
  // One clk_sys period in ns - the quantisation a ceil conversion can add, so a delivered
  // access time may exceed the capture's by at most this much and never fall short of it.
  localparam integer CLK_NS = 1_000_000_000 / CLK_HZ;

  // The machine's measured per-class access times, in ns: docs/probes/IO.TXT `abs_ns` (the
  // 2026-09-24 Xe10 capture, decoded by tools/hwprobe/ioprobe/ioprobe_decode.py). NEVER
  // derived from our RTL - the RTL is what this bench measures.
  localparam integer NS_DEF_R    = 823;   // the 61 default ports' reads (820.2-826.5)
  localparam integer NS_DEF_W    = 862;   // the default-class writes (OPNA 0x188/0x18A 864.7/861.5)
  localparam integer NS_5F_R     = 826;   // 0x005F read = the default class (0x005F R 826.5)
  localparam integer NS_5F_W     = 1621;  // 0x005F write, the item-41 anchor
  localparam integer NS_EGC_R    = 386;   // 0x6A read 387.8 / 0xA6 read 384.6
  localparam integer NS_EGC_W    = 356;   // 0x6A/0xA6 writes (356.0)
  localparam integer NS_GRCG_W   = 359;   // 0x7C write 359.2 (0x7E is unmeasured: its pair's value)
  localparam integer NS_GDC1_R   = 444;   // text GDC 0x60 read 445.0 / 0x62 read 441.9
  localparam integer NS_GDC2_R   = 676;   // graphics GDC 0xA0 read 673.9 / 0xA2 read 677.1
  localparam integer NS_PIT_R    = 823;   // 0x71/0x73 reads 823.3
  localparam integer NS_PIT_W    = 861;   // 0x77 write 861.5
  localparam integer NS_EGCF_HI  = 9290;  // 0x4A0-0x4AE EVEN reads 8608.5-9365.1 (8.6-9.4 us)
  localparam integer NS_EGCF_LO  = 823;   // 0x4A1-0x4AF ODD reads 823.3-826.5 (the default read class)
  localparam integer NS_9A0      = 391;   // 0x09A0 read 391.0 (PEGC9A0) - 2.1x under the default
  localparam integer NS_FAA      = 296;   // 0x0FAA read 295.6 (ACCFAA) - the fastest port priced

  // The min profile's own values, which base must keep EXACTLY.
  localparam integer MIN_FLOOR = 4;
  localparam integer MIN_PIT   = 21;      // ceil(one 2.4576 MHz PIT tick)
  // ...and the one direction it does NOT apply to: the 8253 floor is the ITF self-test's WRITE
  // requirement, and the capture prices an 8253 READ at the default class (PITD0/PITD1), which
  // in the min profile is the FSM floor.
  localparam integer MIN_PIT_R = MIN_FLOOR;

  // ==== DUT ====
  reg clk = 1'b0;
  always #10 clk = ~clk;                  // 20 ns period = 50 MHz

  reg reset = 1'b1;

  // ---- the three DUTs: min (0), the faithful sub-knob without the parity class (1),
  // ---- and the full faithful table (2). All at the same clock, so any difference between
  // ---- them is the class table and nothing else.
  wire [15:0] min_def_r, min_def_w, min_5f_r, min_5f_w, min_egc_r, min_egc_w, min_grcg_w,
              min_gdc1_r, min_gdc2_r, min_pit_r, min_pit_w, min_egcf_even_r, min_egcf_odd_r,
              min_9a0_r, min_faa_r;
  wire [15:0] sub_def_r, sub_def_w, sub_5f_r, sub_5f_w, sub_egc_r, sub_egc_w, sub_grcg_w,
              sub_gdc1_r, sub_gdc2_r, sub_pit_r, sub_pit_w, sub_egcf_even_r, sub_egcf_odd_r,
              sub_9a0_r, sub_faa_r;
  wire [15:0] fth_def_r, fth_def_w, fth_5f_r, fth_5f_w, fth_egc_r, fth_egc_w, fth_grcg_w,
              fth_gdc1_r, fth_gdc2_r, fth_pit_r, fth_pit_w, fth_egcf_even_r, fth_egcf_odd_r,
              fth_9a0_r, fth_faa_r;
  wire        min_done, sub_done, fth_done;

  lat_probe #(.HZ(CLK_HZ), .PROF(2'd0)) p_min (
      .clk(clk), .reset(reset), .done(min_done),
      .c_def_r(min_def_r), .c_def_w(min_def_w), .c_5f_r(min_5f_r), .c_5f_w(min_5f_w),
      .c_egc_r(min_egc_r), .c_egc_w(min_egc_w), .c_grcg_w(min_grcg_w),
      .c_gdc1_r(min_gdc1_r), .c_gdc2_r(min_gdc2_r), .c_pit_r(min_pit_r), .c_pit_w(min_pit_w),
      .c_egcf_even_r(min_egcf_even_r), .c_egcf_odd_r(min_egcf_odd_r),
      .c_9a0_r(min_9a0_r), .c_faa_r(min_faa_r));

  lat_probe #(.HZ(CLK_HZ), .PROF(2'd1)) p_sub (
      .clk(clk), .reset(reset), .done(sub_done),
      .c_def_r(sub_def_r), .c_def_w(sub_def_w), .c_5f_r(sub_5f_r), .c_5f_w(sub_5f_w),
      .c_egc_r(sub_egc_r), .c_egc_w(sub_egc_w), .c_grcg_w(sub_grcg_w),
      .c_gdc1_r(sub_gdc1_r), .c_gdc2_r(sub_gdc2_r), .c_pit_r(sub_pit_r), .c_pit_w(sub_pit_w),
      .c_egcf_even_r(sub_egcf_even_r), .c_egcf_odd_r(sub_egcf_odd_r),
      .c_9a0_r(sub_9a0_r), .c_faa_r(sub_faa_r));

  lat_probe #(.HZ(CLK_HZ), .PROF(2'd2)) p_fth (
      .clk(clk), .reset(reset), .done(fth_done),
      .c_def_r(fth_def_r), .c_def_w(fth_def_w), .c_5f_r(fth_5f_r), .c_5f_w(fth_5f_w),
      .c_egc_r(fth_egc_r), .c_egc_w(fth_egc_w), .c_grcg_w(fth_grcg_w),
      .c_gdc1_r(fth_gdc1_r), .c_gdc2_r(fth_gdc2_r), .c_pit_r(fth_pit_r), .c_pit_w(fth_pit_w),
      .c_egcf_even_r(fth_egcf_even_r), .c_egcf_odd_r(fth_egcf_odd_r),
      .c_9a0_r(fth_9a0_r), .c_faa_r(fth_faa_r));

  // ==== CHECKS ====
  integer errors = 0;

  task automatic fail(input string message);
    begin
      $display("FAIL: %0s", message);
      errors = errors + 1;
    end
  endtask

  // The class's total access, in real nanoseconds, from the cycles the probe counted.
  function automatic integer ns_of(input [15:0] cycles);
    begin
      ns_of = (cycles * 1000) / (CLK_HZ / 1_000_000);
    end
  endfunction

  // The faithful assertion: the delivered access is the CAPTURE's real time, quantised up to
  // the nearest clk_sys by the ceil conversion and never short of it. A class that fell back
  // to the min floor reads 80 ns and fails here by hundreds to thousands of ns.
  task automatic check_ns(input string which, input [15:0] cycles, input integer expected_ns);
    integer got;
    begin
      got = ns_of(cycles);
      if (got < expected_ns)
        fail($sformatf("%0s delivers %0d ns, SHORT of the capture's %0d ns", which, got, expected_ns));
      else if (got > expected_ns + CLK_NS)
        fail($sformatf("%0s delivers %0d ns, more than one clk (%0d ns) above the capture's %0d ns",
                       which, got, CLK_NS, expected_ns));
    end
  endtask

  task automatic check_cyc(input string which, input [15:0] cycles, input integer expected_cyc);
    begin
      if (cycles !== expected_cyc[15:0])
        fail($sformatf("%0s is %0d clk, expected %0d", which, cycles, expected_cyc));
    end
  endtask

  initial begin
    // ==== STIMULUS ====
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    wait (min_done && sub_done && fth_done);
    repeat (4) @(posedge clk);

    $display("  ---- the min profile (IO_LATENCY_PROFILE 0), which base must keep EXACTLY ----");
    check_cyc("min default read",  min_def_r,  MIN_FLOOR);
    check_cyc("min default write", min_def_w,  MIN_FLOOR);
    check_ns ("min 0x005F read",   min_5f_r,   NS_5F_W);   // one value with the write: the fitter-bug workaround
    check_ns ("min 0x005F write",  min_5f_w,   NS_5F_W);   // the POST timer test's poll window
    check_cyc("min EGC 0x6A read", min_egc_r,  MIN_FLOOR);
    check_cyc("min 0x007E write",  min_grcg_w, MIN_FLOOR);
    check_cyc("min text GDC read", min_gdc1_r, MIN_FLOOR);
    check_cyc("min gfx GDC read",  min_gdc2_r, MIN_FLOOR);
    check_cyc("min 8253 read",     min_pit_r,  MIN_PIT_R);
    check_cyc("min 8253 write",    min_pit_w,  MIN_PIT);
    check_cyc("min EGC file even read", min_egcf_even_r, MIN_FLOOR);
    check_cyc("min 0x09A0 read",   min_9a0_r,  MIN_FLOOR);
    check_cyc("min 0x0FAA read",   min_faa_r,  MIN_FLOOR);
    $display("    min: default %0d/%0d 5F %0d/%0d EGC %0d/%0d 0x7E W %0d GDC %0d/%0d 8253 %0d/%0d EGCfile even %0d",
             min_def_r, min_def_w, min_5f_r, min_5f_w, min_egc_r, min_egc_w, min_grcg_w,
             min_gdc1_r, min_gdc2_r, min_pit_r, min_pit_w, min_egcf_even_r);

    // The min profile's OTHER direction defect is fixed instead of displayed:
    // the 8253's floor is the ITF self-test's WRITE requirement, and the capture prices its READ
    // at the default class. FAIL-FIRST: this read was 21 clk before the fix.

    // The min profile's 0x005F is ONE value, the machine's 1621 ns WRITE time (asserted above),
    // because the BIOS POST's timer-interrupt test polls with `out 0x5f` and its window must
    // outlast a 2.4576 MHz terminal count. A `wr`-dependent value at 0x5F trips a Quartus
    // fitter internal error at physical synthesis (see pc9821_iobus.sv), so the READ pays the
    // same 1621 ns rather than the machine's 826 ns; 0x5F reads are not used by the firmware
    // (0 `in 0x5F` sites against 391 `out 0x5F`). The faithful profile prices both directions.
    $display("    min profile 0x005F is one value: %0d ns (the machine's write time; its read is %0d ns in the faithful profile)",
             ns_of(min_5f_w), NS_5F_R);

    $display("  ---- the faithful profile (IO_LATENCY_PROFILE 2): the capture's real times ----");
    check_ns("faithful default read",  fth_def_r,  NS_DEF_R);
    check_ns("faithful default write", fth_def_w,  NS_DEF_W);
    check_ns("faithful 0x005F read",   fth_5f_r,   NS_5F_R);
    check_ns("faithful 0x005F write",  fth_5f_w,   NS_5F_W);
    check_ns("faithful EGC 0x6A read", fth_egc_r,  NS_EGC_R);
    check_ns("faithful EGC 0x6A write", fth_egc_w, NS_EGC_W);
    check_ns("faithful 0x007E write",  fth_grcg_w, NS_GRCG_W);
    check_ns("faithful text GDC read", fth_gdc1_r, NS_GDC1_R);
    check_ns("faithful gfx GDC read",  fth_gdc2_r, NS_GDC2_R);
    check_ns("faithful 8253 read",     fth_pit_r,  NS_PIT_R);
    check_ns("faithful 8253 write",    fth_pit_w,  NS_PIT_W);
    check_ns("faithful EGC file even read", fth_egcf_even_r, NS_EGCF_HI);
    check_ns("faithful EGC file odd read",  fth_egcf_odd_r,  NS_EGCF_LO);
    // The two measured-FAST ports the default arm used to over-charge: 0x9A0
    // at 391 ns was 2.1x over, 0xFAA at 295.6 ns was 2.8x over. FAIL-FIRST: both measured the
    // default class (823 ns) before the fix, which check_ns rejects as more than one clk above
    // the capture.
    check_ns("faithful 0x09A0 read", fth_9a0_r, NS_9A0);
    check_ns("faithful 0x0FAA read", fth_faa_r, NS_FAA);
    if (fth_9a0_r >= fth_def_r)
      fail($sformatf("0x09A0 must be priced below the default class: %0d vs %0d clk",
                     fth_9a0_r, fth_def_r));
    if (fth_faa_r >= fth_9a0_r)
      fail($sformatf("0x0FAA is the fastest measured port, so it must be below 0x09A0: %0d vs %0d clk",
                     fth_faa_r, fth_9a0_r));
    $display("    faithful: default %0d/%0d 5F %0d/%0d EGC %0d/%0d 0x7E W %0d GDC %0d/%0d 8253 %0d/%0d EGCfile even/odd %0d/%0d clk",
             fth_def_r, fth_def_w, fth_5f_r, fth_5f_w, fth_egc_r, fth_egc_w, fth_grcg_w,
             fth_gdc1_r, fth_gdc2_r, fth_pit_r, fth_pit_w, fth_egcf_even_r, fth_egcf_odd_r);

    // A read-vs-write PAIR, asserted explicitly: the capture prices the directions differently
    // and the min profile cannot.
    if (fth_5f_w <= fth_5f_r)
      fail($sformatf("0x005F must cost more on a WRITE than a read: %0d vs %0d clk", fth_5f_w, fth_5f_r));
    if (fth_def_w <= fth_def_r)
      fail($sformatf("the default class must cost more on a WRITE than a read: %0d vs %0d clk", fth_def_w, fth_def_r));
    // The min profile charges 0x005F ONE value, the machine's 1621 ns (the BIOS POST's timer
    // test needs the write; a `wr`-dependent value there trips a Quartus fitter bug), so the
    // two directions must AGREE where the faithful profile's differ.
    if (min_5f_w !== min_5f_r)
      fail($sformatf("the min profile must charge 0x005F ONE value (the fitter-bug workaround): %0d vs %0d",
                     min_5f_w, min_5f_r));

    // The EGC file's parity split, and that it is a SEPARATE knob: profile 1 holds the
    // unresolved-mechanism class back to the odd/default read class.
    if (fth_egcf_even_r <= fth_egcf_odd_r)
      fail($sformatf("the EGC file's even read must be the slow class: even %0d vs odd %0d clk",
                     fth_egcf_even_r, fth_egcf_odd_r));
    check_ns("sub-knob EGC file even read (profile 1)", sub_egcf_even_r, NS_EGCF_LO);
    check_ns("sub-knob EGC file odd read (profile 1)",  sub_egcf_odd_r,  NS_EGCF_LO);
    $display("    sub-knob profile 1: EGC file even read %0d ns (held back), profile 2 %0d ns",
             ns_of(sub_egcf_even_r), ns_of(fth_egcf_even_r));

    // Profile 1 is otherwise profile 2: the three classes the parity knob does not touch.
    check_ns("sub-knob default read", sub_def_r, NS_DEF_R);
    check_ns("sub-knob 0x005F write", sub_5f_w,  NS_5F_W);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_IO_LATENCY_PROFILE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_IO_LATENCY_PROFILE: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_IO_LATENCY_PROFILE: TIMEOUT");
  end

endmodule

// ------------------------------------------------------------------
// One pc9821_iobus at one IO_LATENCY_PROFILE, self-driving: it measures the class of every
// port this bench checks, ONE access at a time, in both directions, and raises `done`.
// The count is the io_class idiom (the request is presented on a negedge, the count is the
// negedges waited), so the value stored is io_access_cycles' own return - the class value,
// the FSM's three cycles included.
// ------------------------------------------------------------------
`default_nettype none
module lat_probe #(parameter [31:0] HZ = 32'd50_000_000,
                   parameter [1:0]  PROF = 2'd0) (
    input  wire       clk,
    input  wire       reset,
    output reg        done,
    output reg [15:0] c_def_r, c_def_w,
    output reg [15:0] c_5f_r, c_5f_w,
    output reg [15:0] c_egc_r, c_egc_w, c_grcg_w,
    output reg [15:0] c_gdc1_r, c_gdc2_r,
    output reg [15:0] c_pit_r, c_pit_w,
    output reg [15:0] c_egcf_even_r, c_egcf_odd_r,
    output reg [15:0] c_9a0_r, c_faa_r
);
  reg [31:0] cpu_addr = 32'd0, cpu_din = 32'd0;
  reg [3:0]  cpu_be = 4'd0;
  reg        cpu_valid = 1'b0, cpu_write = 1'b0;
  wire [31:0] cpu_dout;
  wire        cpu_ready, cpu_resp_valid;
  reg  [7:0]  debug_status = 8'hA5;
  wire        device_io_wr, device_io_rd;
  wire [15:0] device_io_addr;
  wire [7:0]  device_io_din;
  reg  [7:0]  device_io_dout = 8'hC3;
  // A device that presents its data in the strobe cycle, so the S_DEVWAIT cycle is never in
  // the measurement: what is measured is the class table's own hold, which is the subject.
  reg         device_rd_wait = 1'b0;
  reg         device_rd_hold = 1'b0;
  reg         device_wr_wait = 1'b0;
  wire [3:0]  top_bank;
  wire        sound_extend;
  wire        ide_rom_enable, bios_ram_gate;
  wire ide_ram_gate;   // 0x1E8E's IDE work-RAM gate (the iobus drives it; unused here)
  wire [7:0]  win0_sel;
  wire       win0_sel_moved;   // pc9821_iobus's registered `win0_sel != 8'h08`
  wire        sys16m_en;
  wire        beep_mute;
  wire [1:0]  beep_vol;
  wire        a20_enable, cpu_reset_req;
  wire [15:0] unmapped_writes, unmapped_reads, last_unmapped_port;
  wire [7:0]  post_code;
  wire        post_write;
  // The core's native whole-L1 flush handshake (iobus's cache_flush_req /
  // cache_flush_busy / cache_flush_done), modelled here at ZERO LATENCY: this
  // bench does not measure flush timing, and an unmodelled cache_flush_done
  // would leave any flush-triggering write waiting in iobus's S_FLUSH forever.
  // The real request/done contract is tb_pc9821_cache_flush's subject.
  wire cache_flush_req;
  wire crt31k;   // 0x09A8 bit 0 (pc9821_iobus), named so .* binds it
  wire cache_flush_busy = 1'b0;
  wire cache_flush_done = cache_flush_req;
  wire [3:0]  dbg_gate;
  wire [7:0]  dbg_itf_stage;
  wire [15:0] dbg_artic_hi;
  wire [15:0] dbg_last_io_addr;
  wire [7:0]  dbg_last_io_data;
  wire        dbg_last_io_rd, dbg_last_io_wr;
  // The FDC's debug taps: named because the DUT is (.*), not exercised here
  // (tb_pc9821_fdc_dbg pins them).
  wire [7:0]  dbg_fdc_state;
  wire [7:0]  dbg_fdc_cmd;
  wire [31:0] dbg_fdc_result;
  wire [31:0] dbg_fdc_chrn;
  reg         cal_cdat = 1'b0;
  wire [6:0]  cfg_ram_mib = 7'd0;
  wire        cfg_seed_en = 1'b0;
  wire       sdip_seed_pulse;   // the machine-reset seed's one-shot (pc9821_iobus)
  reg         triple_fault_reset = 1'b0;
  reg         egc_gate = 1'b0;
  wire [15:0] egc_access, egc_fgbg, egc_ope, egc_fg, egc_mask, egc_bg, egc_sft, egc_leng;
  wire        egc_shift_we;
  wire [1:0]  ems_state;
  wire        top_shadow_en;
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window
  reg  [3:0]  bios_set = 4'd0;
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  fdd_dip_fixed = 1'b1;   // the 0x00BE bit-2 FDD-mode switch at the measured unit's Fixed
  reg  [10:0] gdc_ff2_state = 11'd0;
  wire        mouse_irq;
  reg  [24:0] ps2_mouse = 25'd0;
  // ---- pc9821_iobus's Phase-1 port groups, tied off: this probe drives NO floppy ----
/* verilator lint_off UNUSEDSIGNAL */
  wire [3:0]  fdd_present = 4'd0;
  wire [3:0]  fdd_chg = 4'd0;          // no media change: the FDC's ready-change tag
  wire        fdd_frame_tick = 1'b0;
  wire        fdd_req, fdd_req_hdr, fdd_adv;
  wire [1:0]  fdd_unit;
  wire [7:0]  fdd_c, fdd_h, fdd_r, fdd_n, fdd_idx, fdd_dout, fdd_hr, fdd_hn, fdd_hs;
  wire [7:0]  fdd_tc;   // pc9821_iobus's physical-track pair (pc9821_fdc media_tc/media_hd)
  wire        fdd_hd;
  wire        fdd_mf;
  wire        fdd_2hd;   // pc9821_iobus's media-mode pair (pc9821_fdc media_2hd/media_rpm)
  wire        fdd_rpm;
  wire        fdd_ready = 1'b1, fdd_rdy = 1'b0, fdd_hdrv = 1'b0, fdd_err = 1'b0;
  wire [31:0] dma_mem_addr, dma_mem_din;
  wire [1:0]  dma_mem_gvwin;   // the DMAC's plane-window class (unused here)
  wire [3:0]  dma_mem_be;
  wire        dma_mem_req, dma_mem_we;
  wire        dma_mem_ready = 1'b0;
  wire [31:0] dma_mem_dout = 32'd0;
  wire        dma_mem_resp_valid = 1'b0;
/* verilator lint_on UNUSEDSIGNAL */
  // Stage A's write-protect seam. Declared because pc9821_iobus is instantiated with `.*`
  // here, which requires every one of its ports to resolve (tools/check_wiring.py).
  wire [3:0] fdd_wp = 4'b0000;
  wire       fdd_req_wr;   // pc9821_iobus's write leg (unused here: no write is issued)
  wire [7:0] fdd_din;
  wire       fdd_abort;


  wire [1:0] d8_bank;   // 0x063C bits 1-0 (the 0xD8000 bank select); unused here


  // P5: the device-bus chip selects are pc9821_iobus outputs now (its own one decode).
  // This bench drives no device select of its own, so they are named here for the wildcard
  // instantiation and left unused.
  wire pic_master_cs, pic_slave_cs, pit_cs, interrupt_cs, cal_cs, kbd_cs,
       ata_cs, opna_cs, pcm_cs, gameport_cs, mpu_cs, sdph_cs, gdc_cs;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1), .SYS_CLOCK_HZ(HZ), .IO_LATENCY_PROFILE(PROF)) dut (
      .ide_unit0_present(1'b0),.*);

  task automatic measure(input [15:0] portnum, input wr, output [15:0] cycles);
    integer n;
    begin
      @(negedge clk);
      cpu_addr  = {16'd0, portnum[15:2], 2'b00};
      cpu_be    = 4'b0001 << portnum[1:0];
      cpu_din   = 32'h0000_0000;
      cpu_write = wr;
      cpu_valid = 1'b1;
      n = 0;
      while (!cpu_ready) begin
        @(negedge clk);
        n = n + 1;
      end
      cycles = n[15:0] - 16'd1;   // the FSM's own three cycles included: this IS io_access_cycles' return (the io_class idiom)
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_write = 1'b0;
      cpu_be    = 4'd0;
      while (dut.state != 0) @(negedge clk);
    end
  endtask

  initial begin
    done = 1'b0;
    c_def_r = 16'd0; c_def_w = 16'd0; c_5f_r = 16'd0; c_5f_w = 16'd0;
    c_egc_r = 16'd0; c_egc_w = 16'd0; c_grcg_w = 16'd0;
    c_gdc1_r = 16'd0; c_gdc2_r = 16'd0; c_pit_r = 16'd0; c_pit_w = 16'd0;
    c_egcf_even_r = 16'd0; c_egcf_odd_r = 16'd0;
    c_9a0_r = 16'd0; c_faa_r = 16'd0;
    wait (!reset);
    @(negedge clk);
    measure(16'h0EE0, 1'b0, c_def_r);   // unmapped -> the default class
    measure(16'h0EE0, 1'b1, c_def_w);
    measure(16'h005F, 1'b0, c_5f_r);    // the firmware's own I/O-wait port (read)
    measure(16'h005F, 1'b1, c_5f_w);    // ...and its item-41 write anchor
    measure(16'h006A, 1'b0, c_egc_r);   // EGC mode register
    measure(16'h006A, 1'b1, c_egc_w);
    measure(16'h007E, 1'b1, c_grcg_w);  // the GRCG tile register (the Rusty wipe's port)
    measure(16'h0060, 1'b0, c_gdc1_r);  // text GDC
    measure(16'h00A0, 1'b0, c_gdc2_r);  // graphics GDC
    measure(16'h0071, 1'b0, c_pit_r);   // the 8253
    measure(16'h0071, 1'b1, c_pit_w);
    measure(16'h04A0, 1'b0, c_egcf_even_r);  // EGC register file, even address
    measure(16'h04A1, 1'b0, c_egcf_odd_r);   // ...and odd
    measure(16'h09A0, 1'b0, c_9a0_r);   // the PEGC index/data query (the measured-fast pair)
    measure(16'h0FAA, 1'b0, c_faa_r);   // ...and the accelerator index port
    done = 1'b1;
  end
endmodule
`default_nettype wire
