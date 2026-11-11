// The CPU-side debug instrument (build_profile.py --dbg-cpu / --dbg-snoop / --dbg-trig): a
// periodic sampler, a physical-address memory snoop and a triggered, frozen instruction trace,
// all on the debug UART through pc9821_dbg_ring and pc9821_dbg_mux. COMPILED OUT in every preset:
// the three parts are generate-if'd by SAMPLER_EN / SNOOP_EN / TRIG_KIND, and system.sv does not
// instantiate the module at all unless one of them is on.
//
// It was built for a Policenauts intro stall (which took a day to find because
// every instrument was a one-off on a scratch branch), and promoted. The method it serves is
// in docs/mister-testing.md, "The debug UART".
//
// RECORDS (all `0xA5, type, ...`, big-endian; the lengths are pc9821_dbg_mux's table):
//   0x20 / 0x21  SAMPLE, 34 bytes, every SAMPLE_MS ms (0x21 = a sample was skipped just before
//                this one, because the previous record was not out yet):
//      0 0xA5  1 type  2-3 ms  4-5 CS  6-7 EIP[15:0]
//      8 acks of vector 0x08 (IRQ0)  9 0x09 (IRQ1)  10 0x0A (IRQ2 VSYNC)  11 other master 0x0B-0x0F
//      12 0x11 (IRQ9 IDE)  13 0x15 (IRQ13 mouse)  14 other slave 0x10-0x17 (not 0x11/0x14/0x15)
//      15 VSYNC IRQ pulses raised  16 port 0x64 writes  17 master IMR  18 master IRR  19 master ISR
//      20 ATA block reads  21 flags {PE, VM, IF, INTR, 4'b0}  22 port 0xA0 reads
//      23 cycles with INTR high in the window, >>12, saturating  24 acks of 0x14 (IRQ12 sound)
//      25 slave IMR  26 slave ISR  27 gate reads at an IDT slot of vector 6 (addr[11:0] == 0x030)
//         or the real-mode IVT entry 0x18 (addr[11:0] == 0x018)  28-29 CS  30-31 EIP[15:0] at the last
//      32 the sample sequence number (low 8 bits; it counts every tick, so a gap is a skipped
//         sample)  33 0x5A
//      Counters are per window and saturate at 0xFF.
//   0x30 / 0x31  SNOOP, 15 bytes: a CPU write accepted into [SNOOP_LO, SNOOP_HI) / a read response
//      beat from it: 0xA5, type, cycle counter [31:0], byte address [31:0], byte enables (a read
//      beat carries {line, burst[2:0]} of its request), data [31:0]
//   0x32  SNOOP LOST, 8 bytes: 0xA5, 0x32, cycle counter of the first loss, events dropped (16
//      bits) - the event queue (256 entries) or the read-request tracker (8 in flight) overflowed,
//      or three events landed in one two-cycle window (the queue takes one entry a cycle). Events
//      are queued in arrival order except that a write and a read beat in the same cycle are
//      swapped for one cycle at most: order by the cycle stamp.
//   0x43  TRACE entry, 15 bytes: 0xA5, 0x43, index (16), CS, EIP (32), SP, EFLAGS[15:0], 0x5A -
//      the frozen ring dumped oldest first, once
//   0x44  TRIGGER, 13 bytes: 0xA5, 0x44, stage, address (32), data (32), byte enables, 0x5A - the
//      event that froze the trace (a PC trigger carries EIP and {16'b0, CS}; an I/O trigger carries
//      {16'b0, port} and {matches since ARM_S [23:0] (saturating), the byte}). The stage byte is
//      {tag[3:0], 1'b0, last, stage[1:0]}: stage 1 or 2, last = 1 in the LAST_MS mode, tag = 4 for
//      the I/O trigger and 0 for the others (whose records are unchanged).
//
// THE TRACE: every instruction issue writes {CS, next EIP, SP, EFLAGS[15:0]} into a 2^TRACE_AW ring.
// (The general registers are not in it: z486 exports no tap for them, and the CPU is the fork's.)
// TRIG_KIND selects the trigger (0 = no trace at all):
//   1 PC      the first issue with CS:EIP == TRIG_CS:TRIG_ADDR
//   2 WRITE   the first CPU write covering the byte at physical TRIG_ADDR
//   3 RELOAD  a CPU write of a nonzero 16-bit word to the even-aligned word at TRIG_ADDR that
//             follows a write of zero to it (the pn-stall method: a stub's header reload)
//   4 IO      the first CPU OUT of the byte TRIG_ADDR[7:0] to the port TRIG_ADDR[23:8] (any byte
//             when TRIG_ADDR[24] is set), seen on the iobus's last-access latch (lio_*), so it
//             covers the ports the iobus answers itself (the FDC) as well as the device bus. The
//             trace entry of the OUT itself is already in the ring when the latch lands.
// LAST_MS != 0 selects the LAST occurrence instead of the first (single stage; PC, WRITE or IO):
// every match re-arms, records POST issues after it and then holds that capture as the candidate
// while recording goes on in a second ring bank (so the next match has its own history); the
// candidate is dumped once LAST_MS ms pass with no further match. A match that comes within the
// POST issues of the previous one restarts the count (the capture follows the later match). The
// dump then carries only the entries written since that bank was last started (at most 2^TRACE_AW).
// Nothing fires before ARM_S seconds have passed (boot-time traffic). With a second stage
// (TRIG2_LO != TRIG2_HI) the first trigger only ARMS the second: the first CPU write into
// [TRIG2_LO, TRIG2_HI) after it is the trigger that counts (pn-stall: the overlay overwrite that
// follows the header reload). POST further issues are recorded after the final trigger, then the
// ring freezes and dumps once, followed by the 0x44 record.
//
// OVERRUN HANDLING. A record starts only when the ring has room for the longest one
// (pc9821_dbg_ring `room`), so a record is whole or absent. Snoop LOST and event records go out
// first, then the sampler's, then the trace dump (an event is the one thing that cannot be re-taken;
// a skipped sample is cheap). A SAMPLE that finds the previous one still waiting (or being
// serialised) is skipped and the next one carries type 0x21; snoop events that cannot be queued
// are counted and reported by a 0x32 record; the trace dump simply waits.
//
// The core's reset does not reach this module (it must keep logging across a guest reset), so
// its state has power-up values only.
`default_nettype none
/* verilator lint_off PROCASSINIT */
// An instrument part that is not built leaves its inputs unread (the CPU's SP/EFLAGS without a
// trace, the memory port without a snoop): the unused inputs are by design.
/* verilator lint_off UNUSEDSIGNAL */
// Likewise a memory whose writer is not built (eq without a snoop, tr without a trigger) is read
// only by dead code, and a window that starts at 0 makes `>= LO` constant: both are by design.
/* verilator lint_off UNDRIVEN */
/* verilator lint_off UNSIGNED */
module pc9821_dbg_cpu #(
    parameter integer LOG_CLK_HZ = 50_000_000,
    parameter integer RING_AW    = 13,
    // the sampler
    parameter integer SAMPLER_EN = 1,
    parameter integer SAMPLE_MS  = 10,
    // the snoop window
    parameter integer SNOOP_EN   = 0,
    parameter [31:0]  SNOOP_LO   = 32'h0,
    parameter [31:0]  SNOOP_HI   = 32'h0,
    // the trace and its triggers
    parameter integer TRIG_KIND  = 0,
    parameter [31:0]  TRIG_ADDR  = 32'h0,
    parameter [15:0]  TRIG_CS    = 16'h0,
    parameter [31:0]  TRIG2_LO   = 32'h0,
    parameter [31:0]  TRIG2_HI   = 32'h0,
    parameter integer ARM_S      = 0,
    parameter integer POST       = 32,
    parameter integer TRACE_AW   = 9,
    parameter integer LAST_MS    = 0
) (
    input  wire        clk,
    input  wire [15:0] cpu_cs,
    input  wire [31:0] cpu_eip,
    input  wire        cpu_pe,
    input  wire        cpu_vm,
    input  wire        cpu_if,
    input  wire        cpu_intr,
    input  wire [15:0] cpu_sp,
    input  wire [15:0] cpu_flags,
    input  wire        inta_ready,
    input  wire [7:0]  inta_vec,
    input  wire        vsync_irq,
    input  wire        io_wr,
    input  wire        io_rd,
    input  wire [15:0] io_addr,
    input  wire [7:0]  imr,
    input  wire [7:0]  irr,
    input  wire [7:0]  isr,
    input  wire [7:0]  s_imr,
    input  wire [7:0]  s_isr,
    input  wire        ata_block_read,
    input  wire        gate_read,
    input  wire [31:0] gate_addr,
    input  wire        issue,
    input  wire [31:0] issue_eip,
    // the iobus's last-access latch (pc9821_iobus dbg_last_io_*): one strobe per landed access
    input  wire        lio_stb,
    input  wire        lio_wr,
    input  wire [15:0] lio_addr,
    input  wire [7:0]  lio_data,
    // the CPU's memory port (accepted requests and response beats)
    input  wire        m_valid,
    input  wire        m_ready,
    input  wire        m_write,
    input  wire [31:0] m_addr,
    input  wire [3:0]  m_be,
    input  wire [7:0]  m_burst,
    input  wire        m_line,
    input  wire [31:0] m_wdata,
    input  wire        m_resp_valid,
    input  wire [31:0] m_rdata,
    output wire [7:0]  log_byte,
    output wire        log_we,
    input  wire        log_accept
);
  localparam integer MS_DIV = LOG_CLK_HZ / 1000;
  localparam integer TRACE_N = 1 << TRACE_AW;
  localparam integer POST_W = (POST < 2) ? 1 : $clog2(POST + 1);
  localparam         HAS_TRACE = (TRIG_KIND != 0);
  localparam         HAS_STAGE2 = (TRIG2_LO != TRIG2_HI);
  localparam [POST_W-1:0] POST_LAST = POST_W'(POST - 1);   // (unused when POST = 0)
  localparam integer EQW = 101;
  localparam [TRACE_AW:0] D_FULL = (TRACE_AW+1)'(TRACE_N);   // the dump has loaded every entry
  localparam         IS_LAST = HAS_TRACE && (LAST_MS != 0);
  localparam integer TAW = TRACE_AW + (IS_LAST ? 1 : 0);      // a second ring bank in the LAST mode

  // ---- time ----
  reg [31:0] ms_div = 32'd0;
  reg [15:0] ms = 16'd0;
  reg        ms_tick = 1'b0;
  always @(posedge clk) begin
    ms_tick <= 1'b0;
    if (ms_div == MS_DIV - 1) begin ms_div <= 32'd0; ms <= ms + 16'd1; ms_tick <= 1'b1; end
    else ms_div <= ms_div + 32'd1;
  end
  reg [31:0] cyc = 32'd0;
  always @(posedge clk) cyc <= cyc + 32'd1;

  // ---- the ring and the serialiser's push port ----
  reg        push;
  reg  [7:0] din;
  wire       room;
  pc9821_dbg_ring #(.AW(RING_AW), .MAX_REC(40)) u_ring (
      .clk(clk), .push(push), .din(din), .room(room),
      .log_byte(log_byte), .log_we(log_we), .log_accept(log_accept));

  // ---- the memory port: accepted writes and read beats ----
  wire acc_rd = m_valid && m_ready && !m_write;
  wire acc_wr = m_valid && m_ready && m_write;

  // the outstanding reads in order: {base address, kind, beats}
  reg [31:0] rq_addr [0:7];
  reg [7:0]  rq_n    [0:7];
  reg [3:0]  rq_k    [0:7];
  reg [2:0]  rq_wp = 3'd0, rq_rp = 3'd0;
  reg [3:0]  rq_cnt = 4'd0;
  reg [3:0]  rd_k = 4'd0;
  reg [31:0] rd_addr = 32'd0;   // the current response's next beat address
  reg [7:0]  rd_left = 8'd0;
  wire [31:0] beat_addr = (rd_left != 8'd0) ? rd_addr : rq_addr[rq_rp];
  wire [3:0]  beat_k    = (rd_left != 8'd0) ? rd_k : rq_k[rq_rp];
  wire        rq_full = (rq_cnt == 4'd8);
  wire        rq_drop = acc_rd && rq_full;     // a ninth read in flight: not tracked
  wire        rd_first = m_resp_valid && (rd_left == 8'd0);
  generate if (SNOOP_EN != 0) begin : g_rq
    always @(posedge clk) begin
      if (acc_rd && !rq_full) begin
        rq_addr[rq_wp] <= m_addr; rq_k[rq_wp] <= {m_line, m_burst[2:0]};
        rq_n[rq_wp] <= (m_burst == 8'd0) ? 8'd1 : m_burst; rq_wp <= rq_wp + 3'd1;
      end
      if (m_resp_valid) begin
        if (rd_left == 8'd0) begin
          rd_k <= rq_k[rq_rp]; rd_addr <= rq_addr[rq_rp] + 32'd4; rd_left <= rq_n[rq_rp] - 8'd1;
          rq_rp <= rq_rp + 3'd1;
        end else begin
          rd_addr <= rd_addr + 32'd4; rd_left <= rd_left - 8'd1;
        end
      end
      rq_cnt <= rq_cnt + ((acc_rd && !rq_full) ? 4'd1 : 4'd0) - (rd_first ? 4'd1 : 4'd0);
    end
  end endgenerate

  // ---- the event queue: {read, cycle, address, be, data} ----
  // The queue takes one entry a cycle. A write accepted and a read beat returned in the SAME cycle
  // both want in: the later one waits one cycle in `hold` (its cycle stamp is its own, so the
  // decoder orders by stamp), and a third entry in that window is the only thing lost.
  (* ramstyle = "M10K" *) reg [EQW-1:0] eq [0:255];
  reg [8:0]  eq_wp = 9'd0, eq_rp = 9'd0;
  reg [15:0] ev_lost = 16'd0;
  reg        lost_clr = 1'b0;
  reg [31:0] lost_cyc = 32'd0;
  wire       in_win_w = (m_addr >= SNOOP_LO) && (m_addr < SNOOP_HI);
  wire       in_win_r = (beat_addr >= SNOOP_LO) && (beat_addr < SNOOP_HI);
  wire       ev_w = SNOOP_EN != 0 && acc_wr && in_win_w;
  wire       ev_r = SNOOP_EN != 0 && m_resp_valid && in_win_r;
  wire       eq_full = (eq_wp - eq_rp) >= 9'd254;
  reg                 hold_v = 1'b0;
  reg  [EQW-1:0]      hold;
  wire [EQW-1:0]      ent_w = {1'b0, cyc, m_addr, m_be, m_wdata};
  wire [EQW-1:0]      ent_r = {1'b1, cyc, beat_addr, beat_k, m_rdata};
  wire                any_ev = hold_v || ev_w || ev_r;
  wire [EQW-1:0]      pick = hold_v ? hold : ev_w ? ent_w : ent_r;
  wire                left_w = hold_v && ev_w;                 // the write still waits after pick
  wire                left_r = (hold_v || ev_w) && ev_r;       // the read still waits after pick
  wire                two_left = left_w && left_r;             // ... both: the read is dropped
  wire [EQW-1:0]      keep = left_w ? ent_w : ent_r;
  generate if (SNOOP_EN != 0) begin : g_eq
    always @(posedge clk) begin
      if (any_ev && !eq_full) begin
        eq[eq_wp[7:0]] <= pick;
        eq_wp <= eq_wp + 9'd1;
      end
      hold_v <= left_w || left_r;
      hold   <= keep;
    end
  end endgenerate
  // loss accounting: a full queue, a third entry in the hold window, a read the tracker could
  // not follow
  wire [1:0] lost_inc = {1'b0, (SNOOP_EN != 0) && any_ev && eq_full} +
                        {1'b0, (SNOOP_EN != 0) && two_left} +
                        {1'b0, (SNOOP_EN != 0) && rq_drop};
  always @(posedge clk) begin
    if (lost_clr) begin
      ev_lost <= {14'd0, lost_inc};          // events lost in the clearing cycle still count
      if (lost_inc != 2'd0) lost_cyc <= cyc;
    end else if (lost_inc != 2'd0) begin
      if (ev_lost == 16'd0) lost_cyc <= cyc;
      ev_lost <= (ev_lost > 16'hFFFC) ? 16'hFFFF : ev_lost + {14'd0, lost_inc};
    end
  end

  // ---- the sampler ----
  localparam [7:0] WIN_LAST = 8'(SAMPLE_MS - 1);
  reg [7:0] win_ms = 8'd0;
  wire sample = SAMPLER_EN != 0 && ms_tick && (win_ms == WIN_LAST);
  always @(posedge clk) if (ms_tick) win_ms <= (win_ms == WIN_LAST) ? 8'd0 : win_ms + 8'd1;
  wire vec_ok = inta_ready && (inta_vec != 8'h00);
  reg [7:0] c0 = 0, c6 = 0, c12 = 0, c1 = 0, c2 = 0, cm = 0, c9 = 0, c13 = 0, cs = 0, cv = 0, c64 = 0, cata = 0, ca0 = 0;
  reg [19:0] chi = 0;
  wire vec6 = gate_read && (gate_addr[11:0] == 12'h030 || gate_addr[11:0] == 12'h018);
  reg [15:0] ud_cs = 16'd0, ud_ip = 16'd0;
  always @(posedge clk) if (SAMPLER_EN != 0 && vec6) begin ud_cs <= cpu_cs; ud_ip <= cpu_eip[15:0]; end
  reg [271:0] s_vec = 272'd0;     // the snapshot the serialiser reads (byte 0 is the MSB)
  reg        s_pend = 1'b0, s_lost = 1'b0;
  reg [7:0]  s_seq = 8'd0;
  wire       s_busy;               // the serialiser is reading s_vec
  wire       take_smp;             // ... and starts on it this cycle
  wire [271:0] s_new = {8'hA5, 8'h20, ms, cpu_cs, cpu_eip[15:0],
      c0, c1, c2, cm, c9, c13, cs, cv, c64, imr, irr, isr, cata,
      cpu_pe, cpu_vm, cpu_if, cpu_intr, 4'b0000, ca0,
      (chi[19:12] == 8'hFF || chi[19]) ? 8'hFF : chi[19:12],
      c12, s_imr, s_isr, c6, ud_cs, ud_ip, s_seq, 8'h5A};
  // A counter cleared at the snapshot restarts from the event of that same cycle, so no event is
  // lost to the window boundary (the sum of a counter over all records is the event total).
  function automatic [7:0] inc2(input [7:0] c, input e, input clr);
    inc2 = (clr ? 8'd0 : c) + ((e && (clr || c != 8'hFF)) ? 8'd1 : 8'd0);
  endfunction
  wire snap = sample && !(s_pend || s_busy);     // this tick takes a snapshot
  always @(posedge clk) if (SAMPLER_EN != 0) begin
    if (take_smp) begin s_pend <= 1'b0; s_lost <= 1'b0; end
    if (sample) begin
      s_seq <= s_seq + 8'd1;                   // every tick counts: a gap in the records is a skipped sample
      // a sample that finds the previous one still waiting or being serialised is skipped (the
      // counters keep accumulating) and the next record carries type 0x21
      if (s_pend || s_busy) s_lost <= 1'b1;
      else begin s_vec <= s_new; s_pend <= 1'b1; end
    end
    c0  <= inc2(c0,  vec_ok && inta_vec == 8'h08, snap);
    c1  <= inc2(c1,  vec_ok && inta_vec == 8'h09, snap);
    c2  <= inc2(c2,  vec_ok && inta_vec == 8'h0A, snap);
    cm  <= inc2(cm,  vec_ok && inta_vec[7:3] == 5'b00001 && inta_vec[2:0] > 3'd2, snap);
    c9  <= inc2(c9,  vec_ok && inta_vec == 8'h11, snap);
    c13 <= inc2(c13, vec_ok && inta_vec == 8'h15, snap);
    cs  <= inc2(cs,  vec_ok && inta_vec[7:3] == 5'b00010 && inta_vec != 8'h11 && inta_vec != 8'h15 && inta_vec != 8'h14, snap);
    c12 <= inc2(c12, vec_ok && inta_vec == 8'h14, snap);
    c6  <= inc2(c6, vec6, snap);
    cv  <= inc2(cv,  vsync_irq, snap);
    c64 <= inc2(c64, io_wr && io_addr == 16'h0064, snap);
    cata <= inc2(cata, ata_block_read, snap);
    ca0 <= inc2(ca0, io_rd && io_addr == 16'h00A0, snap);
    if (snap) chi <= {19'd0, cpu_intr};
    else if (cpu_intr && !chi[19]) chi <= chi + 20'd1;
  end

  // ---- the trace and its triggers ----
  reg        armed = (ARM_S == 0);
  reg [31:0] arm_ms = 32'd0;
  always @(posedge clk) if (HAS_TRACE && !armed && ms_tick) begin
    arm_ms <= arm_ms + 32'd1;
    if (arm_ms + 32'd1 >= ARM_S * 1000) armed <= 1'b1;
  end
  localparam [31:0] WORD_ADDR = {TRIG_ADDR[31:1], 1'b0};
  wire        wr_hit  = acc_wr && m_addr[31:2] == TRIG_ADDR[31:2] && m_be[TRIG_ADDR[1:0]];
  wire        wrd_hit = acc_wr && m_addr[31:2] == WORD_ADDR[31:2] && (|m_be[{WORD_ADDR[1], 1'b0} +: 2]);
  wire [15:0] wrd_val = WORD_ADDR[1] ? m_wdata[31:16] : m_wdata[15:0];
  wire        pc_hit  = issue && cpu_cs == TRIG_CS && issue_eip == TRIG_ADDR;
  wire        io_hit  = lio_stb && lio_wr && lio_addr == TRIG_ADDR[23:8] &&
                        (TRIG_ADDR[24] || lio_data == TRIG_ADDR[7:0]);
  reg         hdr_zero = 1'b0;
  reg         stage1 = 1'b0, tr_trig = 1'b0, tr_frozen = 1'b0;
  reg  [POST_W-1:0] tr_post = {POST_W{1'b0}};
  reg  [1:0]  trg_stage = 2'd0;
  reg  [31:0] trg_addr = 32'd0, trg_data = 32'd0;
  reg  [3:0]  trg_be = 4'd0;
  // the I/O trigger's match count since ARM_S, reported in its record (saturating)
  reg  [23:0] io_cnt = 24'd0;
  wire [23:0] io_cnt_n = (io_cnt == 24'hFFFFFF) ? io_cnt : io_cnt + 24'd1;
  always @(posedge clk) if (TRIG_KIND == 4 && armed && !tr_frozen && io_hit) io_cnt <= io_cnt_n;
  wire [31:0] io_tdata = {io_cnt_n, lio_data};
  wire        s1_fire = HAS_TRACE && !IS_LAST && armed && !stage1 && !tr_trig && !tr_frozen &&
                        ((TRIG_KIND == 1 && pc_hit) ||
                         (TRIG_KIND == 2 && wr_hit) ||
                         (TRIG_KIND == 3 && wrd_hit && wrd_val != 16'd0 && hdr_zero) ||
                         (TRIG_KIND == 4 && io_hit));
  wire        s2_fire = HAS_TRACE && HAS_STAGE2 && stage1 && !tr_trig && !tr_frozen && acc_wr &&
                        m_addr >= TRIG2_LO && m_addr < TRIG2_HI;
  wire        tr_wr = !tr_frozen && issue;
  (* ramstyle = "M10K" *) reg [79:0] tr [0:(1 << TAW)-1];
  reg [TRACE_AW-1:0] tr_wp = {TRACE_AW{1'b0}};
  // the LAST mode's state: the bank being written and how full it is, the held candidate
  reg         rec_bank = 1'b0, cand_bank = 1'b0, in_post = 1'b0, have_cand = 1'b0;
  reg  [TRACE_AW:0]   fill = {(TRACE_AW+1){1'b0}}, cand_fill = {(TRACE_AW+1){1'b0}};
  reg  [TRACE_AW-1:0] cand_wp = {TRACE_AW{1'b0}};
  reg  [31:0] quiet = 32'd0;
  reg  [31:0] lv_addr = 32'd0, lv_data = 32'd0;   // the latest match, until its capture commits
  reg  [3:0]  lv_be = 4'd0;
  reg  [TRACE_AW-1:0] d_rp = {TRACE_AW{1'b0}};    // the dump's read pointer (the serialiser's)
  wire [TAW-1:0] wr_ix, rd_ix;
  generate if (IS_LAST) begin : g_ix2
    assign wr_ix = {rec_bank, tr_wp};
    assign rd_ix = {cand_bank, d_rp};
  end else begin : g_ix1
    assign wr_ix = tr_wp;
    assign rd_ix = d_rp;
  end endgenerate
  generate if (IS_LAST) begin : g_last
    wire l_hit = armed && !tr_frozen &&
                 ((TRIG_KIND == 1 && pc_hit) || (TRIG_KIND == 2 && wr_hit) || (TRIG_KIND == 4 && io_hit));
    wire [TRACE_AW-1:0] wp_n = tr_wp + 1'b1;
    wire [TRACE_AW:0]   fill_n = (fill == D_FULL) ? D_FULL : fill + 1'b1;
    // the capture of the latest match is complete: POST issues after it (POST = 0: at once)
    wire l_commit = in_post && !l_hit && (POST == 0 || (tr_wr && tr_post == POST_LAST));
    always @(posedge clk) begin
      if (tr_wr) begin
        tr[wr_ix] <= {cpu_cs, issue_eip, cpu_sp, cpu_flags};
        tr_wp <= wp_n;
        fill <= fill_n;
        if (in_post) tr_post <= tr_post + 1'b1;
      end
      if (l_hit) begin
        in_post <= 1'b1; tr_post <= {POST_W{1'b0}};   // (the quiet time restarts at the commit)
        lv_addr <= (TRIG_KIND == 1) ? issue_eip : (TRIG_KIND == 4) ? {16'd0, lio_addr} : m_addr;
        lv_data <= (TRIG_KIND == 1) ? {16'd0, cpu_cs} : (TRIG_KIND == 4) ? io_tdata : m_wdata;
        lv_be   <= (TRIG_KIND == 2) ? m_be : 4'd0;
      end else if (l_commit) begin
        // hold this bank as the candidate, record on in the other one from empty
        in_post <= 1'b0; have_cand <= 1'b1; quiet <= 32'd0;
        cand_bank <= rec_bank; cand_wp <= tr_wr ? wp_n : tr_wp; cand_fill <= tr_wr ? fill_n : fill;
        rec_bank <= ~rec_bank; tr_wp <= {TRACE_AW{1'b0}}; fill <= {(TRACE_AW+1){1'b0}};
        trg_stage <= 2'd1; trg_addr <= lv_addr; trg_data <= lv_data; trg_be <= lv_be;
      end else if (have_cand && !in_post && !tr_frozen && ms_tick) begin
        quiet <= quiet + 32'd1;
        if (quiet + 32'd1 >= LAST_MS) tr_frozen <= 1'b1;
      end
    end
  end else if (HAS_TRACE) begin : g_tr
    always @(posedge clk) begin
      if (tr_wr) begin
        tr[wr_ix] <= {cpu_cs, issue_eip, cpu_sp, cpu_flags};
        tr_wp <= tr_wp + 1'b1;
        if (tr_trig) begin
          tr_post <= tr_post + 1'b1;
          if (tr_post == POST_LAST) tr_frozen <= 1'b1;
        end
      end
      if (TRIG_KIND == 3 && armed && wrd_hit && !stage1 && !tr_trig && wrd_val == 16'd0) hdr_zero <= 1'b1;
      if (s1_fire) begin
        trg_stage <= 2'd1;
        trg_addr <= (TRIG_KIND == 1) ? issue_eip : (TRIG_KIND == 4) ? {16'd0, lio_addr} : m_addr;
        trg_data <= (TRIG_KIND == 1) ? {16'd0, cpu_cs} : (TRIG_KIND == 4) ? io_tdata : m_wdata;
        trg_be   <= (TRIG_KIND == 1 || TRIG_KIND == 4) ? 4'd0 : m_be;
        if (HAS_STAGE2) stage1 <= 1'b1; else tr_trig <= 1'b1;
      end
      if (s2_fire) begin
        tr_trig <= 1'b1; trg_stage <= 2'd2; trg_addr <= m_addr; trg_data <= m_wdata; trg_be <= m_be;
      end
      // POST = 0: the freeze follows the trigger without waiting for another issue
      if (POST == 0 && tr_trig) tr_frozen <= 1'b1;
    end
  end endgenerate

  // ---- the serialiser: one record at a time into the ring ----
  localparam [2:0] K_NONE = 3'd0, K_SMP = 3'd1, K_EVT = 3'd2, K_LST = 3'd3, K_TRC = 3'd4, K_TRG = 3'd5;
  reg [2:0]  kind = K_NONE;
  reg [5:0]  bi = 6'd0;
  reg        ld = 1'b0;            // a memory read for the record is in flight (one cycle)
  reg [EQW-1:0] e_cur;
  reg [79:0]  t_cur;
  reg [7:0]   smp_t = 8'h20;
  reg [47:0]  lst_snap = 48'd0;    // {cycle of the first loss, count}, taken when the record starts
  reg [TRACE_AW:0]   d_n = {(TRACE_AW+1){1'b0}};   // entries loaded so far
  // the dump: the whole ring oldest first, or (LAST mode) the candidate bank's filled entries
  wire [TRACE_AW:0]   d_total = IS_LAST ? cand_fill : D_FULL;
  wire [TRACE_AW-1:0] d_start = IS_LAST ? cand_wp - cand_fill[TRACE_AW-1:0] : tr_wp;
  localparam [3:0]    TRG_TAG = (TRIG_KIND == 4) ? 4'd4 : 4'd0;
  localparam [0:0]    TRG_LAST = IS_LAST ? 1'b1 : 1'b0;
  reg        d_state = 1'b0;       // the dump has started
  reg        d_done = 1'b0;
  reg        trg_sent = 1'b0;

  wire [31:0]  ev_cyc  = e_cur[99:68];
  wire [31:0]  ev_addr = e_cur[67:36];
  wire [3:0]   ev_be   = e_cur[35:32];
  wire [31:0]  ev_data = e_cur[31:0];
  wire [119:0] rec_e = {8'hA5, e_cur[100] ? 8'h31 : 8'h30, ev_cyc, ev_addr, 4'h0, ev_be, ev_data};
  wire [63:0]  rec_l = {8'hA5, 8'h32, lst_snap};
  wire [TRACE_AW:0] d_idx_w = d_n - 1'b1;
  wire [15:0]  d_idx = 16'(d_idx_w);
  wire [119:0] rec_t = {8'hA5, 8'h43, d_idx, t_cur, 8'h5A};
  wire [103:0] rec_g = {8'hA5, 8'h44, TRG_TAG, 1'b0, TRG_LAST, trg_stage, trg_addr, trg_data, 4'h0, trg_be, 8'h5A};
  wire [5:0]   k_len = (kind == K_SMP) ? 6'd34 : (kind == K_EVT) ? 6'd15 : (kind == K_LST) ? 6'd8 :
                       (kind == K_TRC) ? 6'd15 : 6'd13;
  assign s_busy = (kind == K_SMP);
  wire eq_empty = (eq_wp == eq_rp);
  wire idle = (kind == K_NONE) && !ld && room;
  wire hi_pend = SNOOP_EN != 0 && (ev_lost != 16'd0 || !eq_empty);   // loss and event records go first
  assign take_smp = SAMPLER_EN != 0 && idle && s_pend && !hi_pend;
  always @* begin
    push = 1'b0; din = 8'h00;
    if (kind != K_NONE && !ld) begin
      push = 1'b1;
      case (kind)
        K_SMP: din = (bi == 6'd1) ? smp_t : s_vec[271 - 8 * bi -: 8];
        K_EVT: din = rec_e[119 - 8 * bi -: 8];
        K_LST: din = rec_l[63 - 8 * bi -: 8];
        K_TRC: din = rec_t[119 - 8 * bi -: 8];
        default: din = rec_g[103 - 8 * bi -: 8];
      endcase
    end
  end
  always @(posedge clk) begin
    lost_clr <= 1'b0;
    if (ld) begin
      ld <= 1'b0;
      if (kind == K_EVT) begin e_cur <= eq[eq_rp[7:0]]; eq_rp <= eq_rp + 9'd1; end
      if (kind == K_TRC) begin t_cur <= tr[rd_ix]; d_rp <= d_rp + 1'b1; d_n <= d_n + 1'b1; end
    end else if (kind != K_NONE) begin
      bi <= bi + 6'd1;
      if (bi == k_len - 6'd1) begin
        if (kind == K_TRG) trg_sent <= 1'b1;
        kind <= K_NONE;
      end
    end else if (room) begin
      bi <= 6'd0;
      if (SNOOP_EN != 0 && ev_lost != 16'd0) begin
        kind <= K_LST; lst_snap <= {lost_cyc, ev_lost}; lost_clr <= 1'b1;
      end else if (SNOOP_EN != 0 && !eq_empty) begin
        kind <= K_EVT; ld <= 1'b1;
      end else if (take_smp) begin
        kind <= K_SMP; smp_t <= s_lost ? 8'h21 : 8'h20;
      end else if (HAS_TRACE && tr_frozen && !d_done) begin
        if (!d_state) begin d_state <= 1'b1; d_rp <= d_start; d_n <= {(TRACE_AW+1){1'b0}}; end
        else if (d_n == d_total) d_done <= 1'b1;
        else begin kind <= K_TRC; ld <= 1'b1; end
      end else if (HAS_TRACE && d_done && !trg_sent) begin
        kind <= K_TRG;
      end
    end
  end
endmodule
/* verilator lint_on UNSIGNED */
/* verilator lint_on UNDRIVEN */
/* verilator lint_on UNUSEDSIGNAL */
/* verilator lint_on PROCASSINIT */
`default_nettype wire
