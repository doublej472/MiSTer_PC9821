// NEC's uPD71071: 8237-compatible, four channels, PC-98 addressing; register behaviour is
// NP2kai's io/dmac.c (chip: nec-core-survey section 6; windows: IO-11).

// ONE CONSUMER, THE FDC: its DRQ and DACK sit on channel 2 or 3 as its strap selects (pc9821_iobus
// `.dma_dack(fdc_strap_2hd ? dma_dev_dack[2] : dma_dev_dack[3])`). The CS4231 is unmodelled and the PC-9801-86's sample path is PIO.

// THE MACHINE OUTRANKS THE MODEL ON READS: write-only registers answer rather than float - 0xFF
// at 0x13/0x15/0x17/0x19/0x1D/0x1F, 0x00 at 0x11/0x1B. 0x1B does NOT clear the
// byte flip-flop: NP2kai's dmac_o1b leaves dmac.lh alone (io/dmac.c:202-215) (the 8237
// Master Clear rule is an unmeasured datasheet deviation).

// COUNT IS N+1: an 8237 moves one more byte than programmed, so 0 is 65536 - and so does
// NP2kai's transfer engine, the code that actually runs (mem/dmax86.c:19-24 tests leng
// BEFORE decrementing, so the byte that consumes a zero count still moves; only the bulk
// helper dmac_getdatas is N). The ITF's self-test (BANK4@0xF83EF) writes each register
// twice and starts no transfer, so it cannot tell N from N+1 by itself.

// NOT MODELLED: 16-bit transfers (every channel is byte-wide), memory-to-memory, mode pacing
// (bits 6:5 latched, every transfer single-cycle), the 0xE05-0xE0B window (0x29 is the last
// register, so ch_addr[30:24] moves only via S_FIN's increment and a 0x21-0x27 bank write
// zeroes them, NP2kai dmac_o21 io/dmac.c:242). The memory port is a second bus master:
// pc9821_iobus exports it and pc9821_memory_subsystem admits it as its third owner.

`default_nettype none

module pc9821_dmac (
    input wire clk,
    input wire reset,

    // The register file on the PC-98 device bus. `sel` is the decode
    // pc9821_device_select exports; `idx` is the register index within it.
    input  wire        sel,
    input  wire        write,
    input  wire [4:0]  idx,
    input  wire [7:0]  din,
    output reg  [7:0]  dout,
    // THE SAME BYTE, COMBINATIONALLY, for a fabric that captures its read data IN the
    // access cycle (pc9821_iobus's S_BYTE). `dout` is registered because this module's own
    // benches sample it one cycle later, and because the register file's reads have SIDE
    // EFFECTS (the address/count flip-flop, the 0x11 terminal-count clear) whose commit
    // must be the access's edge; a same-cycle reader must therefore see the value BEFORE
    // that edge. Both outputs are the same expressions over the same state, so they agree
    // in every cycle an access is presented - the registered one a cycle late, which is
    // what a device-fabric read would otherwise have to spend a wait state on.
    output reg  [7:0]  dout_comb,

    // The per-channel device interface. A device asks by holding drq; the controller answers
    // dack while that channel's byte moves and tc WITH the block's last byte's dack/strobe
    // (the 8237's EOP-during-final-transfer convention), so a device can qualify EOP with
    // its DACK and terminate after that byte.
    // dev_we is the direction (1 = memory to port); dev_stb qualifies the data for one cycle.
    input  wire [3:0]  dev_drq,
    output wire [3:0]  dev_dack,
    output wire        dev_we,
    output wire        dev_stb,
    output wire        dev_tc,
    output wire [1:0]  dev_ch,
    output wire [7:0]  dev_dout,
    input  wire [7:0]  dev_din,

    // The bus-master port: one byte per transaction, in the shape the memory subsystem's
    // backend actually takes. Four things here are load-bearing.
    //   * mem_be is one-hot because a byte is moving. The backend IGNORES the low address
    //     bits (src/memory/sdram.v:95 `(bits [1:0] ignored)`), so mem_be picks the byte inside the word; both
    //     it and the address come from the same counter, so they cannot disagree.
    //   * mem_din REPLICATES the byte into all four lanes rather than placing it in the
    //     selected one, so the module carries no lane-order convention it cannot test.
    //   * mem_ready is the ACCEPT and mem_resp_valid is the COMPLETION, several cycles
    //     apart at real SDRAM latency. Sampling the read byte on the accept returns the
    //     PREVIOUS word's byte - the one-cycle-record defect rebuilt. Two pulses.
    //   * A WRITE HAS NO RESPONSE: it completes at the accept, so only the read path
    //     waits for mem_resp_valid.
    output reg  [31:0] mem_addr,
    // THE ADDRESS mem_addr LOADS NEXT, and the cycle it loads (mem_load: mem_addr takes
    // mem_addr_nx at this clock edge). pc9821_memory_subsystem decodes the byte's route from
    // these and registers it on the same edge as mem_addr, so the decode is not in series with
    // the request's accept (dma_ready reaches the CPU's snoop input combinationally).
    output wire [31:0] mem_addr_nx,
    output wire        mem_load,
    // THE DIRECTION OF THE BYTE mem_load LOADS, valid in the load cycle. mem_we is a request
    // qualifier (mem_req && ...) and is low in both load cycles - S_FIRST and S_DEV precede
    // S_MEM - so the subsystem's route decode, which runs on the load, cannot take it from
    // mem_we: a port-to-memory byte would be decoded as a read and a ROM window's store kept.
    output wire        mem_load_we,
    output wire        mem_we,
    output wire [3:0]  mem_be,
    output reg  [31:0] mem_din,
    input  wire [31:0] mem_dout,
    output reg         mem_req,
    input  wire        mem_ready,
    input  wire        mem_resp_valid,
    // THE MEMORY-SIDE TERMINAL COUNT. dev_tc is the
    // block's terminal count WITH the final device strobe (the 8237's
    // EOP-during-final-transfer convention, above); THIS one pulses one state later,
    // at S_FIN, where the port-to-memory path's FINAL BYTE HAS BEEN ACCEPTED by the
    // backend (S_FIN is entered from S_MEM only on mem_ready). It has no coherency
    // consumer: the per-write DMA snoop (T24) covers every accepted write, so no
    // completion event is needed, and pc9821_iobus holds this on an unused wire.
    // A memory-to-port or verify block writes no memory, so it pulses nothing.
    output wire        mem_tc
);

  // Register indices in the 0x01..0x29 window, as NP2kai's dmaco00[16]/dmaco21[8] bind them.
  // `idx` is NOT the port number. 0,2,4,6 are the address halves (ports 0x01,0x05,0x09,0x0D) and
  // 1,3,5,7 the count halves (0x03,0x07,0x0B,0x0F). 8..15 are status 0x11, software request
  // 0x13, single mask 0x15, mode 0x17, clear flip-flop 0x19, master clear 0x1B, clear masks
  // 0x1D and write masks 0x1F. 16..19 are the bank byte (0x21,0x23,0x25,0x27) and 20 is bound.
  localparam [4:0] R_CLEAR_FF  = 5'd12;
  localparam [4:0] R_MASTER    = 5'd13;
  localparam [4:0] R_CLEARMSK  = 5'd14;
  localparam [4:0] R_ALLMSK    = 5'd15;
  localparam [4:0] R_BOUND     = 5'd20;

  // Per-channel state. NP2kai stores the live register and the value it was programmed
  // with (adrs/adrsorg, leng/lengorg) but NEVER reads the _org pair - it has no
  // autoinitialize reload (mem/dmax86.c clears `working` at TC and never restores). The reload the engine performs is 8237-datasheet behaviour adopted over
  // that NP2kai gap, and tb_pc9821_dma_vram names it as such.
  reg [30:0] ch_addr [0:3];      // live, and what a transfer walks
  reg [15:0] ch_count[0:3];      // live, and what a transfer counts down

  // The AS-PROGRAMMED copies, for autoinitialize: per channel {count[15:0], address[23:0]} (address
  // bits 30:24 of the live register are never programmed, so the copy carries 24). Only the CPU's
  // writes and the S_FIN reload touch it, never a read-back, so it lives in block RAM instead of 160
  // flops and the 4:1 reload muxes: five byte-wide memories (Quartus 17 infers no byte-enabled RAM
  // from lane writes of one wide array, and a read-modify-write of a wide word would need a read of
  // a channel the engine is not on), written a byte lane at a time as the guest programs the
  // halves and read back by the channel the engine is on. `cur` holds still from S_IDLE through
  // S_FIN, so the registered read has long arrived by the S_FIN that uses it. A guest write to
  // the ACTIVE channel's copy in the single cycle BEFORE its own autoinitializing S_FIN is seen one
  // cycle late (an I/O write racing the final byte's bookkeeping by one clock; the chip has no
  // defined winner there either). No reset: the programmed copy is not cleared by a reset (an
  // 8237's base registers are not), and the `initial` below is the power-on zero.
  (* ramstyle = "M10K, no_rw_check" *) reg [7:0] org_a0 [0:3];   // address 7:0
  (* ramstyle = "M10K, no_rw_check" *) reg [7:0] org_a1 [0:3];   // address 15:8
  (* ramstyle = "M10K, no_rw_check" *) reg [7:0] org_a2 [0:3];   // address 23:16
  (* ramstyle = "M10K, no_rw_check" *) reg [7:0] org_c0 [0:3];   // count 7:0
  (* ramstyle = "M10K, no_rw_check" *) reg [7:0] org_c1 [0:3];   // count 15:8
  initial begin
    for (int k = 0; k < 4; k++) begin
      org_a0[k] = 8'h00; org_a1[k] = 8'h00; org_a2[k] = 8'h00; org_c0[k] = 8'h00; org_c1[k] = 8'h00;
    end
  end
  reg [7:0] org_qa0, org_qa1, org_qa2, org_qc0, org_qc1;
  wire [39:0] org_q = {org_qc1, org_qc0, org_qa2, org_qa1, org_qa0};
  reg [7:0]  ch_mode [0:3];
  reg [1:0]  ch_bound[0:3];
  // The 0x29 read: the four bounds packed, channel 0 lowest (see the read arm).
  wire [7:0] bound_rd = {ch_bound[3], ch_bound[2], ch_bound[1], ch_bound[0]};

  // The 8237's low/high byte flip-flop. GLOBAL to the chip, not per channel, and it
  // toggles on every address or count access - which is why the ITF's
  // write-then-read self-test passes against it: one access of each cancels.
  reg lh;

  // Mask and status. stat's low nibble is each channel's terminal count, cleared by reading
  // 0x11; its high nibble is DOCUMENTED AS the request state but nothing here writes it, so a
  // driver always reads request bits of 0. NP2kai has the same gap (io/dmac.c:162-165 vs the
  // tables at :327/:334). Named absent rather than invented. The read clear is NIBBLE-WIDTH:
  // NP2kai's dmac_i11 does `dmac.stat &= 0xf0` (io/dmac.c:290-294), so the read acknowledges
  // the terminal-count bits and leaves the request-state nibble standing (tb_pc9821_dmac S7).
  reg [3:0] mask;
  reg [7:0] stat;
  reg [3:0] sw_req;

  // The engine: one byte at a time, in explicit phases.
  localparam [2:0] S_IDLE = 3'd0,  // choosing a channel
                   S_FIRST = 3'd1, // deciding which side the byte starts on
                   S_MEM   = 3'd2, // presenting the request, waiting for the ACCEPT
                   S_RESP  = 3'd5, // a read: waiting for the COMPLETION
                   S_DEV   = 3'd3, // the strobe cycle: the device's byte moves
                   S_FIN   = 3'd4, // advance the address and count, maybe report TC
                   S_SEL   = 3'd6; // the byte's address held for its route decode (THE ADDRESS SNAPSHOT)
  reg [2:0]  state;
  reg [1:0]  cur;
  reg [30:0] cur_addr_q;   // ch_addr[cur] in every cycle (THE ENGINE CHANNEL'S ADDRESS below)
  reg        cur_read;   // the byte comes from memory and goes to the device
  reg        cur_verify;
  reg [7:0]  cur_byte;

  // The byte the backend returned, from the lane mem_be names. Both come from mem_addr's low
  // bits, and mem_addr is held through S_MEM and S_RESP, so the lane is valid when it arrives.
  // mem_be (assigned below) is the one-hot decode of those SAME bits, so the read byte selects
  // off it rather than re-comparing mem_addr[1:0]: one decode, value-identical at every cycle.
  wire [7:0] mem_rd_byte = mem_be[0] ? mem_dout[7:0]   :
                           mem_be[1] ? mem_dout[15:8]  :
                           mem_be[2] ? mem_dout[23:16] :
                                       mem_dout[31:24];

  wire [3:0] req      = dev_drq | sw_req;
  wire [3:0] want     = req & ~mask;
  wire       any_want = |want;

  // ---------------------------------------------------------------- event folds
  // The CPU register arms and the engine's S_FIN step write the SAME state: left to source
  // order, a same-cycle CPU write would lose to S_FIN's later NBA - silently, and leaving
  // ch_addr_org/ch_count_org holding values the live registers never saw. On the real chip,
  // and in NP2kai (whose register file is plain memory and whose engine a separate
  // function), the CPU access is never dropped. So each collision is MERGED into one
  // next-state expression per register (docs/single-cycle-event-discipline.md R2/R4) rather
  // than left to source order:
  //   * a CPU write wins its BYTE LANE of ch_addr/ch_count over S_FIN's advance or reload
  //     (the transfer still walks the lanes the CPU did not write);
  //   * R_MASTER (0x1B) wins whole registers outright (it zeroes them);
  //   * the status TC bit is SET-WINS (R3): a fresh terminal count is an event, and a
  //     count-write's TC clear landing on it must not eat it;
  //   * mask and sw_req follow the CPU write (an explicit unmask / software request is not
  //     eaten by the engine's TC bookkeeping).
  // The arms below skip their raw write exactly when the fold carries it, so only one NBA
  // site per register fires in any cycle and reordering the block cannot change the result.
  wire cpu_wr         = sel && write;
  wire cpu_rd         = sel && !write;
  wire [1:0] cpu_chan = idx[2:1];            // the channel of an address/count half
  wire [1:0] cpu_bank_ch = idx[1:0] + 2'd1;  // the channel of a 0x21..0x27 bank byte
  wire cpu_addr_half  = cpu_wr && (idx <= 5'd7) && !idx[0];
  wire cpu_cnt_half   = cpu_wr && (idx <= 5'd7) &&  idx[0];
  wire cpu_bank       = cpu_wr && (idx >= 5'd16) && (idx <= 5'd19);
  wire cpu_master     = cpu_wr && (idx == R_MASTER);
  wire cpu_status_rd  = cpu_rd && (idx == 5'd8);
  wire fin_tc         = (state == S_FIN) && (ch_count[cur] == 16'd0);
  wire autoinit       = ch_mode[cur][4];

  wire [7:0] stat_set = fin_tc ? (8'h01 << cur) : 8'h00;
  // A count write clears that channel's TC bit (NP2kai dmac_o03); a 0x11 read clears the
  // WHOLE terminal-count nibble and ONLY it (NP2kai dmac_i11's `dmac.stat &= 0xf0`,
  // io/dmac.c:290-294 - a full-byte clear would eat the request-state nibble).
  wire [7:0] stat_clr = (cpu_cnt_half  ? (8'h01 << cpu_chan) : 8'h00) |
                        (cpu_status_rd ? 8'h0F : 8'h00);

  wire [3:0] mask_tc_set = (fin_tc && !autoinit) ? (4'b0001 << cur) : 4'h0;
  reg  [3:0] mask_cpu_wr, mask_cpu_val;
  always @* begin
    mask_cpu_wr  = 4'h0;
    mask_cpu_val = 4'h0;
    if (cpu_wr && (idx == 5'd10)) begin        // 0x15 single-channel mask
      mask_cpu_wr  = 4'b0001 << din[1:0];
      mask_cpu_val = {4{din[2]}};
    end
    if (cpu_wr && (idx == R_CLEARMSK)) begin   // 0x1D clear masks
      mask_cpu_wr  = 4'hF;
      mask_cpu_val = 4'h0;
    end
    if (cpu_wr && (idx == R_ALLMSK)) begin     // 0x1F write masks
      mask_cpu_wr  = 4'hF;
      mask_cpu_val = din[3:0];
    end
    if (cpu_master) begin                      // 0x1B masks all four
      mask_cpu_wr  = 4'hF;
      mask_cpu_val = 4'hF;
    end
  end

  wire       sw_req_wr  = cpu_wr && (idx == 5'd9);
  wire [3:0] sw_tc_clr  = fin_tc ? (4'b0001 << cur) : 4'h0;
  wire [3:0] sw_cpu_wr  = sw_req_wr ? (4'b0001 << din[1:0]) : 4'h0;
  wire [3:0] sw_cpu_val = (sw_req_wr && din[2]) ? sw_cpu_wr : 4'h0;

  // S_FIN's next value for the walked registers: address direction is mode bit 5 (the
  // 8237's decrement bit, honoured by both NP2kai transfer paths), and the count is N+1 -
  // the byte that consumes a count of zero is the LAST, so a programmed count of 0 is one
  // transfer and 0xFFFF is 65536; testing BEFORE the decrement is what makes it N+1 (and
  // matches mem/dmax86.c's test-before-decrement). At TC: autoinitialize reloads, or the
  // 8237's counter wraps to 0xFFFF and the channel masks itself.
  wire [30:0] addr_base = (fin_tc && autoinit) ? {7'd0, org_q[23:0]}
                        : (ch_mode[cur][5] ? (ch_addr[cur] - 31'd1)
                                           : (ch_addr[cur] + 31'd1));
  wire [15:0] cnt_base  = fin_tc ? (autoinit ? org_q[39:24] : 16'hFFFF)
                                 : (ch_count[cur] - 16'd1);
  wire addr_hit = (cpu_addr_half && (cpu_chan == cur)) ||
                  (cpu_bank && (cpu_bank_ch == cur)) || cpu_master;
  wire cnt_hit  = (cpu_cnt_half && (cpu_chan == cur)) || cpu_master;
  wire [30:0] addr_cpu_val = cpu_master ? 31'd0
                           // A bank write zeroes bits 30:24 along with setting 23:16 - NP2kai's
                           // dmac_o21 does `adrs.b[DMA32_HIGH + DMA16_HIGH] = 0` on EVERY bank
                           // write (io/dmac.c:242), so a stale upper byte left by an S_FIN carry
                           // out of bit 23 cannot survive a bank reprogram (tb_pc9821_dmac_engine
                           // E7d is this collision; tb_pc9821_dma_vram B1 the raw arm).
                           : cpu_bank  ? {7'd0000000, din, addr_base[15:0]}
                           : (lh ? {addr_base[30:16], din, addr_base[7:0]}
                                 : {addr_base[30:8],  din});
  wire [15:0] cnt_cpu_val = cpu_master ? 16'h0
                          : (lh ? {din, cnt_base[7:0]}
                                : {cnt_base[15:8], din});

  integer i;

  // The programmed copy's write port: the same halves the live registers take, one byte lane at a
  // time (a block RAM with byte enables), and read back by the engine's channel.
  reg  [1:0] org_wa;
  reg  [4:0] org_wl;     // lane enables: [0..2] address bytes, [3..4] count bytes
  always @* begin
    org_wa = idx[2:1];
    org_wl = 5'b00000;
    if (sel && write && !reset) begin
      if (idx <= 5'd7) begin
        if (idx[0]) org_wl = lh ? 5'b10000 : 5'b01000;     // count half
        else        org_wl = lh ? 5'b00010 : 5'b00001;     // address half
      end else if (idx >= 5'd16 && idx <= 5'd19) begin
        org_wa = idx[1:0] + 2'd1;                           // NP2kai's ((port >> 1) + 1) & 3
        org_wl = 5'b00100;                                  // address bits 23:16
      end
    end
  end
  always @(posedge clk) begin
    if (org_wl[0]) org_a0[org_wa] <= din;
    if (org_wl[1]) org_a1[org_wa] <= din;
    if (org_wl[2]) org_a2[org_wa] <= din;
    if (org_wl[3]) org_c0[org_wa] <= din;
    if (org_wl[4]) org_c1[org_wa] <= din;
  end
  always @(posedge clk) begin
    org_qa0 <= org_a0[cur]; org_qa1 <= org_a1[cur]; org_qa2 <= org_a2[cur];
    org_qc0 <= org_c0[cur]; org_qc1 <= org_c1[cur];
  end

  always @(posedge clk) begin
    if (reset) begin
      lh        <= 1'b0;
      mask      <= 4'hF;      // every channel masked at reset, as the 8237 is
      stat      <= 8'h00;
      sw_req    <= 4'h0;
      state     <= S_IDLE;
      cur       <= 2'd0;
      cur_read  <= 1'b0;
      cur_verify<= 1'b0;
      cur_byte  <= 8'h00;
      mem_req   <= 1'b0;
      mem_addr  <= 32'd0;
      mem_din   <= 32'd0;
      dout      <= 8'hFF;
      for (i = 0; i < 4; i = i + 1) begin
        ch_addr[i]      <= 31'd0;
        ch_count[i]     <= 16'd0;
        ch_mode[i]      <= 8'h00;
        ch_bound[i]     <= 2'd0;
      end
    end else begin
      // The folded updates for the state the CPU arms and S_FIN BOTH write (see the
      // event folds above): one NBA per register per cycle, with collisions resolved by
      // the fold's boolean rather than by source order (docs/single-cycle-event-discipline.md R2).
      stat   <= (stat & ~stat_clr) | stat_set;
      mask   <= ((mask | mask_tc_set) & ~mask_cpu_wr) | (mask_cpu_val & mask_cpu_wr);
      sw_req <= ((sw_req & ~sw_tc_clr) & ~sw_cpu_wr) | (sw_cpu_val & sw_cpu_wr);

      // ---------------------------------------------------------------- writes
      if (sel && write) begin
        case (idx)
          // Address halves (0x01,0x05,0x09,0x0D); NP2kai's dmac_o01 writes adrs and adrsorg
          // through the same flip-flop.
          5'd0, 5'd2, 5'd4, 5'd6: begin
            // A same-cycle S_FIN carries this register's write in its own folded
            // update (addr_hit/addr_cpu_val), so the raw write is skipped exactly then:
            // one NBA site per register per cycle, whichever block is read first.
            if (!lh) begin
              if (!(state == S_FIN && idx[2:1] == cur))
                ch_addr    [idx[2:1]][7:0]   <= din;
            end else begin
              if (!(state == S_FIN && idx[2:1] == cur))
                ch_addr    [idx[2:1]][15:8]  <= din;
            end
            lh <= ~lh;
          end
          // Count halves (0x03,0x07,0x0B,0x0F); a count write also clears that channel's
          // terminal count (NP2kai dmac_o03) - through the stat fold, which is SET-WINS
          // against a fresh terminal count landing on the same cycle.
          5'd1, 5'd3, 5'd5, 5'd7: begin
            if (!lh) begin
              if (!(state == S_FIN && idx[2:1] == cur))
                ch_count    [idx[2:1]][7:0]  <= din;
            end else begin
              if (!(state == S_FIN && idx[2:1] == cur))
                ch_count    [idx[2:1]][15:8] <= din;
            end
            lh <= ~lh;
          end
          // 0x11 is read-only; a write there does nothing.
          5'd8: ;
          // 0x13 software request, 0x15 single-channel mask, 0x1D clear masks and 0x1F
          // write masks all land through the folds at the top of the block, which is
          // where their same-cycle collisions with S_FIN are resolved.
          5'd9, 5'd10, R_CLEARMSK, R_ALLMSK: ;
          5'd11: ch_mode[din[1:0]] <= din;
          R_CLEAR_FF: lh <= 1'b0;
          // 0x1B master clear: zero the address and count registers (the mask-all is in
          // the mask fold). It does NOT clear the byte flip-flop: NP2kai's dmac_o1b
          // leaves dmac.lh alone (io/dmac.c:202-215) (the 8237's Master Clear flip-flop
          // rule is the unmeasured deviation). A
          // same-cycle S_FIN still books its TC (the stat fold is set-wins) but the
          // CPU's zeros win the walked registers themselves.
          R_MASTER: begin
            for (i = 0; i < 4; i = i + 1) begin
              if (!(state == S_FIN && i[1:0] == cur)) begin
                ch_addr[i]  <= 31'd0;
                ch_count[i] <= 16'd0;
              end
            end
          end
          // 0x21..0x27 bank byte, address bits 23:16 - and bits 30:24 go to ZERO, because
          // NP2kai's dmac_o21 zeroes adrs.b[DMA32_HIGH + DMA16_HIGH] on every bank write
          // (io/dmac.c:242: "25bit upper is unreachable here -> 0E05"): a bank reprogram
          // returns the channel to the low 16 MiB even after an S_FIN carry out of bit 23.
          // NP2kai's channel arithmetic is
          // '((port >> 1) + 1) & 3', so 0x21 lands on channel 1 and 0x27 on 0. QEMU's formula differs
          // and NP2kai chose theirs knowingly, so the reference is followed rather than silently
          // corrected - the one mapping the machine has never confirmed. `idx[1:0] + 2'd1` reaches 0 by
          // 2-BIT WRAPAROUND: the literal must stay 2 bits or 0x27 would index ch_addr[4].
          // ch_addr_org's bits 30:24 are never written by anything and stay zero, so the
          // autoinitialize reload cannot resurrect upper bits either.
          5'd16, 5'd17, 5'd18, 5'd19: begin
            if (!(state == S_FIN && idx[1:0] + 2'd1 == cur)) begin
              ch_addr    [idx[1:0] + 2'd1][23:16] <= din;
              ch_addr    [idx[1:0] + 2'd1][30:24] <= 7'd0000000;
            end
          end
          // 0x29 bound. Latched, and it does not alter a byte transfer.
          R_BOUND: ch_bound[din[1:0]] <= din[3:2];
          default: ;
        endcase
      end

      // The write-only registers answer 0xFF because the machine does: B1-B7 measured two
      // driven values, 0xFF and 0x00, not a float.
      if (sel && !write) begin
        case (idx)
          // The address and count registers advance the flip-flop on a READ too, not only a write
          // (NP2kai's dmac_i01/dmac_i03 both toggle). The ITF's self-test writes the SAME byte to both
          // halves and compares both reads against it, so it cannot pin this: what it DOES pin is that
          // a write toggles. The read toggle follows NP2kai and is not firmware-proven.
          5'd0, 5'd2, 5'd4, 5'd6: begin
            dout <= lh ? ch_addr[idx[2:1]][15:8] : ch_addr[idx[2:1]][7:0];
            lh   <= ~lh;
          end
          5'd1, 5'd3, 5'd5, 5'd7: begin
            dout <= lh ? ch_count[idx[2:1]][15:8] : ch_count[idx[2:1]][7:0];
            lh   <= ~lh;
          end
          // Reading the status register returns it and clears the terminal-count
          // NIBBLE, stat[3:0], which is how a driver acknowledges them - stat[7:4]
          // (the request state) survives the read, exactly NP2kai's `dmac.stat &=
          // 0xf0` (io/dmac.c:290-294). The clear is in the stat fold (set-wins
          // against a terminal count landing on the read's own cycle).
          5'd8: begin
            dout      <= stat;
          end
          // 0x1B reads 0x00 on the machine (the capture wins over NP2kai's float).
          R_MASTER: dout <= 8'h00;
          // 0x21..0x27, the bank byte's PORT read: the LOW NIBBLE ALONE. The capture decides
          // the read width - RDBACK wrote 0xA5 at 0x21/0x23/0x25/0x27 and read 0x05 back on
          // every one (docs/probes/RDBACK.TXT:153-156), so the port drives four bits - and a
          // capture outranks NP2kai, which has no read handler for these ports at all (its
          // dmaco21 table is sysout-only, io/dmac.c:354), and qemu, which returns the stored
          // byte (hw/dma/pc98-dma.c:296-298). The STORE below stays the whole byte: NP2kai's
          // compiled IA32 branch and qemu both keep it, the engine's address needs bits 23:20
          // (tb_pc9821_dmac_engine's E7d asserts a bank of 0xFF reaches 0xFFFFFF), and the
          // capture constrains the READ, not the register. The IOBUS stub this state will
          // move from returns the same nibble, so the hand-off cannot change a
          // guest-visible byte. CHANNEL MAP: `((port >> 1) + 1) & 3` (see the write arm).
          5'd16, 5'd17, 5'd18, 5'd19:
            dout <= {4'b0000, ch_addr[idx[1:0] + 2'd1][19:16]};
          // 0x29 reads ALL FOUR channels' bounds, channel n in bits 2n+1:2n. The Xe10 reads
          // `00 0C 0C 8C 8E 86 86 50` after the writes 0D (ch1 = 3), 02 (ch2 = 0), 0B (ch3 = 2),
          // 08 (ch0 = 2), 05 (ch1 = 1), none, then 00 01 06 07 (ch0 = ch1 = 0, ch2 = ch3 = 1)
          // (docs/probes/XE10Z-XE10.TXT:205 `D29 asfound w0D w02 w0B w08 w05 again final = 00 0C
          // 0C 8C 8E 86 86 50`; tools/hwprobe/xe10z/xe10z.s sec_d29): each read is that packed
          // byte, and a channel-0 write alone reads its bound in bits 1:0
          // (docs/probes/RDBACK.TXT:157 `after 04/08/0C = 01 02 03`). NP2kai and qemu-pc98 have
          // no read handler for 0x29 (io/dmac.c:336-338; hw/dma/pc98-dma.c:273-276).
          R_BOUND: dout <= bound_rd;
          5'd9, 5'd10, 5'd11, R_CLEAR_FF, R_ALLMSK: dout <= 8'hFF;
          default: dout <= 8'hFF;
        endcase
      end

      // Per byte: S_FIRST picks the side (a verify channel touches no memory; a memory-to-port
      // channel reads first; port-to-memory strobes first). S_DEV is the single strobe cycle, with
      // dack asserted. S_FIN advances the address, counts down, and reports terminal count.
      case (state)
        S_IDLE: if (any_want) begin
          // Lowest requesting, unmasked channel: the loop runs downward so the last
          // assignment is the lowest index.
          for (i = 3; i >= 0; i = i - 1)
            if (want[i]) cur <= i[1:0];
          state <= S_SEL;
        end

        // The second cycle the snapshot's route decode is given (THE ADDRESS SNAPSHOT, below).
        S_SEL: state <= S_FIRST;

        S_FIRST: begin
          cur_read   <= (ch_mode[cur][3:2] == 2'b10) || (ch_mode[cur][3:2] == 2'b11);
          cur_verify <= (ch_mode[cur][3:2] == 2'b00);
          if (ch_mode[cur][3:2] == 2'b10 || ch_mode[cur][3:2] == 2'b11) begin
            // Memory to port: read memory first, then strobe the device with the byte in S_DEV.
            mem_req  <= 1'b1;
            mem_addr <= mem_addr_nx;
            state    <= S_MEM;
          end else begin
            // Verify and port-to-memory both strobe: a verify channel consumes a byte without
            // touching memory (NP2kai calls only inproc()); port-to-memory takes the device's byte.
            state <= S_DEV;
          end
        end

        // The ACCEPT. A write completes here - the backend commits at the accept and returns nothing
        // - and a read moves on to wait for the word. Leaving S_MEM on the accept rather than the
        // response keeps mem_req single-cycle.
        S_MEM: if (mem_ready) begin
          mem_req <= 1'b0;
          if (cur_read) begin
            state <= S_RESP;     // the byte is not here yet
          end else begin
            state <= S_FIN;      // the port-to-memory write completed
          end
        end

        // The COMPLETION, a different pulse from the accept and several cycles later. Sampling the
        // word HERE rather than at the accept is the point of this state, and a bench with
        // combinational mem_rdata cannot check it.
        S_RESP: if (mem_resp_valid) begin
          cur_byte <= mem_rd_byte;
          state    <= S_DEV;     // the byte is handed to the device in S_DEV
        end

        // The single strobe cycle, the only place dev_stb is high. A memory-to-port byte is in
        // cur_byte and the device samples it during THIS cycle; a port-to-memory byte is latched here.
        S_DEV: if (cur_read || cur_verify) begin
          state <= S_FIN;
        end else begin
          cur_byte  <= dev_din;
          // Replicated across all four lanes; see the port comment. mem_be selects one lane,
          // so this is correct regardless of lane order.
          mem_din   <= {4{dev_din}};
          mem_addr  <= mem_addr_nx;
          mem_req   <= 1'b1;
          state     <= S_MEM;
        end

        S_FIN: begin
          // Advance the address, count down, and book any terminal count - with a
          // same-cycle CPU write folded in (see the event folds above): the CPU wins the
          // byte lanes it writes, the engine still walks the rest. The autoinit reload is
          // part of addr_base's select, so the two cannot resolve by source order.
          // stat/mask/sw_req bookkeeping is
          // the folds' set/clear terms, computed from fin_tc here.
          ch_addr[cur]  <= addr_hit ? addr_cpu_val : addr_base;
          ch_count[cur] <= cnt_hit  ? cnt_cpu_val  : cnt_base;
          state <= S_IDLE;
        end

        default: state <= S_IDLE;
      endcase
    end
  end

  // The combinational mirror of the read arms below (see dout_comb's port comment).
  always @* begin
    dout_comb = 8'hFF;
    if (sel && !write) begin
      case (idx)
        5'd0, 5'd2, 5'd4, 5'd6: dout_comb = lh ? ch_addr[idx[2:1]][15:8] : ch_addr[idx[2:1]][7:0];
        5'd1, 5'd3, 5'd5, 5'd7: dout_comb = lh ? ch_count[idx[2:1]][15:8] : ch_count[idx[2:1]][7:0];
        5'd8: dout_comb = stat;
        R_MASTER: dout_comb = 8'h00;
        5'd16, 5'd17, 5'd18, 5'd19:
          dout_comb = {4'b0000, ch_addr[idx[1:0] + 2'd1][19:16]};
        R_BOUND: dout_comb = bound_rd;
        default: dout_comb = 8'hFF;
      endcase
    end
  end

  assign dev_dack = (state == S_DEV) ? (4'b0001 << cur) : 4'b0000;
  assign dev_we   = (state == S_DEV) && cur_read;
  // The strobe is COMBINATIONAL on the state, because it must coincide with the data it
  // qualifies: in S_DEV a port-to-memory byte is on dev_din and is latched at the end of that
  // cycle, and a memory-to-port byte is already in cur_byte and is sampled during it.
  assign dev_stb  = (state == S_DEV);
  // TC coincides with the block's LAST byte's strobe/dack: an 8237-family device
  // qualifies EOP with its channel's DACK ("terminate after this byte"), so the two must
  // be high together. NP2kai's engine fires DMAEXT_END in the same step as the final
  // byte's inproc/outproc (mem/dmax86.c:19-24 calls extproc before the byte moves in the
  // loop iteration that consumes the zero count), and the 8237 asserts EOP during the
  // final transfer cycle - a registered tc pulse would come >= 2 cycles LATE (later on
  // the port->mem path) with every dack down.
  assign dev_tc   = (state == S_DEV) && (ch_count[cur] == 16'd0);
  // The same terminal count on the MEMORY side (see the port comment): by S_FIN a
  // port-to-memory block's every write has been accepted, which is what a
  // cache-coherency consumer needs and dev_tc does not provide.
  assign mem_tc   = fin_tc && !cur_read && !cur_verify;
  assign dev_ch   = cur;
  assign dev_dout = cur_byte;

  assign mem_we = mem_req && !cur_read && !cur_verify;

  // One byte, one lane, chosen by the address's low bits so a byte access reaches the right
  // byte of the backend's 32-bit word - consistent with its rule that addr[1:0] is ignored.

  // The two mem_addr loads below: S_FIRST of a memory-to-port channel (mode bits 3:2 = 10/11)
  // and S_DEV of a port-to-memory one.
  assign mem_addr_nx = {1'b0, ld_addr};

  // ==== THE ENGINE CHANNEL'S ADDRESS, ONE STEP AHEAD ====
  // mem_addr_nx feeds pc9821_memory_subsystem's DMA route decode, which registers the byte's
  // backend address and route class through the whole memory map at mem_load. Read as
  // ch_addr[cur], that was a single-cycle path from S_IDLE's `cur` choice (S_FIRST of a
  // memory-to-port channel loads in the very next cycle) through the 31-bit channel mux and the
  // map into dma_be_addr/dma_cls, and it missed setup in STA on every seed of every sweep (xt:
  // -3.69 ns, rr1: -4.39 ns). cur_addr_q is a REGISTER that equals ch_addr[cur] in every cycle:
  // it is loaded with the next value of ch_addr at the next `cur` - S_IDLE's want priority
  // choosing the channel, S_FIN's folded advance for the channel the engine is on, and every
  // other cycle the CPU's raw writes to that channel (an address half, a bank byte, the master
  // clear), which are the only other writers of ch_addr. No state moves and no byte changes
  // timing; tools/check_seq_equiv.py --proof dmac_cur_addr proves the module cycle-identical to
  // the ch_addr[cur] form, with cur_addr_q == ch_addr[cur] as the induction's invariant.
  wire [1:0] cur_nx = (state == S_IDLE && any_want) ? (want[0] ? 2'd0 : want[1] ? 2'd1 :
                                                      want[2] ? 2'd2 : 2'd3) : cur;
  reg  [30:0] cur_addr_nx;
  always @* begin
    cur_addr_nx = ch_addr[cur_nx];
    if (state == S_FIN)
      cur_addr_nx = addr_hit ? addr_cpu_val : addr_base;    // cur_nx == cur here
    else if (cpu_master)
      cur_addr_nx = 31'd0;
    else if (cpu_addr_half && (cpu_chan == cur_nx)) begin
      if (lh) cur_addr_nx[15:8] = din;
      else    cur_addr_nx[7:0]  = din;
    end else if (cpu_bank && (cpu_bank_ch == cur_nx)) begin
      cur_addr_nx[23:16] = din;
      cur_addr_nx[30:24] = 7'd0;
    end
  end
  always @(posedge clk) cur_addr_q <= reset ? 31'd0 : cur_addr_nx;

  // ==== THE ADDRESS SNAPSHOT (owner decision 2026-11-13, docs/trade-candidates.md T89) ====
  // The byte's address (cur_addr_q alone above) still reached pc9821_memory_subsystem's DMA route
  // decode in ONE cycle: cur_addr_q -> the whole memory map -> dma_be_addr/dma_cls, 13.3-14.9 ns of
  // data on an 11.1 ns clk_sys (the pf2-755a892d census, every seed). The map does not fit a cycle.
  // So the address the load uses is a snapshot, ld_addr, taken two cycles before the load, and
  // S_SEL (one state between S_IDLE and S_FIRST, +1 clk_sys per DMA byte) gives the second cycle:
  //   * memory-to-port (S_FIRST loads): ld_addr is taken at S_IDLE's accept, from ch_addr[cur] as
  //     the accept's edge leaves it (cur_addr_nx) - the address S_FIRST loaded before S_SEL existed;
  //   * port-to-memory (S_DEV loads, two states after S_SEL): ld_addr is taken again in S_SEL, which
  //     is the cycle the parent's S_FIRST occupied, so a CPU write to the channel's address up to that
  //     cycle is seen, as it was.
  // So each byte loads the address the parent loaded, one clk_sys later. ld_addr is written nowhere
  // else, and no load happens within two cycles of either snapshot (S_SEL -> S_FIRST, and S_SEL ->
  // S_FIRST -> S_DEV), so ld_addr -> the subsystem's load registers is an exact two-cycle path: the
  // SDC's pc9821_mc_dmaaddr multicycle (tools/profile_gen.py CEN_MULTICYCLES, sdc_exceptions.tsv
  // mc_dmaaddr_*), and the SIM-ONLY check below asserts the premise at every load.
  reg [30:0] ld_addr;
  wire       ld_we = (state == S_IDLE && any_want) || (state == S_SEL && !ch_mode[cur][3]);
  always @(posedge clk)
    if (reset) ld_addr <= 31'd0;
    else if (ld_we)
      ld_addr <= cur_addr_nx;
  // synthesis translate_off
  // The multicycle's premise, at every load: a load in cycle L captures at the edge ending L, and
  // -setup 2 allows a launch no later than the edge ending L-2, so ld_addr must not be WRITTEN at the
  // edge between L-1 and L (its write enable low in L-1), whatever value a write would carry, and its
  // value in L equals its value in L-1.
  reg [30:0] ld_addr_d1;
  reg        ld_we_d1, ld_live;
  always @(posedge clk) begin
    ld_addr_d1 <= ld_addr;
    ld_we_d1   <= ld_we && !reset;
    ld_live    <= !reset;
    if (ld_live && !reset && mem_load && (ld_we_d1 || (ld_addr != ld_addr_d1)))
      $fatal(1, "pc9821_dmac: the byte's address snapshot was written inside its two-cycle window (%08h -> %08h, state %0d)",
             ld_addr_d1, ld_addr, state);
  end
  // synthesis translate_on
  // synthesis translate_off
  // The invariant the cut rests on, every cycle after a reset: the shadow IS ch_addr[cur].
  /* verilator lint_off PROCASSINIT */   // 0 until the first reset has set it
  reg cur_addr_live = 1'b0;
  /* verilator lint_on PROCASSINIT */
  always @(posedge clk) begin
    cur_addr_live <= cur_addr_live || reset;
    if (cur_addr_live && !reset && (cur_addr_q != ch_addr[cur]))
      $fatal(1, "pc9821_dmac: cur_addr_q %08h differs from ch_addr[%0d] %08h (state %0d)",
             cur_addr_q, cur, ch_addr[cur], state);
  end
  // synthesis translate_on
  // The port-to-memory load is the store's: its byte is written at S_MEM (mem_we above). The
  // S_FIRST load is a memory-to-port channel's read, so it carries no direction bit.
  assign mem_load_we = (state == S_DEV) && !(cur_read || cur_verify);
  assign mem_load    = ((state == S_FIRST) && ch_mode[cur][3]) || mem_load_we;

  assign mem_be = (mem_addr[1:0] == 2'd0) ? 4'b0001 :
                  (mem_addr[1:0] == 2'd1) ? 4'b0010 :
                  (mem_addr[1:0] == 2'd2) ? 4'b0100 : 4'b1000;

endmodule

`default_nettype wire
