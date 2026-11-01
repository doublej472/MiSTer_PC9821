`timescale 1ns/1ns
// Unit bench for gpr_write_merge.  The module is the single arbitration for the
// register producers that can be in flight at once, so these cases pin the
// rules the commit path and every forwarding view now share:
//   * the younger producer wins the byte lanes it owns,
//   * byte lanes it does not own keep the older producer's value,
//   * views differ only in visibility, never in order,
//   * an M3 ALU result is committed but never forwarded.
module tb_gpr_write_merge;
    import z486_pkg::*;

    // Must match the masks data_unit wires.  The recipe commits (bits 7:5) are
    // consolidated for the register-file write (pulse_value/pulse_wmask) but are
    // deliberately NOT forwarded, so no view mask sets them.
    localparam logic [7:0] VIS_EX  = 8'b0000_1010;   // mem, wb
    localparam logic [7:0] VIS_EA  = 8'b0001_1001;   // shift, wb, dly
    localparam logic [7:0] VIS_CAP = 8'b0001_1011;   // shift, mem, wb, dly

    logic [255:0] cur;
    logic         v_shift, v_mem, v_rom, v_wb, v_dly;
    logic [2:0]   dst_shift, dst_mem, dst_rom, dst_wb, dst_dly;
    logic [1:0]   size_shift, mode_mem, size_rom, size_wb, mode_dly;
    logic [31:0]  data_shift, data_mem, data_rom, data_wb, data_dly;
    logic         wb_is_alu;
    // The plain loaded value the views forward: data_wb on a plain write-back
    // (the contract), a distinct value under an M3 ALU result so a view that
    // forwarded it would fail the "not forwarded" checks.
    wire  [31:0]  fwd_wb = wb_is_alu ? ~data_wb : data_wb;
    logic         v_stos, v_sigsrc, v_esp;
    logic [2:0]   dst_sigsrc;
    logic [1:0]   size_stos, size_sigsrc;
    logic [31:0]  data_stos, data_sigsrc, data_esp;
    logic [255:0] commit_value, commit_wmask, pulse_value, pulse_wmask;
    logic [255:0] ex_value, ea_value, cap_value;
    logic [2:0]   cap_sel_a = 3'd0, cap_sel_b = 3'd0;
    logic [31:0]  cap_a_value, cap_b_value;
    logic [2:0]   ea_sel_a = 3'd0, ea_sel_b = 3'd0;
    logic [31:0]  ea_a_value, ea_b_value;
    logic [2:0]   ex_sel_a = 3'd0, ex_sel_b = 3'd0, ex_sel_c = 3'd0, ex_sel_d = 3'd0, ex_sel_e = 3'd0;
    logic [31:0]  ex_a_value, ex_b_value, ex_c_value, ex_d_value, ex_e_value;

    integer failures = 0;

    // The caller registers producer 3's view hits with the write-back
    // (data_access vipt_load_wb_view_hit_r); the bench forms them from its stimulus.
    // Producer 1's hits, which data_unit registers with the memory token
    // (recipe_memory_hit_r); EA_FWD_BLO/BHI/W/D are 0/1/2/3.
    function automatic [31:0] mem_hit_of(input v, input [2:0] dst, input [1:0] mode);
        logic [2:0] r;
        logic [3:0] be;
        begin
            r  = (mode <= 2'd1) ? {1'b0, dst[1:0]} : dst;
            be = (mode == 2'd0) ? 4'h1 : (mode == 2'd1) ? 4'h2 : (mode == 2'd2) ? 4'h3 : 4'hF;
            mem_hit_of = v ? ({28'h0, be} << {r, 2'b00}) : 32'h0;
        end
    endfunction
    function automatic [31:0] wb_view_hit_of(input v, input [2:0] dst, input [1:0] size, input is_alu);
        logic [2:0] r;
        logic [3:0] be;
        begin
            r  = (size == 2'd0) ? {1'b0, dst[1:0]} : dst;
            be = (size == 2'd0) ? (dst[2] ? 4'h2 : 4'h1) : (size == 2'd1) ? 4'h3 : 4'hF;
            wb_view_hit_of = (v && !is_alu) ? ({28'h0, be} << {r, 2'b00}) : 32'h0;
        end
    endfunction

    gpr_write_merge dut (
        .cur(cur),
        .v_shift(v_shift), .dst_shift(dst_shift), .size_shift(size_shift), .data_shift(data_shift),
        .v_mem(v_mem), .dst_mem(dst_mem), .mode_mem(mode_mem), .data_mem(data_mem),
        .v_rom(v_rom), .dst_rom(dst_rom), .size_rom(size_rom), .data_rom(data_rom),
        .v_wb(v_wb), .dst_wb(dst_wb), .size_wb(size_wb), .wb_is_alu(wb_is_alu), .data_wb(data_wb),
        .fwd_wb(fwd_wb),
        .hitv3_wb(wb_view_hit_of(v_wb, dst_wb, size_wb, wb_is_alu)),
        .hit_mem(mem_hit_of(v_mem, dst_mem, mode_mem)),
        .hit_shift(wb_view_hit_of(v_shift, dst_shift, size_shift, 1'b0)),
        // The registered AH lane selects, formed the way their callers register
        // them (producer_ah_reg.v): the shift token's only where it is visible.
        .ah_shift(v_shift && (size_shift == 2'd0) && dst_shift[2]),
        .ah_rom((size_rom == 2'd0) && dst_rom[2]),
        .ah_wb((size_wb == 2'd0) && dst_wb[2]),
        .lanes_dly(mem_hit_of(1'b1, dst_dly, mode_dly)),
        .v_dly(v_dly), .dst_dly(dst_dly), .mode_dly(mode_dly), .data_dly(data_dly),
        .v_stos(v_stos), .size_stos(size_stos), .data_stos(data_stos),
        .v_sigsrc(v_sigsrc), .dst_sigsrc(dst_sigsrc), .size_sigsrc(size_sigsrc),
        .data_sigsrc(data_sigsrc),
        .v_esp(v_esp), .data_esp(data_esp),
        .vis_ex(VIS_EX), .vis_ea(VIS_EA), .vis_cap(VIS_CAP),
        .commit_value(commit_value), .commit_wmask(commit_wmask),
        .pulse_value(pulse_value), .pulse_wmask(pulse_wmask),
        .ex_value(ex_value), .ea_value(ea_value), .cap_value(cap_value),
        .cap_sel_a(cap_sel_a), .cap_sel_b(cap_sel_b),
        .cap_a_value(cap_a_value), .cap_b_value(cap_b_value),
        .ea_sel_a(ea_sel_a), .ea_sel_b(ea_sel_b),
        .ea_a_value(ea_a_value), .ea_b_value(ea_b_value),
        .ex_sel_a(ex_sel_a), .ex_sel_b(ex_sel_b), .ex_sel_c(ex_sel_c), .ex_sel_d(ex_sel_d),
        .ex_sel_e(ex_sel_e),
        .ex_a_value(ex_a_value), .ex_b_value(ex_b_value), .ex_c_value(ex_c_value),
        .ex_d_value(ex_d_value), .ex_e_value(ex_e_value)
    );

    function automatic [31:0] regval(input [255:0] v, input int r);
        regval = v[r*32 +: 32];
    endfunction

    // The select-first capture ports must equal the full capture view for every
    // register, in every state a check samples.
    // What the register file holds after the commit (or recipe pulse): the merge's
    // value in the lanes its mask writes, the register's own bytes elsewhere. The
    // value outside the mask is not part of the contract (data_unit's
    // commit_merged writes only masked lanes).
    function automatic [31:0] committed(input int r);
        committed = (regval(commit_value, r) & regval(commit_wmask, r)) |
                    (regval(cur, r) & ~regval(commit_wmask, r));
    endfunction
    function automatic [31:0] pulsed(input int r);
        pulsed = (regval(pulse_value, r) & regval(pulse_wmask, r)) |
                 (regval(cur, r) & ~regval(pulse_wmask, r));
    endfunction

    task automatic check_cap_select(input string name);
    begin
        for (int i = 0; i < 8; i++) begin
            cap_sel_a = 3'(i);
            cap_sel_b = 3'(7 - i);
            #1;
            if (cap_a_value !== regval(cap_value, i) ||
                cap_b_value !== regval(cap_value, 7 - i)) begin
                $display("GPR MERGE FAIL %s: select-first capture reg %0d", name, i);
                failures = failures + 1;
            end
        end
    end
    endtask

    // The select-first EA ports (the D2 base and index reads) must equal the full
    // EA view for every register, and the five select-first EX ports the EX view.
    task automatic check_ea_select(input string name);
    begin
        for (int i = 0; i < 8; i++) begin
            ea_sel_a = 3'(i);
            ea_sel_b = 3'(7 - i);
            ex_sel_a = 3'(i); ex_sel_b = 3'(7 - i); ex_sel_c = 3'((i + 3) % 8);
            ex_sel_d = 3'((i + 5) % 8); ex_sel_e = 3'((i + 1) % 8);
            #1;
            if (ex_a_value !== regval(ex_value, i) || ex_b_value !== regval(ex_value, 7 - i) ||
                ex_c_value !== regval(ex_value, (i + 3) % 8) ||
                ex_d_value !== regval(ex_value, (i + 5) % 8) ||
                ex_e_value !== regval(ex_value, (i + 1) % 8)) begin
                $display("GPR MERGE FAIL %s: select-first ex reg %0d", name, i);
                failures = failures + 1;
            end
            if (ea_a_value !== regval(ea_value, i) ||
                ea_b_value !== regval(ea_value, 7 - i)) begin
                $display("GPR MERGE FAIL %s: select-first ea reg %0d", name, i);
                failures = failures + 1;
            end
        end
    end
    endtask

    task automatic check(input string name, input [31:0] got, input [31:0] want);
    begin
        check_cap_select(name);
        check_ea_select(name);
        if (got !== want) begin
            $display("GPR MERGE FAIL %s: got %08x want %08x", name, got, want);
            failures = failures + 1;
        end else begin
            $display("GPR MERGE PASS %s: %08x", name, got);
        end
    end
    endtask

    task automatic idle();
    begin
        v_shift = 1'b0; dst_shift = 3'd0; size_shift = 2'd2; data_shift = 32'd0;
        v_mem   = 1'b0; dst_mem   = 3'd0; mode_mem   = EA_FWD_D; data_mem = 32'd0;
        v_rom   = 1'b0; dst_rom   = 3'd0; size_rom   = 2'd2; data_rom = 32'd0;
        v_wb    = 1'b0; dst_wb    = 3'd0; size_wb    = 2'd2; wb_is_alu = 1'b0;
        data_wb = 32'd0;
        v_dly   = 1'b0; dst_dly   = 3'd0; mode_dly   = EA_FWD_D; data_dly = 32'd0;
        v_stos  = 1'b0; size_stos  = 2'd2; data_stos  = 32'd0;
        v_sigsrc= 1'b0; dst_sigsrc = 3'd0; size_sigsrc= 2'd2; data_sigsrc = 32'd0;
        v_esp   = 1'b0;                    data_esp   = 32'd0;
    end
    endtask

    initial begin
        idle();
        cur = 256'd0;

        // 1. Older dword token, younger dword write-back, same register.
        //    The younger producer must win the commit and every view.
        idle();
        cur = {224'd0, 32'h1111_1111};
        v_mem = 1'b1; dst_mem = 3'd0; mode_mem = EA_FWD_D; data_mem = 32'hAAAA_AAAA;
        v_wb  = 1'b1; dst_wb  = 3'd0; size_wb  = 2'd2;     data_wb  = 32'hBBBB_BBBB;
        #1;
        check("1 ex view",     regval(ex_value, 0),     32'hBBBB_BBBB);
        check("1 commit",      committed(0), 32'hBBBB_BBBB);

        // 2. Older token owns byte 1 (AH), younger write-back owns byte 0 (AL).
        idle();
        cur = {224'd0, 32'h0000_1111};
        v_mem = 1'b1; dst_mem = 3'd0; mode_mem = EA_FWD_BHI; data_mem = 32'h0000_00AA;
        v_wb  = 1'b1; dst_wb  = 3'd0; size_wb  = 2'd0;       data_wb  = 32'h0000_00BB;
        #1;
        check("2 disjoint lanes", regval(ex_value, 0), 32'h0000_AABB);

        // 2b. Byte producers address the register as dst[1:0] with dst[2]
        //     selecting AH/AL: an older byte to AH (dst=4) and a younger byte to
        //     AL (dst=0) must both land in the same register, disjointly.
        idle();
        cur = {224'd0, 32'h0000_0000};
        v_mem = 1'b1; dst_mem = 3'd4; mode_mem = EA_FWD_BHI; data_mem = 32'h0000_00AA;
        v_wb  = 1'b1; dst_wb  = 3'd0; size_wb  = 2'd0;       data_wb  = 32'h0000_00EF;
        #1;
        check("2b AH/AL encoding", regval(ex_value, 0), 32'h0000_AAEF);

        // 3. Older dword token, younger byte write-back: the byte wins, the
        //    token keeps the lanes the write-back does not own.
        idle();
        cur = 256'd0;
        v_mem = 1'b1; dst_mem = 3'd0; mode_mem = EA_FWD_D; data_mem = 32'hAAAA_AAAA;
        v_wb  = 1'b1; dst_wb  = 3'd0; size_wb  = 2'd0;     data_wb  = 32'h0000_00EF;
        #1;
        check("3 younger byte wins", regval(ex_value, 0), 32'hAAAA_AAEF);
        check("3 commit",            committed(0), 32'hAAAA_AAEF);

        // 4. Older byte token, younger dword write-back: the younger dword wins.
        idle();
        cur = 256'd0;
        v_mem = 1'b1; dst_mem = 3'd0; mode_mem = EA_FWD_BLO; data_mem = 32'h0000_00AA;
        v_wb  = 1'b1; dst_wb  = 3'd0; size_wb  = 2'd2;       data_wb  = 32'hBBBB_BBBB;
        #1;
        check("4 younger dword wins", regval(ex_value, 0), 32'hBBBB_BBBB);

        // 5. M3 ALU result: committed, never forwarded (it is derived from the
        //    views, so forwarding it would close a loop).  The result is
        //    right-aligned in its operand width, like every other producer.
        idle();
        cur = 256'd0;
        v_mem = 1'b1; dst_mem = 3'd0; mode_mem = EA_FWD_D; data_mem = 32'hAAAA_AAAA;
        v_wb  = 1'b1; dst_wb  = 3'd0; size_wb  = 2'd2; wb_is_alu = 1'b1;
        data_wb = 32'hCCCC_CCCC;
        #1;
        check("5 M3 not forwarded", regval(ex_value, 0),     32'hAAAA_AAAA);
        check("5 M3 committed",     committed(0), 32'hCCCC_CCCC);

        // 5b. M3 byte op into AH: the result is right-aligned, so it must be
        //     placed in byte 1 of the register, and still not forwarded.
        idle();
        cur = {224'd0, 32'h1234_1056};
        v_wb  = 1'b1; dst_wb  = 3'd4; size_wb  = 2'd0; wb_is_alu = 1'b1;
        data_wb = 32'h0000_0012;           // 0x10 + 2 in the operand width
        #1;
        check("5b M3 AH committed",  committed(0), 32'h1234_1256);
        check("5b M3 AH not forwarded", regval(ex_value, 0),  32'h1234_1056);

        // 6. Visibility: the EA view has no memory-token term (a D2 consumer of
        //    a still-pending load is interlocked), the capture view does.
        idle();
        cur = {224'd0, 32'h0000_2222};
        v_mem = 1'b1; dst_mem = 3'd0; mode_mem = EA_FWD_D; data_mem = 32'h9999_9999;
        #1;
        check("6 ex sees token",       regval(ex_value, 0),  32'h9999_9999);
        check("6 ea hides token",      regval(ea_value, 0),  32'h0000_2222);
        check("6 capture sees token",  regval(cap_value, 0), 32'h9999_9999);

        // 7. Delay-slot bypass is youngest, and view-only.
        idle();
        cur = {224'd0, 32'h0000_0000};
        v_mem = 1'b1; dst_mem = 3'd0; mode_mem = EA_FWD_D; data_mem = 32'h1111_1111;
        v_wb  = 1'b1; dst_wb  = 3'd0; size_wb  = 2'd2;     data_wb  = 32'h2222_2222;
        v_dly = 1'b1; dst_dly = 3'd0; mode_dly = EA_FWD_W; data_dly = 32'h0000_3333;
        #1;
        check("7 ea: dly wins low word", regval(ea_value, 0),     32'h2222_3333);
        check("7 ea: wb wins upper",     regval(ea_value, 0) >> 16, 32'h2222);
        check("7 commit: no dly",        committed(0),  32'h2222_2222);

        // 8. The commit's byte mask is the union of the applied lanes, and the
        //    ROM slot sits between the memory token and the write-back.
        idle();
        cur = 256'd0;
        v_mem = 1'b1; dst_mem = 3'd0; mode_mem = EA_FWD_BHI; data_mem = 32'h0000_00AA;
        v_wb  = 1'b1; dst_wb  = 3'd0; size_wb  = 2'd0;       data_wb  = 32'h0000_00BB;
        v_rom = 1'b1; dst_rom = 3'd0; size_rom = 2'd1;       data_rom = 32'h0000_CCCC;
        #1;
        // The write-back is younger than the ROM slot, so its byte 0 wins over
        // the slot's word, and the union of the three lanes is the whole register.
        check("8 commit wmask", commit_wmask[31:0], 32'h0000_FFFF);
        check("8 wb byte wins over rom slot", committed(0), 32'h0000_CCBB);

        // 9. Different registers: producers must not cross lanes.
        idle();
        cur = 256'd0;
        v_mem = 1'b1; dst_mem = 3'd0; mode_mem = EA_FWD_D; data_mem = 32'h1111_1111;
        v_wb  = 1'b1; dst_wb  = 3'd2; size_wb  = 2'd2;     data_wb  = 32'h2222_2222;  // EDX
        #1;
        check("9 reg0 keeps token", regval(ex_value, 0), 32'h1111_1111);
        check("9 reg2 gets wb",     regval(ex_value, 2), 32'h2222_2222);
        check("9 reg1 untouched",   regval(ex_value, 1), 32'h0000_0000);

        // 10. A deferred-load token owns EAX while a SIGSRC recipe commit
        //     (MOVZX/MOVSX) writes EAX in the same cycle.  The commit path
        //     arbitrates them: the token is committed first and the younger
        //     recipe commit is applied on top.  The views deliberately do NOT
        //     forward the recipe commit (no younger consumer samples it in that
        //     cycle), so they show the token where mem is visible and cur where
        //     it is not.
        idle();
        cur = 256'd0;
        v_mem = 1'b1; dst_mem = 3'd0; mode_mem = EA_FWD_D; data_mem = 32'h0000_0044;
        v_sigsrc = 1'b1; dst_sigsrc = 3'd0; size_sigsrc = 2'd2; data_sigsrc = 32'h0000_0200;
        #1;
        check("10 pulse value",      pulsed(0), 32'h0000_0200);
        check("10 pulse wmask",      pulse_wmask[31:0],      32'hFFFF_FFFF);
        check("10 token committed",  committed(0), 32'h0000_0044);
        check("10 ex hides commit",  regval(ex_value, 0),    32'h0000_0044);
        check("10 ea hides token",   regval(ea_value, 0),    32'h0000_0000);
        check("10 cap hides commit", regval(cap_value, 0),   32'h0000_0044);

        // 11. Lane granularity: a word SIGSRC writes only its two lanes.  The
        //     register file composes it over the committed token; the view shows
        //     the token unchanged.
        idle();
        cur = 256'd0;
        v_mem = 1'b1; dst_mem = 3'd0; mode_mem = EA_FWD_D; data_mem = 32'hAAAA_AAAA;
        v_sigsrc = 1'b1; dst_sigsrc = 3'd0; size_sigsrc = 2'd1; data_sigsrc = 32'hDDDD_CCCC;
        #1;
        check("11 pulse wmask word",    pulse_wmask[31:0],       32'h0000_FFFF);
        check("11 pulse word merge",    pulsed(0),  32'h0000_CCCC);
        check("11 token committed",     committed(0), 32'hAAAA_AAAA);
        check("11 ex hides word commit",regval(ex_value, 0),     32'hAAAA_AAAA);

        // 12. The ESP recipe commit is the youngest producer of all, and the
        //     commit path applies it after the token, the write-back and the
        //     delay-slot bypass.  The views keep the base tier.
        idle();
        cur = 256'd0;
        v_mem  = 1'b1; dst_mem = 3'd4; mode_mem = EA_FWD_D; data_mem = 32'h1111_1111;
        v_wb   = 1'b1; dst_wb  = 3'd4; size_wb  = 2'd2;     data_wb  = 32'h2222_2222;
        v_dly  = 1'b1; dst_dly = 3'd4; mode_dly = EA_FWD_D; data_dly = 32'h3333_3333;
        v_esp  = 1'b1;                    data_esp = 32'h4444_4444;
        #1;
        check("12 esp commit value",  pulsed(4), 32'h4444_4444);
        check("12 esp commit mask",   pulse_wmask[159:128],  32'hFFFF_FFFF);
        check("12 ex base wins wb",   regval(ex_value, 4),    32'h2222_2222);
        check("12 ea base wins dly",  regval(ea_value, 4),    32'h3333_3333);
        check("12 cap base wins dly", regval(cap_value, 4),   32'h3333_3333);

        // 13. Order among the recipe commits: SIGSRC (6) is younger than the REP
        //     STOS count (5), so it wins when both target ECX.
        idle();
        cur = 256'd0;
        v_stos = 1'b1; size_stos = 2'd2; data_stos = 32'h5555_5555;
        v_sigsrc = 1'b1; dst_sigsrc = 3'd1; size_sigsrc = 2'd2; data_sigsrc = 32'h6666_6666;
        #1;
        check("13 sigsrc younger than stos", pulsed(1), 32'h6666_6666);

        // 14. A lone REP STOS count is a word write to ECX (reg 1): it merges
        //     into the current value and does not appear in the deferred commit.
        idle();
        cur = {192'd0, 32'h9999_9999, 32'h0000_0000};
        v_stos = 1'b1; size_stos = 2'd1; data_stos = 32'hEEEE_1234;
        #1;
        check("14 stos word merge",    pulsed(1), 32'h9999_1234);
        check("14 stos wmask",         pulse_wmask[63:32],    32'h0000_FFFF);
        check("14 stos not in commit", commit_wmask[63:32],   32'h0000_0000);

        // 15. A recipe commit must not disturb other registers.
        idle();
        cur = 256'd0;
        v_sigsrc = 1'b1; dst_sigsrc = 3'd3; size_sigsrc = 2'd2; data_sigsrc = 32'h7777_7777;
        #1;
        check("15 target commit",    pulsed(3), 32'h7777_7777);
        check("15 target mask only", pulse_wmask[127:96],    32'hFFFF_FFFF);
        check("15 others clean",     pulsed(0), 32'h0000_0000);
        check("15 others clean",     pulsed(7), 32'h0000_0000);

        $display("");
        if (failures == 0) begin
            $display("GPR WRITE MERGE TEST PASS");
        end else begin
            $display("GPR WRITE MERGE TEST FAIL: %0d case(s)", failures);
        end
        $finish;
    end

    initial begin
        repeat (1000) #1;
        $display("GPR WRITE MERGE TEST FAIL timeout");
        $finish;
    end
endmodule
