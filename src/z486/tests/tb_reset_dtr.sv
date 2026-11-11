// The IDTR and GDTR a program reads straight after reset: SIDT and SGDT as the
// first two instructions at the reset vector, nothing loaded before them.
//
// Expected: base 0, limit FFFFh for both. A PC-9821Xe10 (i486DX2) reads
// "idt=FFFF:00000000 gdt=FFFF:00000000" at the DOS prompt (the PC-9821 core
// repository's docs/probes/KIT1-XE10-CFG0.TXT:78), where the same boot on a
// core resetting both to 03FFh reads 03FF:00000000 for both, so the boot path
// loads neither register and the machine's values are its reset values; NP2kai
// i386c/ia32/interface.c resets CPU_GDTR_LIMIT and CPU_IDTR_LIMIT to 0xffff.
// The Intel486 documents disagree (Intel486 Programmer's Reference Manual 1992,
// Table 10-1, and the Intel486 DX2 data sheet, Table 6.2: "IDTR Base = 0,
// Limit=3FFh"; neither lists GDTR); the machine is followed.
`timescale 1ns/1ns
module tb_reset_dtr;
    reg clk = 0;
    always #5 clk = ~clk;
    reg reset_n = 0;
    wire [31:2] addr;
    wire [3:0]  be;
    wire [31:0] dout;
    wire valid, write, line_read;
    reg resp_valid = 0;
    reg line_resp_valid = 0;
    reg [127:0] line_din = 0;
    z486 dut (
        .clk(clk), .reset_n(reset_n),
        .device_mmio_enable(1'b0), .device_mmio_base(32'd0),
        .win0_unmapped(1'b0), .ram_cache_top(32'hffff_ffff),
        .addr(addr), .be(be), .burstcount(), .dout(dout), .valid(valid),
        .write(write), .io(), .line_read(line_read),
        .ready(1'b1), .din(32'h9090_9090), .line_din(line_din),
        .resp_valid(resp_valid), .line_resp_valid(line_resp_valid),
        .intr(1'b0), .nmi(1'b0), .inta(),
        .snoop_valid(1'b0), .snoop_addr(32'd0),
        .cache_flush(1'b0), .cache_flush_busy(), .cache_flush_done(),
        .a20_enable(1'b1),
        .fast_off_req(1'b0), .cache_off_req(1'b0), .x87_off_req(1'b0),
        .single_step(1'b0),
        .triple_fault_reset()
    );

    // The reset-vector line (FFFFFFF0h, DS base 0):
    //   0F 01 0E 00 01   sidt [0100h]
    //   0F 01 06 08 01   sgdt [0108h]
    //   EB FE            jmp $
    //   90 90 90 90
    localparam logic [127:0] RESET_LINE =
        128'h90909090_FEEB0108_06010F01_000E010F;

    // Byte image of the writes below 200h, sentinel AAh.
    reg [7:0] mem [0:511];
    initial for (int i = 0; i < 512; i++) mem[i] = 8'hAA;

    always @(posedge clk) begin
        resp_valid <= valid && !write && !line_read;
        line_resp_valid <= valid && !write && line_read;
        line_din <= (addr[15:2] == 14'h3ffc) ? RESET_LINE : {16{8'h90}};
        if (valid && write && ({addr, 2'b00} < 32'h200))
            for (int b = 0; b < 4; b++)
                if (be[b]) mem[{addr[8:2], 2'(b)}] <= dout[8*b +: 8];
    end

    function automatic [15:0] w16(input int a);
        w16 = {mem[a + 1], mem[a]};
    endfunction
    function automatic [23:0] w24(input int a);
        w24 = {mem[a + 2], mem[a + 1], mem[a]};
    endfunction

    initial begin
        fork begin repeat (4000) @(posedge clk); $fatal(1, "reset dtr bench timeout"); end join_none
        repeat (5) @(negedge clk);
        reset_n = 1;
        // Both stores have landed when the GDTR base's third byte is written.
        do @(negedge clk); while (mem[16'h10A + 2] === 8'hAA || mem[16'h102 + 2] === 8'hAA);
        repeat (20) @(negedge clk);
        if (w16(16'h100) !== 16'hFFFF || w24(16'h102) !== 24'h0)
            $fatal(1, "IDTR after reset reads %04x:%06x, expected FFFF:000000",
                   w16(16'h100), w24(16'h102));
        if (w16(16'h108) !== 16'hFFFF || w24(16'h10A) !== 24'h0)
            $fatal(1, "GDTR after reset reads %04x:%06x, expected FFFF:000000",
                   w16(16'h108), w24(16'h10A));
        $display("RESET DTR TEST PASS");
        $finish;
    end
endmodule
