`timescale 1ns/1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_Z486_SIGMA_EQUIV: the CYCLE-EXACT EQUIVALENCE contract for the z486 data_unit SIGMA next-state arm mux - the REFACTOR pin for the Class-1 cut-3 flatten (the sink of the vipt_load_wb_dst_r -> data_unit|sigma family), a CHARACTERIZATION against the documented semantics and not a hardware claim. sigma captures the documented next-state on EVERY clock edge across the full arm space and its overlaps: the stack-pointer advance (forwarded_esp +/- 2/4, 16/32-bit stack, both directions, wrap cases directed), the gate arm, the two shift arms, the 17-arm aluop->alu_result class, the 8-arm muldiv class gated by muldiv_sigma_write (a documented NO-OP/hold when the gate is low), the unlisted-aluop hold, and the any_fault override over everything. The internal arm VALUES are driven with force (the x87_pulse_race idiom) so the golden is independent arithmetic over chosen values. Blind spots stated: not a hardware bench, the z486.sv forwarded_esp arm mux is pinned by its in-tree FWD-ESP FUSE in every simulation, the ALU/shifter/muldiv engines are forced at their results.
//
// TB_PC9821_Z486_SIGMA_EQUIV: a CYCLE-EXACT EQUIVALENCE (characterization,
// not a hardware claim) bench for the z486 data_unit SIGMA next-state arm
// mux - the sink of the vipt_load_wb_dst_r -> data_unit|sigma family the
// Class-1 cut-3 flatten restructures (the serial priority chain stack >
// gate > exec(shift > 17-arm aluop case) > hold becomes parallel one-hot
// class selects + one AND-OR merge). `sigma` is bit-identical on EVERY
// capture edge to a golden computed from the documented semantics.
//
// THE CONTRACT, asserted by NAME:
//  [sigma-capture-identity] `sigma` captures the documented next-state on
//     every clock edge across the FULL arm space and its overlaps: the
//     stack-pointer advance (forwarded_esp +/- 2/4, 16/32-bit stack, both
//     directions), the gate arm ({16'd0, tmpc[31:16]}), the two shift arms,
//     the 17-arm aluop -> alu_result class, the 8-arm muldiv class gated by
//     muldiv_sigma_write (a NO-OP when the gate is low - the register HOLDS),
//     the default hold, and the any_fault override (which wins over
//     everything), in one clock.
//
// THE GOLDEN MODEL never reads the DUT. The internal arm VALUES (alu_result,
// shift_setup_result, shift_result, muldiv_sigma_value and tmpc) are driven
// with `force` - the `force` idiom used by the other equivalence benches - so the golden's
// arithmetic is over values the bench itself chose, and the arm CLASSES come
// from the z486_pkg ALUJMP_* decode (the documented aluop classification).
//
// WHAT IT IS BLIND TO, stated: (1) it is not a hardware-behaviour bench - no
// NP2kai value is asserted here; (2) the z486.sv `forwarded_esp` arm mux is
// upstream of this module and is pinned by its in-tree FWD-ESP FUSE assertion
// (runs in every simulation: boot golden, z486 suite, Dhrystone), where the
// bench instead drives forwarded_esp directly; (3) the ALU/shifter/muldiv
// engines themselves are forced at their results, not exercised.

`default_nettype none

module tb_pc9821_z486_sigma_equiv;
  import z486_pkg::*;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset_n = 0;
  reg [31:0] cyc = 0;
  always @(posedge clk) cyc <= cyc + 32'd1;

  integer errors = 0;
  integer checks = 0;

  task automatic fail(input string what, input [31:0] got, input [31:0] want);
    begin
      errors = errors + 1;
      $display("FAIL [sigma-capture-identity] %s at cyc=%0d got=%08x want=%08x",
               what, cyc, got, want);
      if (errors > 16) begin
        $display("TB_PC9821_Z486_SIGMA_EQUIV: FAIL (too many mismatches)");
        $fatal(1, "sigma capture identity broken");
      end
    end
  endtask

  // ==== DUT: data_unit (only the sigma cone is driven/observed) ====
  reg         instr_start = 0;
  reg         stack_op = 0, stack_dir = 0, stack_data32 = 0, stack32 = 0;
  reg         gate_detect = 0;
  reg         any_fault = 0;
  reg         exec = 0;
  reg  [1:0]  shift_sigma_sel = 0;
  reg  [6:0]  aluop = 0;
  reg  [31:0] forwarded_esp = 0;
  wire [31:0] sigma;

  // ==== DUT ====
  data_unit dut (
    .clk(clk), .reset_n(reset_n),
    .exec(exec), .instr_start(instr_start),
    .stack_op(stack_op), .stack_dir(stack_dir),
    .stack_data32(stack_data32), .stack32(stack32),
    .gate_detect(gate_detect), .any_fault(any_fault),
    .aluop(aluop), .shift_sigma_sel(shift_sigma_sel),
    .forwarded_esp(forwarded_esp),
    // op_size and the registered decode z486 drives beside it (data_unit's
    // fuse holds them equal); the sigma cone reads neither.
    .op_size(2'd0), .op_size_is0(1'b1), .op_size_is1(1'b0),
    .sigma(sigma)
  );

  // forced internal arm values (the bench chooses them; the golden is exact)
  reg [31:0] v_alu = 0, v_shs = 0, v_shr = 0, v_mv = 0, v_tmpc = 0;
  reg        v_mw = 0;

  // ==== golden: the documented sigma next-state ====
  reg [31:0] g_sigma = 0;

  function automatic logic sigma_alu_class(input logic [6:0] op);
    sigma_alu_class =
        (op == ALUJMP_ALU)    || (op == ALUJMP_INCDEC) || (op == ALUJMP_IMCS) ||
        (op == ALUJMP_SZ_EXT) || (op == ALUJMP_AND)    || (op == ALUJMP_OR)   ||
        (op == ALUJMP_XOR)    || (op == ALUJMP_SIGN)   || (op == ALUJMP_ADD)  ||
        (op == ALUJMP_ADC)    || (op == ALUJMP_SUB)    || (op == ALUJMP_CMP)  ||
        (op == ALUJMP_PASS)   || (op == ALUJMP_PASS2)  ||
        (op == ALUJMP_AAAAAS) || (op == ALUJMP_DAADAS) || (op == ALUJMP_SERECO);
  endfunction

  function automatic logic sigma_mul_class(input logic [6:0] op);
    sigma_mul_class =
        (op == ALUJMP_IMUL3)  || (op == ALUJMP_IMUL4) || (op == ALUJMP_SZ_EX2) ||
        (op == ALUJMP_DIV5)   || (op == ALUJMP_PREDIV) || (op == ALUJMP_IDIV1) ||
        (op == ALUJMP_IDIV2)  || (op == ALUJMP_DIV7);
  endfunction

  function automatic [31:0] sigma_next_gold(input [31:0] cur);
    reg [31:0] nxt; reg [15:0] new_sp; reg [31:0] delta;
    begin
      nxt = cur;                    // documented hold
      if (instr_start && stack_op) begin
        delta = stack_data32 ? 32'd4 : 32'd2;
        if (stack32)
          nxt = stack_dir ? forwarded_esp + delta : forwarded_esp - delta;
        else begin
          new_sp = stack_dir ? forwarded_esp[15:0] + delta[15:0]
                             : forwarded_esp[15:0] - delta[15:0];
          nxt = {forwarded_esp[31:16], new_sp};
        end
      end else if (gate_detect) begin
        nxt = {16'd0, v_tmpc[31:16]};
      end else if (exec) begin
        if (shift_sigma_sel == 2'd1) nxt = v_shs;
        else if (shift_sigma_sel == 2'd2) nxt = v_shr;
        else if (sigma_alu_class(aluop)) nxt = v_alu;
        else if (sigma_mul_class(aluop) && v_mw) nxt = v_mv;
      end
      if (any_fault) nxt = 32'd0;   // documented final override
      sigma_next_gold = nxt;
    end
  endfunction

  // ==== stimulus (deterministic) ====
  reg [31:0] rng = 32'h5eed_1234;
  function automatic [31:0] rnd;
    begin
      rng = rng ^ (rng << 13); rng = rng ^ (rng >> 17); rng = rng ^ (rng << 5);
      rnd = rng;
    end
  endfunction

  // documented wrap-heavy operands for the stack arm
  function automatic [31:0] wrap_operand(input integer sel);
    case (sel % 8)
      0: wrap_operand = 32'h0000_ffff;
      1: wrap_operand = 32'h0000_0002;
      2: wrap_operand = 32'h0000_fffe;
      3: wrap_operand = 32'hffff_ffff;
      4: wrap_operand = 32'h0000_0004;
      5: wrap_operand = 32'h8000_0000;
      6: wrap_operand = 32'h7fff_ffff;
      default: wrap_operand = 32'h0001_0000;
    endcase
  endfunction

  localparam integer DIRECTED = 40;

  // ==== CHECKS ====
  task automatic drive_cycle(input integer mode);
    reg [31:0] r0, r1;
    begin
      r0 = rnd(); r1 = rnd();
      instr_start = 0; stack_op = 0; gate_detect = 0; exec = 0; any_fault = 0;
      shift_sigma_sel = 2'd0; aluop = 7'd0;
      if (mode < DIRECTED) begin
        // directed: one arm per cycle plus deliberate overlaps
        case (mode % 5)
          0: begin
            instr_start = 1; stack_op = 1;
            stack_dir = mode[2]; stack_data32 = mode[3]; stack32 = mode[4];
            forwarded_esp = wrap_operand(mode);
          end
          1: begin gate_detect = 1; end
          2: begin
            exec = 1;
            shift_sigma_sel = mode[1:0];
            aluop = sigma_alu_class(mode * 3) ? (mode * 3) : ALUJMP_ADD;
          end
          3: begin
            exec = 1; shift_sigma_sel = 2'd0;
            aluop = sigma_mul_class(mode * 5) ? (mode * 5) : ALUJMP_DIV5;
            v_mw = mode[0];
          end
          default: begin
            // overlap: stack wins over gate/exec; fault wins over all
            instr_start = 1; stack_op = 1; gate_detect = 1; exec = 1;
            any_fault = mode[0];
            stack_dir = mode[1]; stack_data32 = 1; stack32 = mode[2];
            forwarded_esp = wrap_operand(mode);
            shift_sigma_sel = 2'd2;
            aluop = ALUJMP_ADD;
          end
        endcase
      end else begin
        instr_start = r0[0]; stack_op = r0[1]; stack_dir = r0[2];
        stack_data32 = r0[3]; stack32 = r0[4];
        gate_detect = r0[5]; exec = r0[6]; any_fault = r0[7];
        shift_sigma_sel = r0[9:8];
        case (r0[12:10])
          0: aluop = ALUJMP_ADD;
          1: aluop = ALUJMP_ALU;
          2: aluop = ALUJMP_SERECO;
          3: aluop = ALUJMP_DIV5;
          4: aluop = ALUJMP_IMUL3;
          5: aluop = ALUJMP_IDIV2;
          6: aluop = ALUJMP_CMP;
          default: aluop = 7'h40;  // unlisted encoding: documented hold
        endcase
        forwarded_esp = wrap_operand(r0[15:13]);
        v_mw = r0[16];
      end
      v_alu = r0; v_shs = r1; v_shr = {r1[15:0], r0[31:16]};
      v_mv = {r0[7:0], r1[31:8]}; v_tmpc = {r1[23:0], r0[31:24]};
    end
  endtask

  // drive at negedge, check the capture at the following posedge+1
  integer i;
  initial begin
    reset_n = 0;
    repeat (4) @(negedge clk);
    reset_n = 1;
    force dut.alu_result = v_alu;
    force dut.shift_setup_result = v_shs;
    force dut.shift_result = v_shr;
    force dut.muldiv_sigma_write = v_mw;
    force dut.muldiv_sigma_value = v_mv;
    force dut.tmpc = v_tmpc;
    for (i = 0; i < DIRECTED + 20000; i = i + 1) begin
      @(negedge clk);
      drive_cycle(i);
    end
    @(negedge clk);
    release dut.alu_result;
    release dut.shift_setup_result;
    release dut.shift_result;
    release dut.muldiv_sigma_write;
    release dut.muldiv_sigma_value;
    release dut.tmpc;
    @(negedge clk);
    // ==== VERDICT ====
    if (errors != 0) begin
      $display("TB_PC9821_Z486_SIGMA_EQUIV: FAIL (%0d mismatches in %0d checks)",
               errors, checks);
      $fatal(1, "sigma capture identity broken");
    end
    $display("z486_sigma_equiv: %0d checks, %0d cycles", checks, cyc);
    $display("TB_PC9821_Z486_SIGMA_EQUIV: PASS");
    $finish;
  end

  // The edge capture: the golden next-state is computed from the PRE-edge
  // inputs (stable through the edge) and compared against the captured
  // register after it.
  always @(posedge clk) begin
    #1;
    if (!reset_n) begin
      g_sigma = 0;
    end else begin
      checks = checks + 1;
      g_sigma = sigma_next_gold(g_sigma);
      if (sigma !== g_sigma)
        fail("sigma", sigma, g_sigma);
    end
  end
endmodule

`default_nettype wire
