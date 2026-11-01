// PC-9821 graphics palette: palette index and colour mode -> the RGB the picture is
// painted with.
//
// The ANALOGUE table (the CPU's 0xA8 index / 0xAA green / 0xAC red / 0xAE blue registers,
// 16 entries x 12 bits) is a LIVE table the CPU writes and a DISPLAYED one the scanout
// reads, copied live->displayed at the frame boundary (17 clk_sys, always inside a blank). A
// bank swap would lose the accumulated register state. The displayed read is ASYNCHRONOUS,
// so no dot of the pixel path moves.
//
// MEASURED (module-alone Quartus probes): only ONE of these two tables can be a small RAM. `disp` is read ASYNCHRONOUSLY on the dot path and an asynchronous read is refused
// by every block type on this device, MLAB included (`Info (276007) ... uninferred due to
// asynchronous read logic` with no attribute, and a second, independent refusal - `276009 ...
// unsupported read-during-write behavior` - with `ramstyle = "MLAB"`). A Cyclone V MLAB is
// `altdpram`: clocked, so it cannot serve a combinational read at all, which is why `disp`
// cannot be moved without a register on the dot path. So `disp` stays the 192 flops it was.
//
// `live` is the other case: its read IS registered (`cp_q <= live[cp_cnt[3:0]]`, inside the
// frame-boundary copy, one cycle before the value is stored), so moving it to block memory
// changes no address->q latency (trade T13, `docs/trade-candidates.md`): it is three 16x4 nibble lanes in M10K. The nibble split is what infers - a write into a
// 16x12 word is nibble-granular, and a sub-word write refuses inference in every block type
// (the same result as `pc9821_crtc`'s palette mirror and the CG glyph block). Both measured
// with the shipped read shape, including the copy register's reset:
// 151 ALMs as one 16x12 flop table, 31 with the
// three lanes and the resets kept, 7 with the resets dropped from the three read registers;
// and this file's own before/after via `tools/res_exp_map.py --top pc9821_gfx_palette`:
// **296 -> 177 ALMs, 399 -> 215 combinational ALUTs, 402 -> 261 registers, 0 -> 3 M10K blocks.**
//
// The digital bytes and the mode latch stay in pc9821_crtc and arrive here as the
// frame-coherent snapshot. Owns the READ only; separate from pc9821_plane_fold so PEGC's
// packed mode can bypass the fold. Output is {R,G,B}
// nibbles. Derivation: corrections

`default_nettype none

module pc9821_gfx_palette (
    // clk_sys and clk_vid are the same net at the top level (pc9821_system), so one clock
    // port serves both the CPU write port and the frame-boundary copy.
    input  wire        clk,
    input  wire        rst_n,
    // The index: the plane fold {E,G,R,B}, or {G,R,B} in digital mode. Eight bits to
    // match the packed PEGC path in pc9821_video_mixer; only the low nibble resolves
    // here. The analogue read is asynchronous, so it is THIS dot's index.
    /* verilator lint_off UNUSEDSIGNAL */
    input  wire [7:0]  idx,
    /* verilator lint_on UNUSEDSIGNAL */
    // 1 = 16-colour analogue, 0 = 8-colour digital (mode latch 2 bit 0), snapshot.
    input  wire        mode16,
    // The four digital bytes as written, {0xA8, 0xAA, 0xAC, 0xAE}, snapshot.
    input  wire [31:0] dig,
    // The analogue table's CPU write port: 0xA8 selected the entry (widx), 0xAA/0xAC/0xAE
    // write G/R/B into it, so one write carries one channel. It lands in the LIVE table,
    // which the displayed table is copied from at the next frame boundary. widx is
    // palnum & 15 (NP2kai gdc_setanalogpal(gdc.palnum & 15), io/gdc.c:862): the 0xA8
    // register is a FULL 8-bit palnum; the read mirror in pc9821_crtc
    // also takes the MASKED palnum & 15 (PEGC's 256-colour palette is out of scope, so
    // the mirror is 16 entries like this table).
    input  wire        we,
    input  wire [3:0]  widx,
    input  wire [1:0]  wchan,       // 0 = G (0xAA), 1 = R (0xAC), 2 = B (0xAE)
    input  wire [3:0]  wdata,
    // The frame boundary, which starts the live-to-displayed copy.
    input  wire        commit,
    // {R,G,B} nibbles for the selected entry.
    output wire [11:0] colour,

    // ---- the PEGC 256-colour table ----
    // A SECOND store, not a widening of disp: the references keep the 256-colour
    // palette beside the 16-colour one (MAME m_pegc.r/g/b[256] beside m_analog16;
    // NP2kai anareg[16*3 + palnum*4 + c] beside anareg[palnum*3+c]). Three 256x8
    // M10K byte lanes with a REGISTERED dot-path read - the async form is not
    // deployable (the 276007 refusal, measured again at 2,264 ALMs standalone)
    // - and FULL bytes per channel, because NP2kai
    // renders them verbatim (`pal_make9821`: `p[i].p.g = pal[i*4+0]`, vram/palettes.c).
    // The registered read delays this arm by the one clk_sys the text arm takes
    // beside it (pc9821_video_mixer's mode mux), so the picture moves uniformly
    // and the 16-colour path does not move at all.
    input  wire        p256_we,
    input  wire [7:0]  p256_widx,     // the UNMASKED 0xA8 index
    input  wire [1:0]  p256_wchan,    // 0 = G, 1 = R, 2 = B
    input  wire [7:0]  p256_wdata,    // the FULL byte (NP2kai stores it verbatim)
    input  wire [7:0]  idx256,        // the packed pixel's palette index
    output reg  [23:0] colour256      // registered: {R,G,B} full bytes
);

  // THE PEGC 256-COLOUR STORE: the lane form that infers (whole-byte writes into
  // byte lanes; a 256x24 word written byte-wise refuses every block type and the
  // register form measures 4,258 ALMs).
  (* ramstyle = "M10K" *) reg [7:0] pal256_g [0:255];
  (* ramstyle = "M10K" *) reg [7:0] pal256_r [0:255];
  (* ramstyle = "M10K" *) reg [7:0] pal256_b [0:255];

  integer p256_i;
  initial begin
    // Zero-seeded (NP2kai's gdc_reset zeroes the store); the read register is
    // left to its own clocked assignment's zero power-up (a non-default value on
    // the register that captures a memory read is what refuses the inference).
    for (p256_i = 0; p256_i < 256; p256_i = p256_i + 1) begin
      pal256_g[p256_i] = 8'h00;
      pal256_r[p256_i] = 8'h00;
      pal256_b[p256_i] = 8'h00;
    end
    colour256 = 24'h000000;
  end

  // The write port: one whole byte into the lane its channel names.
  always @(posedge clk) begin
    if (p256_we) begin
      if (p256_wchan == 2'd0)      pal256_g[p256_widx] <= p256_wdata;
      else if (p256_wchan == 2'd1) pal256_r[p256_widx] <= p256_wdata;
      else                         pal256_b[p256_widx] <= p256_wdata;
    end
  end

  // The dot-path read, REGISTERED and in its own always block (a read and a write
  // of the same RAM in one block reads as an asynchronous port and the memory
  // never infers).
  always @(posedge clk) begin
    colour256 <= {pal256_r[idx256], pal256_g[idx256], pal256_b[idx256]};
  end

  // The CPU's current table (`live`, one lane per colour channel, one whole-nibble write and
  // one registered read port each) and the frame-coherent copy the scanout reads
  // (`disp`, 16 x 12, asynchronous read - see the header for why it stays flops).
  (* ramstyle = "M10K" *) reg [3:0] live_g [0:15];
  (* ramstyle = "M10K" *) reg [3:0] live_r [0:15];
  (* ramstyle = "M10K" *) reg [3:0] live_b [0:15];
  reg [11:0] disp [0:15];

  // The NEC 16-colour power-on table (itf.rom 0x042F; the source packs {G,R,B} and this
  // table is {R,G,B}, so entry 2 is red and entry 4 green). Both tables start at it, so
  // the first frame already shows it, exactly as the snapshot it replaces did. The lanes
  // are seeded lane-by-lane from the same word (a block RAM's power-up contents come from
  // its own MIF, so each lane needs its own seed).
  //
  // A case function, not an unpacked localparam array: Quartus 17.0.2 rejects an aggregate
  // parameter ("parameter with complex/aggregate value must have a type").
  function [11:0] pal_power_on(input [3:0] e);
    case (e)
      4'd0:  pal_power_on = 12'h000;
      4'd1:  pal_power_on = 12'h007;
      4'd2:  pal_power_on = 12'h700;
      4'd3:  pal_power_on = 12'h707;
      4'd4:  pal_power_on = 12'h070;
      4'd5:  pal_power_on = 12'h077;
      4'd6:  pal_power_on = 12'h770;
      4'd7:  pal_power_on = 12'h777;
      4'd8:  pal_power_on = 12'h444;
      4'd9:  pal_power_on = 12'h00F;
      4'd10: pal_power_on = 12'hF00;
      4'd11: pal_power_on = 12'hF0F;
      4'd12: pal_power_on = 12'h0F0;
      4'd13: pal_power_on = 12'h0FF;
      4'd14: pal_power_on = 12'hFF0;
      default: pal_power_on = 12'hFFF;
    endcase
  endfunction

  integer i;
  reg [11:0] po;
  initial begin
    for (i = 0; i < 16; i = i + 1) begin
      po = pal_power_on(i[3:0]);
      live_g[i] = po[7:4];
      live_r[i] = po[11:8];
      live_b[i] = po[3:0];
      disp[i]   = po;
    end
  end

  // The CPU write port, into the LIVE table: one WHOLE nibble into the lane its channel
  // names, which is the shape that infers (a lane's write enable is its own channel's, so
  // the other two lanes see a write-enable-low port). wchan is 0/1/2 by construction
  // (pc9821_crtc's pal_wr_chan: 22->G, 23->R, else B), and the `else` writes blue for
  // wchan == 3.
  always @(posedge clk) begin
    if (we) begin
      if (wchan == 2'd0)      live_g[widx] <= wdata;   // 0xAA green, live[7:4]
      else if (wchan == 2'd1) live_r[widx] <= wdata;   // 0xAC red,   live[11:8]
      else                    live_b[widx] <= wdata;   // 0xAE blue,  live[3:0]
    end
  end

  // ---- the frame-boundary copy: live[0..15] -> disp[0..15] -------------------
  // Seventeen cycles: cp_cnt 0 reads live[0] into cp_q, 1..16 write disp[cp_cnt-1]
  // from cp_q (cp_cnt 16 writes disp[15], negated to index 15). commit arriving while a
  // copy is running is dropped, which cannot lose a change: the copy reads the live
  // table as it goes, and the next boundary copies again.
  //
  // The three lane reads are in the SAME cycle at the SAME index, so a word is copied whole
  // and never mixed with another entry's; and a CPU write in the cycle the copy reads that
  // entry still loses, because the read is the pre-edge content - the same read-before-write
  // the flop table had (pinned by tb_pc9821_gfx_palette's copy-boundary case). A block RAM's
  // read-during-write is the one place that could differ, and a single-clock memory is the
  // mode Quartus REPRODUCES rather than leaves undefined: the map log's
  // `276020 ... pass-through logic added to match the read-during-write behavior` is that
  // promise, and its absence for these three lanes would be a defect (the dual-clock
  // `276027` and the refused `276009` are the two other messages to look for). It is emitted
  // for all three lanes, and the fitter's functional netlist was simulated against this RTL
  // with the same stimulus to check the promise rather than trust it: identical for the
  // power-on table, the post-copy table and every write/copy collision offset.
  reg [4:0]  cp_cnt;
  reg        cp_busy;
  reg [11:0] cp_q;
  always @(posedge clk) begin
    if (!rst_n) begin
      cp_busy <= 1'b0;
      cp_cnt  <= 5'd0;
      cp_q    <= 12'h000;
    end else if (commit && !cp_busy) begin
      cp_busy <= 1'b1;
      cp_cnt  <= 5'd0;
    end else if (cp_busy) begin
      if (cp_cnt != 5'd16) begin
        cp_q[7:4]  <= live_g[cp_cnt[3:0]];
        cp_q[11:8] <= live_r[cp_cnt[3:0]];
        cp_q[3:0]  <= live_b[cp_cnt[3:0]];
      end
      if (cp_cnt >= 5'd1)  disp[cp_cnt[3:0] - 4'd1] <= cp_q;
      if (cp_cnt == 5'd16) cp_busy <= 1'b0;
      cp_cnt <= cp_cnt + 5'd1;
    end
  end

  // ---- the digital (8-colour) table ----
  // Four bytes of per-bit colour: R = bit 5, G = bit 6, B = bit 4, written as
  // `(byte & mask) ? F : 0` with a SINGLE-BIT mask (a multi-bit condition is true when
  // NON-ZERO, not when bit 0 is set - probed, not assumed). entry 0 = 0xAE, 1 = 0xAA,
  // 2 = 0xAC, 3 = 0xA8; entries 0..3 take each register's high nibble and 4..7 its low,
  // so {G,R,B} indexes them directly. The 3-bit select ignores idx[3]: in 8-colour mode
  // the intensity bit is not a colour.
  wire [7:0] d0 = dig[7:0];    // 0xAE
  wire [7:0] d1 = dig[23:16];  // 0xAA
  wire [7:0] d2 = dig[15:8];   // 0xAC
  wire [7:0] d3 = dig[31:24];  // 0xA8
  /* verilator lint_off WIDTHTRUNC */
  wire [11:0] digpal [0:7];
  assign digpal[0] = { (d0 & 8'h20) ? 4'hF : 4'h0,
                       (d0 & 8'h40) ? 4'hF : 4'h0,
                       (d0 & 8'h10) ? 4'hF : 4'h0 };
  assign digpal[1] = { (d1 & 8'h20) ? 4'hF : 4'h0,
                       (d1 & 8'h40) ? 4'hF : 4'h0,
                       (d1 & 8'h10) ? 4'hF : 4'h0 };
  assign digpal[2] = { (d2 & 8'h20) ? 4'hF : 4'h0,
                       (d2 & 8'h40) ? 4'hF : 4'h0,
                       (d2 & 8'h10) ? 4'hF : 4'h0 };
  assign digpal[3] = { (d3 & 8'h20) ? 4'hF : 4'h0,
                       (d3 & 8'h40) ? 4'hF : 4'h0,
                       (d3 & 8'h10) ? 4'hF : 4'h0 };
  assign digpal[4] = { (d0 & 8'h02) ? 4'hF : 4'h0,
                       (d0 & 8'h04) ? 4'hF : 4'h0,
                       (d0 & 8'h01) ? 4'hF : 4'h0 };
  assign digpal[5] = { (d1 & 8'h02) ? 4'hF : 4'h0,
                       (d1 & 8'h04) ? 4'hF : 4'h0,
                       (d1 & 8'h01) ? 4'hF : 4'h0 };
  assign digpal[6] = { (d2 & 8'h02) ? 4'hF : 4'h0,
                       (d2 & 8'h04) ? 4'hF : 4'h0,
                       (d2 & 8'h01) ? 4'hF : 4'h0 };
  assign digpal[7] = { (d3 & 8'h02) ? 4'hF : 4'h0,
                       (d3 & 8'h04) ? 4'hF : 4'h0,
                       (d3 & 8'h01) ? 4'hF : 4'h0 };
  /* verilator lint_on WIDTHTRUNC */

  // The lookup is COMBINATIONAL, exactly as the register tables it replaces were: the
  // displayed table is an asynchronous-read memory and the digital decode is logic. No
  // dot of the pixel path moves (see the header).
  assign colour = mode16 ? disp[idx[3:0]] : digpal[idx[2:0]];

endmodule

`default_nettype wire
