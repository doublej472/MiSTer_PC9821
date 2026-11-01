`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// The 8259's priority resolver rewrite (the rotate-and-scan of the request, the in-service block and OCW2's level replaced by a mask-and-encode form with no barrel rotators) is cycle-for-cycle identical to the pre-rewrite module (pc9821_pic_ref.sv, the module as of 6b457f7f): over several hundred thousand cycles of random ICW1-ICW4 programming (with and without ICW3/ICW4, AEOI, SFNM, buffered), OCW1 masks, OCW2 commands of every form (non-specific and specific EOI, rotate on/off, set priority, rotate on AEOI), OCW3 (read IRR/ISR, special mask mode), random edge requests on all eight lines and random interrupt acknowledges, for a master-shaped and a cascade-shaped instance with and without the falling-edge withdraw lines, every output (dout, int_out, int_vec, int_irq, int_acked_irq, int_acked_valid and the three debug views) matches on every clk cycle.

// ==== DUT ====
// pc9821_pic vs pc9821_pic_ref, same inputs, two parameterisations. The reference is the
// pre-change text, not a model of the hardware: this bench proves the rewrite did not change
// behaviour; the 8259's behaviour itself is pinned by tb_pc9821_pic, tb_pc9821_pic_cmd and
// tb_pc9821_pic_ref.

module tb_pc9821_pic_equiv;
  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg cs = 0, wr = 0, rd = 0, a0 = 0, inta = 0;
  reg [7:0] din = 0, ir_in = 0;

  `define POUTS(p) \
    wire [7:0] p``_dout, p``_vec, p``_dimr, p``_dirr, p``_disr; \
    wire p``_int, p``_av; wire [2:0] p``_irq, p``_air;

  `POUTS(ma) `POUTS(mr) `POUTS(sa) `POUTS(sr)

  pc9821_pic #(.BASE_VEC(8'h08), .CASCADE_IRQ(7), .WD_MASK(8'h00)) dma_ (
    .clk(clk), .rst_n(rst_n), .cs(cs), .wr(wr), .rd(rd), .a0(a0), .din(din), .dout(ma_dout),
    .ir_in(ir_in), .int_out(ma_int), .int_vec(ma_vec), .int_irq(ma_irq), .int_acked_irq(ma_air),
    .int_acked_valid(ma_av), .inta(inta), .dbg_imr(ma_dimr), .dbg_irr(ma_dirr), .dbg_isr(ma_disr));
  pc9821_pic_ref #(.BASE_VEC(8'h08), .CASCADE_IRQ(7), .WD_MASK(8'h00)) dmr_ (
    .clk(clk), .rst_n(rst_n), .cs(cs), .wr(wr), .rd(rd), .a0(a0), .din(din), .dout(mr_dout),
    .ir_in(ir_in), .int_out(mr_int), .int_vec(mr_vec), .int_irq(mr_irq), .int_acked_irq(mr_air),
    .int_acked_valid(mr_av), .inta(inta), .dbg_imr(mr_dimr), .dbg_irr(mr_dirr), .dbg_isr(mr_disr));
  pc9821_pic #(.BASE_VEC(8'h10), .CASCADE_IRQ(-1), .WD_MASK(8'hA5)) dsa_ (
    .clk(clk), .rst_n(rst_n), .cs(cs), .wr(wr), .rd(rd), .a0(a0), .din(din), .dout(sa_dout),
    .ir_in(ir_in), .int_out(sa_int), .int_vec(sa_vec), .int_irq(sa_irq), .int_acked_irq(sa_air),
    .int_acked_valid(sa_av), .inta(inta), .dbg_imr(sa_dimr), .dbg_irr(sa_dirr), .dbg_isr(sa_disr));
  pc9821_pic_ref #(.BASE_VEC(8'h10), .CASCADE_IRQ(-1), .WD_MASK(8'hA5)) dsr_ (
    .clk(clk), .rst_n(rst_n), .cs(cs), .wr(wr), .rd(rd), .a0(a0), .din(din), .dout(sr_dout),
    .ir_in(ir_in), .int_out(sr_int), .int_vec(sr_vec), .int_irq(sr_irq), .int_acked_irq(sr_air),
    .int_acked_valid(sr_av), .inta(inta), .dbg_imr(sr_dimr), .dbg_irr(sr_dirr), .dbg_isr(sr_disr));

  integer errors = 0, cycles = 0, seed = 7, intacks = 0, eois = 0, rots = 0;
  reg [31:0] x, y;
  wire [63:0] mo_a = {ma_dout, ma_vec, ma_dimr, ma_dirr, ma_disr, 5'd0, ma_irq, 5'd0, ma_air};
  wire [63:0] mo_r = {mr_dout, mr_vec, mr_dimr, mr_dirr, mr_disr, 5'd0, mr_irq, 5'd0, mr_air};
  wire [63:0] so_a = {sa_dout, sa_vec, sa_dimr, sa_dirr, sa_disr, 5'd0, sa_irq, 5'd0, sa_air};
  wire [63:0] so_r = {sr_dout, sr_vec, sr_dimr, sr_dirr, sr_disr, 5'd0, sr_irq, 5'd0, sr_air};

  // stimulus on the falling edge, compare on the rising edge
  always @(negedge clk) begin
    cycles = cycles + 1;
    x = $random(seed);
    y = $random(seed);
    cs <= 1'b0; wr <= 1'b0; rd <= 1'b0; inta <= 1'b0;
    // a command or data write most cycles of the time a few cycles apart
    if (x[3:0] < 4'd3) begin
      cs <= 1'b1; wr <= 1'b1;
      a0 <= x[4];
      case (x[8:5])
        // ICW1 (bit 4) with random LTIM/SNGL/IC4
        4'd0: begin a0 <= 1'b0; din <= {3'b000, 1'b1, y[3], y[2:0]} & 8'h1F; if (y[7:4] == 0) din <= 8'h1F; end
        // OCW2 forms: bit 4 and 3 clear
        4'd1, 4'd2, 4'd3, 4'd4, 4'd5, 4'd6: begin a0 <= 1'b0; din <= {y[7:5], 2'b00, y[2:0]}; eois = eois + 1; if (y[7]) rots = rots + 1; end
        // OCW3: bit 3 set, bit 4 clear
        4'd7, 4'd8: begin a0 <= 1'b0; din <= {1'b0, y[6:5], 2'b01, y[2:0]}; end
        // data port: ICW2/3/4 or IMR (random)
        default: begin a0 <= 1'b1; din <= (x[12:9] < 4'd5) ? 8'h00 : y[7:0]; end
      endcase
    end
    // requests: sparse edges on random lines, held or pulsed
    if (x[20:16] < 5'd6) ir_in <= ir_in ^ (8'h01 << y[18:16]);
    if (x[24:21] == 4'd0) ir_in <= y[31:24];
    // acknowledges
    if (x[28:25] < 4'd2) begin inta <= 1'b1; intacks = intacks + 1; end
    if (x[31:29] == 3'd0) rd <= 1'b1;
  end

  // ==== CHECKS ====
  always @(posedge clk) if (rst_n) begin
    if (mo_a !== mo_r || ma_int !== mr_int || ma_av !== mr_av ||
        so_a !== so_r || sa_int !== sr_int || sa_av !== sr_av) begin
      errors = errors + 1;
      if (errors < 10)
        $display("FAIL cycle %0d: master int %b/%b vec %02h/%02h irq %0d/%0d isr %02h/%02h irr %02h/%02h | slave int %b/%b vec %02h/%02h irq %0d/%0d isr %02h/%02h",
                 cycles, ma_int, mr_int, ma_vec, mr_vec, ma_irq, mr_irq, ma_disr, mr_disr, ma_dirr, mr_dirr,
                 sa_int, sr_int, sa_vec, sr_vec, sa_irq, sr_irq, sa_disr, sr_disr);
    end
  end

  // ==== VERDICT ====
  integer pass, k;
  integer asserted = 0;
  always @(posedge clk) if (ma_int || sa_int) asserted = asserted + 1;
  initial begin
    for (pass = 0; pass < 12; pass = pass + 1) begin
      seed = 31 * pass + 5;
      rst_n = 0; ir_in = 0;
      repeat (4) @(posedge clk);
      rst_n <= 1;
      repeat (40000) @(posedge clk);
    end
    if (intacks < 1000 || eois < 1000 || rots < 100 || asserted < 1000)
      $fatal(1, "TB_PC9821_PIC_EQUIV: the stimulus did not exercise the resolver (acks %0d, OCW2 %0d, rotates %0d, INT cycles %0d)",
             intacks, eois, rots, asserted);
    if (errors != 0) $fatal(1, "TB_PC9821_PIC_EQUIV: %0d mismatches over %0d cycles", errors, cycles);
    $display("TB_PC9821_PIC_EQUIV: PASS");
    $display("NOTE pic_equiv: %0d cycles, %0d acks, %0d OCW2, %0d INT cycles, identical", cycles, intacks, eois, asserted);
    $finish;
  end
endmodule
