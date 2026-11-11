// PC-9821 floppy-controller log: a DEBUG INSTRUMENT (build_profile.py --dbg-fdc, DBG_FDC_EN).
//
// Every guest access to the floppy controller's ports, the controller's interrupt line and the
// guest's DMA programming go out on the debug UART as seven-byte records, so a hardware session
// shows exactly where a floppy driver stops (the Windows 95 HSFLOP.PDR hang that DOS's INT 1Bh
// never shows) without simulating the guest.
//
// Record: 0xA5, type, a 24-bit time in 10 us units (big-endian, wraps after 167 s; the decoder
// unwraps it), two value bytes a, b.
//   type 0x50  a write to the FDC data port (0x92 / 0xCA): a = the byte (command or parameter),
//              b = the controller's state before it (pc9821_fdc dbg_state: {IRQ, DRQ, st, x_st})
//   type 0x51  a read of the FDC data port: a = the byte the CPU received (a result byte, or a
//              PIO data byte), b = the controller state
//   type 0x52  an MSR read (0x90 / 0xC8) whose value differs from the previous MSR read: a = the
//              new value, b = how many reads of the PREVIOUS value went unlogged before it
//              (saturating at 255) - a polling loop is one record per change, not one per read
//   type 0x53  the controller's interrupt line changed: a = the new level (0/1), b = state
//   type 0x54  a control-register access: a = the byte, b = the register: 0 0x94, 1 0xCC,
//              2 0xBE, 3 0x4BE, 4 0xBF; | 0x80 for a read (a = the byte the CPU received)
//   type 0x55  a DMA-controller write the floppy channel depends on: a = the port's low byte
//              (0x09/0x0B channel 2 address/count, 0x11 command, 0x13 request, 0x15 single
//              mask, 0x17 mode, 0x19 flip-flop clear, 0x1B master clear, 0x1D clear mask, 0x1F
//              all-mask, 0x23 channel 2 bank, 0x29 bank mode, 0x39 = port 0x0439), b = the byte
//   type 0x56  a DMA-controller read of 0x09/0x0B/0x11 (address, count, status): a = port, b = byte
//   type 0x5E  LOST: the records dropped since the last one that got out (a = count)
//   type 0x5F  ALIVE: a = 0x5A, at power-up and at the end of every core reset
//
// The I/O event is pc9821_iobus's last-access latch (dbg_last_io_*), taken in the cycle its
// strobe says a new access landed; an access is tens of clocks long, so a seven-cycle record
// never overlaps the next access. An interrupt edge that coincides with an access, or with a
// record in progress, is held in `q_irq` and logged after it (R4/R7); a second edge before the
// first is out is counted LOST (R5). A full ring counts LOST too, and a LOST record follows.
`default_nettype none
// Power-up values on the log's own state (no core reset reaches the instrument's clock or ring
// pointers: it must keep logging across a guest reset).
/* verilator lint_off PROCASSINIT */
module pc9821_fdc_log #(
    parameter integer LOG_CLK_HZ = 50_000_000
) (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        io_stb,      // one cycle: a new access landed in the io_* latch
    input  wire        io_wr,       // 1 = a write, 0 = a read
    input  wire [15:0] io_addr,
    input  wire [7:0]  io_data,
    input  wire        fdc_irq,     // the controller's interrupt line (either window)
    input  wire [7:0]  fdc_state,   // pc9821_fdc dbg_state
    output wire [7:0]  log_byte,
    output wire        log_we,
    input  wire        log_accept
);
  localparam integer TDIV = LOG_CLK_HZ / 100_000;   // 10 us
  reg [31:0] tdiv = 32'd0;
  reg [23:0] t = 24'd0;
  always @(posedge clk) begin
    if (tdiv == TDIV - 1) begin tdiv <= 32'd0; t <= t + 24'd1; end
    else tdiv <= tdiv + 32'd1;
  end

  // ---- the port decode (the address qualifier on the latch's strobe) ----
  wire p_data = (io_addr == 16'h0092) || (io_addr == 16'h00CA);
  wire p_msr  = (io_addr == 16'h0090) || (io_addr == 16'h00C8);
  reg  [2:0] ctl;      // control register code, 3'd7 = none
  always @* begin
    case (io_addr)
      16'h0094: ctl = 3'd0;  16'h00CC: ctl = 3'd1;  16'h00BE: ctl = 3'd2;
      16'h04BE: ctl = 3'd3;  16'h00BF: ctl = 3'd4;  default:  ctl = 3'd7;
    endcase
  end
  wire p_dmaw = (io_addr == 16'h0009) || (io_addr == 16'h000B) ||
                ((io_addr[15:5] == 11'd0) && (io_addr[4] == 1'b1) && io_addr[0]) ||   // 0x11..0x1F odd
                (io_addr == 16'h0023) || (io_addr == 16'h0029) || (io_addr == 16'h0439);
  wire p_dmar = (io_addr == 16'h0009) || (io_addr == 16'h000B) || (io_addr == 16'h0011);

  reg  [7:0] msr_last = 8'h00;
  reg        msr_seen = 1'b0;
  reg  [7:0] msr_cnt  = 8'd0;
  wire msr_rd   = io_stb && !io_wr && p_msr;
  wire msr_new  = msr_rd && (!msr_seen || (io_data != msr_last));

  // The event this access makes, if any: its type and two value bytes.
  reg        e_want;
  reg  [7:0] e_type, e_a, e_b;
  always @* begin
    e_want = 1'b0; e_type = 8'h00; e_a = io_data; e_b = fdc_state;
    if (io_stb) begin
      if (p_data) begin
        e_want = 1'b1; e_type = io_wr ? 8'h50 : 8'h51;
      end else if (msr_new) begin
        e_want = 1'b1; e_type = 8'h52; e_b = msr_cnt;
      end else if (ctl != 3'd7) begin
        e_want = 1'b1; e_type = 8'h54; e_b = {!io_wr, 4'd0, ctl};
      end else if (io_wr && p_dmaw) begin
        e_want = 1'b1; e_type = 8'h55; e_a = io_addr[7:0]; e_b = io_data;
      end else if (!io_wr && p_dmar) begin
        e_want = 1'b1; e_type = 8'h56; e_a = io_addr[7:0]; e_b = io_data;
      end
    end
  end

  // The interrupt line's edges, queued (one deep) until the stage is free.
  reg  irq_d = 1'b0;
  reg  q_irq = 1'b0;
  reg  q_lvl = 1'b0;
  reg  [7:0] q_st = 8'h00;
  wire irq_edge = (fdc_irq != irq_d);

  reg        p_alive = 1'b1;   // power-up
  reg        rst_d = 1'b1;   // no ALIVE of its own for a power-up already out of reset
  reg  [7:0] lost = 8'd0;
  reg        busy = 1'b0;
  reg  [2:0] r_i = 3'd0;
  reg  [7:0] r_type = 8'd0, r_a = 8'd0, r_b = 8'd0;
  reg [23:0] r_t = 24'd0;
  wire       room;
  reg  [7:0] r_byte;
  always @* begin
    case (r_i)
      3'd0: r_byte = 8'hA5;
      3'd1: r_byte = r_type;
      3'd2: r_byte = r_t[23:16];
      3'd3: r_byte = r_t[15:8];
      3'd4: r_byte = r_t[7:0];
      3'd5: r_byte = r_a;
      default: r_byte = r_b;
    endcase
  end

  // What the stage takes this cycle (one record at a time, the access first).
  wire take_e   = !busy && e_want && rst_n && room;
  wire take_q   = !busy && !take_e && q_irq && room;
  wire take_al  = !busy && !take_e && !take_q && p_alive && rst_n && room;
  wire take_lo  = !busy && !take_e && !take_q && !take_al && (lost != 8'd0) && room;
  // Records that cannot be taken: an access event that finds the stage busy or the ring full,
  // and an interrupt edge that finds the one-deep queue still holding the previous edge (and
  // that queue entry not leaving this cycle).
  wire drop_e   = e_want && rst_n && !take_e;
  wire drop_q   = irq_edge && q_irq && !take_q;
  wire [1:0] n_drop = {1'b0, drop_e} + {1'b0, drop_q};

  always @(posedge clk) begin
    rst_d <= rst_n;
    irq_d <= fdc_irq;
    // the MSR run: every MSR read counts, a changed value restarts the count
    if (msr_rd) begin
      msr_last <= io_data;
      msr_seen <= 1'b1;
      msr_cnt  <= msr_new ? 8'd0 : ((msr_cnt == 8'hFF) ? 8'hFF : msr_cnt + 8'd1);
    end
    // the interrupt queue: an edge sets it (set-wins over the stage taking the old one, R3)
    if (irq_edge) begin q_irq <= 1'b1; q_lvl <= fdc_irq; q_st <= fdc_state; end
    else if (take_q) q_irq <= 1'b0;
    if (rst_n && !rst_d) p_alive <= 1'b1;
    else if (take_al) p_alive <= 1'b0;
    // LOST: one merged count of this cycle's drops and the LOST record's own drain (R4)
    if (take_lo)
      lost <= {6'd0, n_drop};
    else if (n_drop != 2'd0)
      lost <= ((lost + {6'd0, n_drop}) < lost) ? 8'hFF : lost + {6'd0, n_drop};
    // the stage
    if (take_e) begin
      busy <= 1'b1; r_i <= 3'd0; r_t <= t; r_type <= e_type; r_a <= e_a; r_b <= e_b;
    end else if (take_q) begin
      busy <= 1'b1; r_i <= 3'd0; r_t <= t; r_type <= 8'h53; r_a <= {7'd0, q_lvl}; r_b <= q_st;
    end else if (take_al) begin
      busy <= 1'b1; r_i <= 3'd0; r_t <= t; r_type <= 8'h5F; r_a <= 8'h5A; r_b <= 8'h00;
    end else if (take_lo) begin
      busy <= 1'b1; r_i <= 3'd0; r_t <= t; r_type <= 8'h5E; r_a <= lost; r_b <= 8'h00;
    end else if (busy) begin
      r_i <= r_i + 3'd1;
      if (r_i == 3'd6) busy <= 1'b0;
    end
  end

  // the ring and its drain to the UART FIFO
  pc9821_dbg_ring #(.AW(11), .MAX_REC(16)) u_ring (
      .clk(clk), .push(busy), .din(r_byte), .room(room),
      .log_byte(log_byte), .log_we(log_we), .log_accept(log_accept));
endmodule
/* verilator lint_on PROCASSINIT */
`default_nettype wire
