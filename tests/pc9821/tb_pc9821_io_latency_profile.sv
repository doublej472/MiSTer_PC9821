`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_IO_LATENCY_PROFILE: The OSD's I/O timing field (pc9821_iobus io_timing_xe10), measured end to end through the real pc9821_iobus at 50 MHz: FAST (0, the default) is today's table EXACTLY - every class but the 8253 WRITE is the FSM floor IO_MIN_HOLD = 4 (0x005F both ways: its write is posted), the 8253 write the ITF self-test's one 2.4576 MHz tick (21 clk), and a word access two floors; XE10 (1) makes each WHOLE I/O instruction - the bus time measured here plus the core CPU's own 8 clk_sys around it (docs/probes/core/KIT2-CORE-SPEED.TXT: `in al,dx` 12 clk in Fast around a 4-clk access) - the Xe10's measured time within one clk and never short of it, every value the net_ns of an XE10T /IO row (docs/probes/XE10T-XE10.TXT): default read 791.5 / write 823.3 ns, 0x5F read 788.4 (its write posted, the floor), EGC 0x6A read 349.7, the fast write class 314.7-317.9 on 0x6A, 0x7E, 0x64 and 0xA4, text GDC 413.3, graphics GDC 639.0, the 8253 read 791.5 and write at the default write, the EGC file's even read 5989.1 and odd read 791.5, 0x09A0/0x09A8 352.9 and 0x0FAA 254.3 - and a 16-bit access costs ONE class (R16_005C 791.5, R16_0188 788.4, W16_04A8 314.7; within two clk, the high lane's walk cycle included), and `in al,dx` at 0x02 and 0xA0 sits on kit 2's SPEED (docs/probes/KIT2-XE10-SPEED.TXT: 802.30 and 650.77 ns net) within XE10T's own disagreement with it plus one clk; no Xe10 access is faster than its Fast one, and a third iobus whose input is flipped at run time, with no reset, measures Fast's list before the flip and Xe10's after it, access for access. FAIL-FIRST: before the field the bus had no Xe10 table at run time (IO_LATENCY_PROFILE was a compile-time parameter), and the faithful table it replaces charged IO.TXT's times on the bus alone, 8 clk (160 ns) over the machine's instruction, and two classes for a word.

`default_nettype none

module tb_pc9821_io_latency_profile;

  localparam integer CLK_HZ = 50_000_000;
  // One clk_sys period in ns - the quantisation a ceil conversion can add, so a delivered
  // access time may exceed the capture's by at most this much and never fall short of it.
  localparam integer CLK_NS = 1_000_000_000 / CLK_HZ;

  // The machine's measured per-class access times, in ns: the `net_ns` column of the Xe10's
  // XE10T /IO section (docs/probes/XE10T-XE10.TXT, decoded by tools/hwprobe/xe10t/xe10t_decode.py;
  // each row is what ONE access instruction costs, the loop less a control without the access).
  // NEVER derived from our RTL - the RTL is what this bench measures. Quoted rows:
  //   R IO R8_0002 ... art=254/255/256 ...   (line 292)  -> 791.5 ns, the default read class
  localparam integer NS_DEF_R    = 792;
  //   R IO W8_0000 ... art=264/265/266 ...   (line 402)  -> 823.3 ns, the default write class
  localparam integer NS_DEF_W    = 823;
  //   R8_005F 788.4 (line 286): 0x5F reads at the default class
  localparam integer NS_5F_R     = 792;
  // A 0x005F WRITE is posted in both tables (W8_005F's period stays 1744 ns from nop=0 to
  // nop=32), so the CPU-visible access is the FSM floor; the bus time behind it is
  // tb_pc9821_io_5f's and sysclk_invariance's.
  //   R IO R8_006A ... art=116/117/117 ...   (line 316)  -> 349.7 ns, EGC named read
  localparam integer NS_EGC_R    = 350;
  //   W8_006A 314.7, W8_007C/W8_007E/W8_0064 317.9, W8_00A4 314.7 (lines 408, 396, 389, 406,
  //   398) and the EGC file's word write W16_04A8 314.7 (line 412): one fast write class
  localparam integer NS_FAST_W   = 318;
  //   R IO R8_0060 ... art=135/136/136 ...   (line 308)  -> 413.3 ns, text GDC
  localparam integer NS_GDC1_R   = 414;
  //   R IO R8_00A0 ... art=206/207/208 ...   (line 312)  -> 639.0 ns, graphics GDC
  localparam integer NS_GDC2_R   = 639;
  //   R8_0071 791.5: the 8253 reads at the default class
  localparam integer NS_PIT_R    = 792;
  // The 8253 write is not an XE10T row; IO.TXT priced 0x77's write (PITCTL 861.5) at its own
  // default write class (the OPNA's 864.7/861.5), so it is the default write here.
  localparam integer NS_PIT_W    = 823;
  //   R IO R8_04A0 ... art=1888/1890/1898 ... (line 322) -> 5989.1 ns, EGC file EVEN read
  localparam integer NS_EGCF_HI  = 5990;
  //   R8_04A1 791.5 (line 324): the odd addresses read at the default class
  localparam integer NS_EGCF_LO  = 792;
  //   R IO R8_09A0 / R8_09A8 ... art=116/117/117 ... (lines 372, 374) -> 352.9 ns
  localparam integer NS_9A0      = 353;
  //   R IO R8_0FAA ... art=86/87/87 ...      (line 376)  -> 254.3 ns, the fastest port
  localparam integer NS_FAA      = 255;
  // A 16-BIT access costs ONE class: R16_005C 791.5 (line 378) = R8_005C 791.5, R16_0188 788.4
  // (line 380) = R8_0188 791.5, and W16_04A8 314.7 (line 412) = the byte writes' 314.7-317.9.
  localparam integer NS_W16_5C   = 792;
  localparam integer NS_W16_188  = 792;
  // Kit 2's SPEED, the same machine by a third method (docs/probes/KIT2-XE10-SPEED.TXT,
  // speed_decode.py: `IN02 852.31 ns/op net 802.30 ns`, `INA0 700.78 ns/op net 650.77 ns`):
  // `in al,dx` at 0x02 (the default class) and 0xA0 (the graphics GDC) less its dec/jnz shell.
  localparam integer NS_SPEED_IN02 = 802;
  localparam integer NS_SPEED_INA0 = 651;

  // THE CORE CPU'S OWN SHARE OF AN I/O INSTRUCTION, which the Xe10 table takes off the bus so
  // the WHOLE instruction costs the machine's time. A measurement of THIS core, not a hardware
  // fact: the same SPEED binary on the core in Fast (docs/probes/core/KIT2-CORE-SPEED.TXT at
  // the base profile's 90 MHz: `IN02 188.90 ns/op net 133.34 ns` = 12 clk_sys for `in al,dx`)
  // around a Fast access of IO_MIN_HOLD = 4: 12 - 4 = 8 clk_sys. The bench adds it back to
  // what it measures at the bus, so every Xe10 check below is a whole-instruction time against
  // the machine's.
  localparam integer CPU_CYC = 8;

  // Fast's own values, which must not move (the gate's boot and Dhrystone goldens run Fast).
  localparam integer MIN_FLOOR = 4;
  localparam integer MIN_PIT   = 21;      // ceil(one 2.4576 MHz PIT tick): the 8253 WRITE floor
  localparam integer MIN_PIT_R = MIN_FLOOR;

  // ==== DUT ====
  reg clk = 1'b0;
  always #10 clk = ~clk;                  // 20 ns period = 50 MHz

  reg reset = 1'b1;

  localparam integer NM = 23;   // the measurement list in lat_probe (M_* below)
  // ---- three DUTs at one clock: Fast (io_timing_xe10 tied 0), Xe10 (tied 1), and a third
  // ---- whose input the bench FLIPS at run time, with no reset, between two measurement runs.
  wire [15:0] f_c [0:NM-1];
  wire [15:0] x_c [0:NM-1];
  wire [15:0] s_c [0:NM-1];
  wire        f_done, x_done, s_done;
  reg         f_go = 1'b0, x_go = 1'b0, s_go = 1'b0;
  reg         s_xe10 = 1'b0;

  localparam integer M_DEF_R = 0,  M_DEF_W = 1,  M_5F_R = 2,  M_5F_W = 3,
                     M_EGC_R = 4,  M_EGC_W = 5,  M_7E_W = 6,  M_64_W = 7,  M_A4_W = 8,
                     M_GDC1_R = 9, M_GDC2_R = 10, M_PIT_R = 11, M_PIT_W = 12,
                     M_EGCF_EVEN_R = 13, M_EGCF_ODD_R = 14, M_9A0_R = 15, M_9A8_R = 16,
                     M_FAA_R = 17, M_W16_5C = 18, M_W16_188 = 19, M_W16_4A8_W = 20,
                     M_02_R = 21, M_A0_R = 22;

  lat_probe #(.HZ(CLK_HZ), .NM(NM)) p_fast (.clk(clk), .reset(reset), .xe10(1'b0), .go(f_go),
                                            .done(f_done), .c(f_c));
  lat_probe #(.HZ(CLK_HZ), .NM(NM)) p_xe10 (.clk(clk), .reset(reset), .xe10(1'b1), .go(x_go),
                                            .done(x_done), .c(x_c));
  lat_probe #(.HZ(CLK_HZ), .NM(NM)) p_sw   (.clk(clk), .reset(reset), .xe10(s_xe10), .go(s_go),
                                            .done(s_done), .c(s_c));

  // ==== CHECKS ====
  integer errors = 0;
  integer k;

  task automatic fail(input string message);
    begin
      $display("FAIL: %0s", message);
      errors = errors + 1;
    end
  endtask

  function automatic integer ns_of(input integer cycles);
    begin
      ns_of = (cycles * 1000) / (CLK_HZ / 1_000_000);
    end
  endfunction

  // An Xe10 access: the bus cycles the probe counted PLUS the CPU's own share is the whole
  // instruction, which must be the capture's time quantised up by at most `slack` clk_sys and
  // never short of it. A class that fell back to Fast's floor reads 240 ns and fails here.
  task automatic check_x(input string which, input [15:0] cycles, input integer expected_ns,
                         input integer slack);
    integer got;
    begin
      got = ns_of(cycles + CPU_CYC);
      if (got < expected_ns)
        fail($sformatf("Xe10 %0s costs %0d ns (bus %0d clk + CPU %0d), SHORT of the machine's %0d ns",
                       which, got, cycles, CPU_CYC, expected_ns));
      else if (got > expected_ns + slack * CLK_NS)
        fail($sformatf("Xe10 %0s costs %0d ns (bus %0d clk + CPU %0d), more than %0d clk above the machine's %0d ns",
                       which, got, cycles, CPU_CYC, slack, expected_ns));
    end
  endtask

  task automatic check_cyc(input string which, input [15:0] cycles, input integer expected_cyc);
    begin
      if (cycles !== expected_cyc[15:0])
        fail($sformatf("%0s is %0d clk, expected %0d", which, cycles, expected_cyc));
    end
  endtask

  // The SPEED cross-check: the same instruction by a third method on the machine. XE10T and
  // SPEED disagree by a few ns themselves, so the core may sit off SPEED by at most that
  // disagreement plus one clk of quantisation.
  task automatic check_speed(input string which, input [15:0] cycles, input integer xe10t_ns,
                             input integer speed_ns);
    integer got, d, allowed;
    begin
      got = ns_of(cycles + CPU_CYC);
      d = (got > speed_ns) ? got - speed_ns : speed_ns - got;
      allowed = ((xe10t_ns > speed_ns) ? xe10t_ns - speed_ns : speed_ns - xe10t_ns) + CLK_NS;
      if (d > allowed)
        fail($sformatf("Xe10 %0s costs %0d ns against kit 2 SPEED's %0d ns: %0d ns off, more than XE10T's own %0d-ns disagreement plus one clk",
                       which, got, speed_ns, d, allowed - CLK_NS));
      else
        $display("    SPEED %0s: core %0d ns, machine SPEED %0d ns, XE10T %0d ns", which, got,
                 speed_ns, xe10t_ns);
    end
  endtask

  initial begin
    // ==== STIMULUS ====
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 1'b0;
    f_go = 1'b1; x_go = 1'b1; s_go = 1'b1;
    wait (f_done && x_done && s_done);
    // The run-time switch: the third DUT measured Fast; flip its input with NO reset and run
    // the same list again. Its second run must be the Xe10 DUT's, access for access.
    begin : run_one
      reg [15:0] s_fast [0:NM-1];
      for (k = 0; k < NM; k = k + 1) s_fast[k] = s_c[k];
      @(negedge clk);
      s_go = 1'b0;
      wait (!s_done);
      s_xe10 = 1'b1;
      @(negedge clk);
      s_go = 1'b1;
      wait (s_done);
      for (k = 0; k < NM; k = k + 1) begin
        if (s_fast[k] !== f_c[k])
          fail($sformatf("run-time switch, before the flip: measurement %0d is %0d clk, Fast's is %0d", k, s_fast[k], f_c[k]));
        if (s_c[k] !== x_c[k])
          fail($sformatf("run-time switch, after the flip: measurement %0d is %0d clk, Xe10's is %0d", k, s_c[k], x_c[k]));
      end
    end
    repeat (4) @(posedge clk);

    $display("  ---- Fast (io_timing_xe10 0), which the shipped default must keep EXACTLY ----");
    check_cyc("Fast default read",  f_c[M_DEF_R],  MIN_FLOOR);
    check_cyc("Fast default write", f_c[M_DEF_W],  MIN_FLOOR);
    check_cyc("Fast 0x005F read",   f_c[M_5F_R],   MIN_FLOOR);
    check_cyc("Fast 0x005F write",  f_c[M_5F_W],   MIN_FLOOR); // posted: the CPU goes on at once
    check_cyc("Fast EGC 0x6A read", f_c[M_EGC_R],  MIN_FLOOR);
    check_cyc("Fast EGC 0x6A write", f_c[M_EGC_W], MIN_FLOOR);
    check_cyc("Fast 0x007E write",  f_c[M_7E_W],   MIN_FLOOR);
    check_cyc("Fast 0x0064 write",  f_c[M_64_W],   MIN_FLOOR);
    check_cyc("Fast 0x00A4 write",  f_c[M_A4_W],   MIN_FLOOR);
    check_cyc("Fast text GDC read", f_c[M_GDC1_R], MIN_FLOOR);
    check_cyc("Fast gfx GDC read",  f_c[M_GDC2_R], MIN_FLOOR);
    check_cyc("Fast 8253 read",     f_c[M_PIT_R],  MIN_PIT_R);
    check_cyc("Fast 8253 write",    f_c[M_PIT_W],  MIN_PIT);
    check_cyc("Fast EGC file even read", f_c[M_EGCF_EVEN_R], MIN_FLOOR);
    check_cyc("Fast EGC file odd read",  f_c[M_EGCF_ODD_R],  MIN_FLOOR);
    check_cyc("Fast 0x09A0 read",   f_c[M_9A0_R],  MIN_FLOOR);
    check_cyc("Fast 0x09A8 read",   f_c[M_9A8_R],  MIN_FLOOR);
    check_cyc("Fast 0x0FAA read",   f_c[M_FAA_R],  MIN_FLOOR);
    // Fast sums its floors per lane (tb_pc9821_io_class): a word is two.
    check_cyc("Fast word read 0x5C", f_c[M_W16_5C],  2 * MIN_FLOOR);
    check_cyc("Fast word read 0x188", f_c[M_W16_188], 2 * MIN_FLOOR);
    check_cyc("Fast word write 0x4A8", f_c[M_W16_4A8_W], 2 * MIN_FLOOR);
    check_cyc("Fast 0x0002 read",   f_c[M_02_R],   MIN_FLOOR);
    check_cyc("Fast 0x00A0 read",   f_c[M_A0_R],   MIN_FLOOR);

    $display("  ---- Xe10 (io_timing_xe10 1): the machine's whole-instruction times ----");
    check_x("default read",   x_c[M_DEF_R],  NS_DEF_R, 1);
    check_x("default write",  x_c[M_DEF_W],  NS_DEF_W, 1);
    check_x("0x005F read",    x_c[M_5F_R],   NS_5F_R, 1);
    check_cyc("Xe10 0x005F write", x_c[M_5F_W], MIN_FLOOR);   // posted, as in Fast
    check_x("EGC 0x6A read",  x_c[M_EGC_R],  NS_EGC_R, 1);
    check_x("EGC 0x6A write", x_c[M_EGC_W],  NS_FAST_W, 1);
    check_x("0x007E write",   x_c[M_7E_W],   NS_FAST_W, 1);
    check_x("0x0064 write",   x_c[M_64_W],   NS_FAST_W, 1);
    check_x("0x00A4 write",   x_c[M_A4_W],   NS_FAST_W, 1);
    check_x("text GDC read",  x_c[M_GDC1_R], NS_GDC1_R, 1);
    check_x("gfx GDC read",   x_c[M_GDC2_R], NS_GDC2_R, 1);
    check_x("8253 read",      x_c[M_PIT_R],  NS_PIT_R, 1);
    check_x("8253 write",     x_c[M_PIT_W],  NS_PIT_W, 1);
    check_x("EGC file even read", x_c[M_EGCF_EVEN_R], NS_EGCF_HI, 1);
    check_x("EGC file odd read",  x_c[M_EGCF_ODD_R],  NS_EGCF_LO, 1);
    check_x("0x09A0 read",    x_c[M_9A0_R],  NS_9A0, 1);
    check_x("0x09A8 read",    x_c[M_9A8_R],  NS_9A0, 1);
    check_x("0x0FAA read",    x_c[M_FAA_R],  NS_FAA, 1);
    // A word: one class, plus the FSM's one walk cycle for its high lane - so up to two clk
    // above the capture, and FAIL-FIRST against the per-lane sum, which costs two classes.
    check_x("word read 0x5C",  x_c[M_W16_5C],  NS_W16_5C, 2);
    check_x("word read 0x188", x_c[M_W16_188], NS_W16_188, 2);
    check_x("word write 0x4A8", x_c[M_W16_4A8_W], NS_FAST_W, 2);
    check_x("0x0002 read",    x_c[M_02_R],   NS_DEF_R, 1);
    check_x("0x00A0 read",    x_c[M_A0_R],   NS_GDC2_R, 1);
    check_speed("in al,dx 0x02", x_c[M_02_R], NS_DEF_R, NS_SPEED_IN02);
    check_speed("in al,dx 0xA0", x_c[M_A0_R], NS_GDC2_R, NS_SPEED_INA0);
    // Nothing in Xe10 is faster than Fast: the posted 0x5F write is the floor in both, and
    // every other access is slower.
    for (k = 0; k < NM; k = k + 1)
      if (x_c[k] < f_c[k])
        fail($sformatf("Xe10 measurement %0d (%0d clk) is faster than Fast's (%0d clk)", k, x_c[k], f_c[k]));
    $display("    Xe10 bus clk: default %0d/%0d EGC %0d/%0d fast W %0d GDC %0d/%0d 8253 %0d/%0d EGCfile %0d/%0d 9A0 %0d FAA %0d word %0d/%0d/%0d (+%0d CPU)",
             x_c[M_DEF_R], x_c[M_DEF_W], x_c[M_EGC_R], x_c[M_EGC_W], x_c[M_7E_W],
             x_c[M_GDC1_R], x_c[M_GDC2_R], x_c[M_PIT_R], x_c[M_PIT_W],
             x_c[M_EGCF_EVEN_R], x_c[M_EGCF_ODD_R], x_c[M_9A0_R], x_c[M_FAA_R],
             x_c[M_W16_5C], x_c[M_W16_188], x_c[M_W16_4A8_W], CPU_CYC);

    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_IO_LATENCY_PROFILE: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_IO_LATENCY_PROFILE: FAIL (%0d errors)", errors);
  end

  initial begin
    #40_000_000;
    $fatal(1, "TB_PC9821_IO_LATENCY_PROFILE: TIMEOUT");
  end

endmodule

// ------------------------------------------------------------------
// One pc9821_iobus at one I/O timing input, self-driving: on each rising `go` it measures the
// class of every access this bench checks, ONE access at a time, and raises `done` (dropped
// when `go` falls). The count is the io_class idiom (the request is presented on a negedge,
// the count is the negedges waited), so the value stored is the access's whole bus time - the
// FSM's three cycles included.
// ------------------------------------------------------------------
`default_nettype none
module lat_probe #(parameter [31:0] HZ = 32'd50_000_000,
                   parameter integer NM = 23) (
    input  wire        clk,
    input  wire        reset,
    input  wire        xe10,
    input  wire        go,
    output reg         done,
    output reg  [15:0] c [0:NM-1]
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
  wire        dbg_last_io_stb;
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
  wire soft_reboot;   // pc9821_iobus's reboot strobe (0x534)
  wire        fdc_irq;
  wire        fdc_irq10;   // IRQ10: the same FDC interrupt at its 2DD port window
  reg  [3:0]  bios_set = 4'd0;
  // The OSD GDC Clock field (port 0x31 bit 7: 0 = the measured 2.5 MHz strap, 1 = 5 MHz).
  // Static here: this bench is not about the strap and an UNDRIVEN input is 0, which is
  // the machine's own state - tb_pc9821_bios_select and tb_pc9821_userdisk own the field.
  reg  gdc_clock_5m = 1'b0;
  reg  msw_hold = 1'b0;        // port 0x31 bit 4 at the measured machine's memory-switch init (0xF3)
  reg  text_lines_20 = 1'b0;   // port 0x31 bit 3 at the measured 25 lines (0xF3)
  reg  [1:0] floppy_mode = 2'd0;   // Auto (1M), 0x861E = 0xF7: the Floppy mode default
  wire [23:0] setup_cfg;       // the OSD configuration pc9821_cg is built from (unread here)
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
  wire [31:0] dma_mem_addr_nx;   // the address dma_mem_addr loads next, and its load cycle (unused here)
  wire        dma_mem_load;
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
  wire io_timing_xe10 = xe10;
  pc9821_iobus #(.SDIP_WRITES_ENABLED(1), .SYS_CLOCK_HZ(HZ)) dut (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),.*);

  task automatic measure(input [15:0] portnum, input [3:0] be, input wr, output [15:0] cycles);
    integer n;
    begin
      @(negedge clk);
      cpu_addr  = {16'd0, portnum[15:2], 2'b00};
      cpu_be    = be;
      cpu_din   = 32'h0000_0000;
      cpu_write = wr;
      cpu_valid = 1'b1;
      n = 0;
      while (!cpu_ready) begin
        @(negedge clk);
        n = n + 1;
      end
      cycles = n[15:0] - 16'd1;   // the FSM's own three cycles included (the io_class idiom)
      @(negedge clk);
      cpu_valid = 1'b0;
      cpu_write = 1'b0;
      cpu_be    = 4'd0;
      while (dut.state != 0) @(negedge clk);
      repeat (200) @(negedge clk);   // any posted 0x5F bus time is over before the next one
    end
  endtask

  function automatic [3:0] be1(input [15:0] portnum);
    be1 = 4'b0001 << portnum[1:0];
  endfunction

  integer i;
  initial begin
    done = 1'b0;
    for (i = 0; i < NM; i = i + 1) c[i] = 16'd0;
    forever begin
      wait (!reset && go);
      @(negedge clk);
      measure(16'h0EE0, be1(16'h0EE0), 1'b0, c[0]);   // unmapped -> the default class
      measure(16'h0EE0, be1(16'h0EE0), 1'b1, c[1]);
      measure(16'h005F, be1(16'h005F), 1'b0, c[2]);   // the firmware's own I/O-wait port
      measure(16'h005F, be1(16'h005F), 1'b1, c[3]);   // ...and its posted write
      measure(16'h006A, be1(16'h006A), 1'b0, c[4]);   // EGC mode register
      measure(16'h006A, be1(16'h006A), 1'b1, c[5]);
      measure(16'h007E, be1(16'h007E), 1'b1, c[6]);   // the GRCG tile register
      measure(16'h0064, be1(16'h0064), 1'b1, c[7]);   // the CRT interrupt reset
      measure(16'h00A4, be1(16'h00A4), 1'b1, c[8]);   // the display page
      measure(16'h0060, be1(16'h0060), 1'b0, c[9]);   // text GDC
      measure(16'h00A2, be1(16'h00A2), 1'b0, c[10]);  // graphics GDC
      measure(16'h0071, be1(16'h0071), 1'b0, c[11]);  // the 8253
      measure(16'h0071, be1(16'h0071), 1'b1, c[12]);
      measure(16'h04A0, be1(16'h04A0), 1'b0, c[13]);  // EGC register file, even address
      measure(16'h04A1, be1(16'h04A1), 1'b0, c[14]);  // ...and odd
      measure(16'h09A0, be1(16'h09A0), 1'b0, c[15]);  // the PEGC index/data query
      measure(16'h09A8, be1(16'h09A8), 1'b0, c[16]);  // the 24/31 kHz select
      measure(16'h0FAA, be1(16'h0FAA), 1'b0, c[17]);  // the accelerator index port
      measure(16'h005C, 4'b0011, 1'b0, c[18]);        // `in ax,0x5C`: R16_005C
      measure(16'h0188, 4'b0011, 1'b0, c[19]);        // `in ax,0x188`: R16_0188
      measure(16'h04A8, 4'b0011, 1'b1, c[20]);        // `out 0x4A8,ax`: W16_04A8
      measure(16'h0002, be1(16'h0002), 1'b0, c[21]);  // SPEED's IN02: the master PIC's mask
      measure(16'h00A0, be1(16'h00A0), 1'b0, c[22]);  // SPEED's INA0: the graphics GDC status
      done = 1'b1;
      wait (!go);
      done = 1'b0;
    end
  end
endmodule
`default_nettype wire
