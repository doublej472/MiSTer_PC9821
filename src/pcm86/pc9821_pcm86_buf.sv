// The PC-9801-86 86-PCM sample buffer, backed by SDRAM instead of 32 M10K blocks.
//
// The 32 KiB circular buffer would cost 32 M10K blocks. Those blocks are the design's scarcest
// resource after the GVRAM, and this buffer is the one block-RAM consumer whose access rate
// tolerates the SDRAM read latency. So it lives on the memory controller's THIRD port.
//
// LATENCY IS AFFORDABLE because the drain reads at most 4 bytes per sample frame against a
// 1134-clk frame period (50 MHz / 44.1 kHz), so its read is a REQUEST/VALID handshake here
// rather than the one-cycle block-RAM read it replaced.
//
// THE WRITE NEEDS A FIFO because the guest's 0xA46C write is a one-cycle strobe and an SDRAM
// write takes several. Back-to-back 0xA46C writes reach the FIFO every ~10-15 clk_sys at the
// IO_MIN_HOLD=4 I/O cadence (a tight loop or REP OUTSB), which can outrun a contended SDRAM
// round trip for a burst. So the FIFO is BACK-PRESSURED, not sized: wr_wait rises while it is
// full and pc9821_pcm86/pc9821_iobus hold the CPU's I/O write in the bus's S_IOWAIT state
// until there is room, so a guest byte is never dropped. This module is a byte-addressed
// 2^15-byte memory and knows nothing about sample format -- the format is pc9821_pcm86.sv's.

`default_nettype none

module pc9821_pcm86_buf (
    input  wire        clk,
    input  wire        reset,

    // Byte address of the buffer's first byte in the SDRAM. An input rather than a
    // parameter because it moves with the guest RAM size: pack_base + PACK_BYTES + 256 KiB.
    // It must be 32 KiB aligned (the buffer's own size): only bits [31:15] are used, and the
    // buffer offset is concatenated under them instead of added. pack_base is a multiple of
    // 1 MiB (pc9821_system size_code_bytes) and 0x140000 a multiple of 256 KiB.
    /* verilator lint_off UNUSEDSIGNAL */   // bits [14:0] are the buffer-offset bits: zero by contract
    input  wire [31:0] buf_base,
    /* verilator lint_on UNUSEDSIGNAL */

    // Guest write port. wr_en is a one-cycle strobe; wr_addr/wr_data are valid on it.
    // wr_wait is the write back-pressure: high while the FIFO cannot accept a byte.
    // The master (pc9821_iobus, through pc9821_pcm86's io_wr_wait) holds the guest's
    // I/O access until it clears, so the 0xA46C stream can run at the IO_MIN_HOLD
    // floor (one byte per ~10-15 clk) against SDRAM contention WITHOUT dropping
    // bytes; `fifo_push` keeps its !full guard as the last resort for a master that
    // ignores the wait.
    input  wire        wr_en,
    input  wire [14:0] wr_addr,
    input  wire  [7:0] wr_data,
    output wire        wr_wait,

    // Drain read port. rd_req is a one-cycle strobe; rd_valid pulses once with rd_data.
    input  wire        rd_req,
    input  wire [14:0] rd_addr,
    output reg   [7:0] rd_data,
    output reg         rd_valid,

    // SDRAM port 2 (the controller's third requester): one 32-bit word per request.
    output reg         sdram_valid,
    input  wire        sdram_ready,
    output reg         sdram_write,
    output reg  [31:0] sdram_addr,
    output reg  [31:0] sdram_din,
    input  wire [31:0] sdram_dout,
    input  wire        sdram_resp_valid,
    output reg   [3:0] sdram_be,
    output wire  [7:0] sdram_burstcount
);

    // The controller's burst count is 4 bits at the port and 0 means ONE word; this module never
    // bursts, so it always asks for exactly one 32-bit word.
    assign sdram_burstcount = 8'd1;

    // ------------------------------------------------------------------
    // The write FIFO: {addr[14:0], data[7:0]} per entry, 4 deep, CIRCULAR (head + count).
    // A shift-down FIFO would make a same-cycle push and pop collide on one index; with a
    // head pointer the push index (head + count) and the pop's head advance never overlap.
    // ------------------------------------------------------------------
    localparam integer FW = 4;                    // FIFO depth (power of two)

    // No reset on the entries: an entry is read only while wcnt says it is held, and it is
    // written before wcnt counts it. Without the reset Quartus can build the 4 x 23 array as
    // memory (a reset of the whole array forces 92 flip-flops).
    reg  [22:0] fifo [0:FW-1];                    // {wr_addr, wr_data}
    reg  [1:0]  fhead;                            // oldest entry
    reg  [2:0]  wcnt;                             // entries held

    wire        fifo_full  = (wcnt == 3'(FW));
    wire [22:0] fifo_head  = fifo[fhead];
    wire        fifo_empty = (wcnt == 3'd0);
    wire [1:0]  fifo_tail  = fhead + wcnt[1:0];

    // The push and the pop can land on the SAME cycle, and a separate `wcnt <= wcnt+1` in the
    // push would then be overwritten by the pop's `wcnt <= wcnt-1` (the later non-blocking
    // assignment wins), losing an entry's worth of count. So the count is computed ONCE, from
    // both events, and assigned in one place.
    wire        fifo_push = wr_en && !fifo_full;
    wire        fifo_pop  = (bstate == B_WR) && sdram_ready;
    wire [2:0]  wcnt_next = wcnt + (fifo_push ? 3'd1 : 3'd0) - (fifo_pop ? 3'd1 : 3'd0);
    assign      wr_wait = fifo_full;

    // ------------------------------------------------------------------
    // The request engine. One SDRAM access outstanding at a time.
    // ------------------------------------------------------------------
    localparam [1:0] B_IDLE  = 2'd0,   // choose the next request
                     B_WR    = 2'd1,   // a write is on the bus
                     B_RD    = 2'd2,   // a read is on the bus
                     B_RWAIT = 2'd3;   // waiting for the read's response

    reg  [1:0]  bstate;
    reg         rd_pending;                       // a latched read request
    reg  [14:0] rd_lat;                           // its address

    // Lane select for the read: which of the 32-bit word's four bytes to take. The write's
    // lane comes straight from fifo_head (the address the byte is stored with), so no
    // separate write latch is kept.
    wire [1:0] rd_lane = rd_lat[1:0];

    always @(posedge clk) begin
        if (reset) begin
            wcnt        <= 3'd0;
            bstate      <= B_IDLE;
            rd_pending  <= 1'b0;
            rd_lat      <= 15'd0;
            fhead       <= 2'd0;
            rd_data     <= 8'd0;
            rd_valid    <= 1'b0;
            sdram_valid <= 1'b0;
            sdram_write <= 1'b0;
            sdram_addr  <= 32'd0;
            sdram_din   <= 32'd0;
            sdram_be    <= 4'd0;
        end else begin
            rd_valid <= 1'b0;

            // ---- the FIFO: push the guest's byte at the tail (the count is assigned below,
            // from both the push and the pop, so the two cannot race) ----
            if (fifo_push) begin
                fifo[fifo_tail] <= {wr_addr, wr_data};
            end
            wcnt <= wcnt_next;

            // ---- latch a read request ----
            if (rd_req && !rd_pending) begin
                rd_lat     <= rd_addr;
                rd_pending <= 1'b1;
            end

            // ---- the engine ----
            case (bstate)
                B_IDLE: begin
                    sdram_valid <= 1'b0;
                    if (!fifo_empty) begin
                        // Writes first: they are the guest's and cannot be made to wait. The
                        // address and byte ride on fifo_head, which is stable until the pop.
                        sdram_valid <= 1'b1;
                        sdram_write <= 1'b1;
                        sdram_addr  <= {buf_base[31:15], fifo_head[22:8]};
                        // The byte's lane: replicated to all four so the byte-enable picks it.
                        sdram_din   <= {4{fifo_head[7:0]}};
                        sdram_be    <= 4'b0001 << fifo_head[9:8];   // addr[1:0]
                        bstate      <= B_WR;
                    end else if (rd_pending) begin
                        sdram_valid <= 1'b1;
                        sdram_write <= 1'b0;
                        sdram_addr  <= {buf_base[31:15], rd_lat};
                        sdram_be    <= 4'b1111;
                        bstate      <= B_RD;
                    end
                end

                B_WR: begin
                    if (sdram_ready) begin
                        sdram_valid <= 1'b0;
                        fhead  <= fhead + 2'd1;   // pop; wcnt is assigned above, from both events
                        bstate <= B_IDLE;
                    end
                end

                B_RD: begin
                    if (sdram_ready) begin
                        sdram_valid <= 1'b0;
                        bstate      <= B_RWAIT;
                    end
                end

                B_RWAIT: begin
                    if (sdram_resp_valid) begin
                        // The response is a 32-bit word; take the requested byte's lane.
                        rd_data    <= sdram_dout[{rd_lane, 3'b000} +: 8];
                        rd_valid   <= 1'b1;
                        rd_pending <= 1'b0;
                        bstate     <= B_IDLE;
                    end
                end

                default: bstate <= B_IDLE;
            endcase
        end
    end

    // A full FIFO is a STALL, not a drop: `wr_wait` back-pressures the guest's I/O
    // access through pc9821_iobus until the engine below has drained a slot. The
    // depth-4 sizing is not a correctness claim (the guest can write once per
    // ~10 clk_sys at IO_MIN_HOLD, faster than a contended SDRAM write); it is burst
    // absorption only, and the `!fifo_full` push guard survives solely for a master
    // that ignores `wr_wait`, where dropping still beats corrupting the FIFO.

endmodule

`default_nettype wire
