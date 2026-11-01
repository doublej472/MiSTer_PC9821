// MiSTer ioctl -> hidden PC-9821 firmware-pack writer.
// Native valid/ready backend interface; no ao486/Avalon compatibility layer.

`default_nettype none

module pc9821_rom_loader #(
    parameter [15:0] IOCTL_INDEX = 16'd0,
    // The firmware reserve: a documented, deliberate number, not a constant to be
    // assumed. It is 1 MiB so that bulk data the CPU reads belongs in the SDRAM
    // pack rather than in block RAM (README.md, design policy), and it must move
    // together with gvram_base (pc9821_memory_subsystem.sv), the OSD RAM-size
    // budget (z486_mister.sv) and the layout in tools/build_pack.py. Everything at
    // or above it fails closed: a download that reaches this bound raises
    // load_error and the CPU is never released.
    parameter [26:0] PACK_BYTES = 27'h010_0000
) (
    input wire clk,
    input wire reset,

    // Runtime base so the reserve can track the OSD-configured guest RAM
    // size (the pack always sits directly above the configured guest RAM).
    input  wire [31:0] pack_base,
    // The top-window shadow store's base (pack_base + PACK_BYTES + 0x58000). The BIOS-top
    // bank staged below is teed into it so the shadow's unwritten offsets read as ROM
    // instead of SDRAM residue; see the tee at the bottom of the staging block.
    input  wire [31:0] shadow_base,

    input  wire        ioctl_download,
    input  wire [15:0] ioctl_index,
    input  wire        ioctl_wr,
    input  wire [26:0] ioctl_addr,
    input  wire [15:0] ioctl_dout,
    output wire        ioctl_wait,

    output reg         mem_valid,
    input  wire        mem_ready,
    output reg  [31:0] mem_addr,
    output reg  [31:0] mem_din,
    output reg  [3:0]  mem_be,
    output wire [7:0]  mem_burstcount,
    output wire        mem_write,

    output reg         rom_ready,
    output reg         load_error,
    output wire        saw_download,
    // rom_ready && !load_error, as its own register (written from the two flags' next state, so
    // equal to their AND in every cycle). The subsystem's cpu_run; see the next-state block below.
    output reg         cpu_run
);

  reg download_d;
  wire selected = ioctl_download && (ioctl_index == IOCTL_INDEX);
  wire incoming = selected && ioctl_wr;
  wire address_ok = (ioctl_addr < PACK_BYTES) && !ioctl_addr[0];

  // The three flags below deliberately survive reset, so they have no reset arm in the
  // clocked block - which leaves them undriven until the first download in a 4-state
  // simulation, where they power up as X and propagate it to cpu_run/cpu_reset_n
  // Power-on determinism comes from here instead, matching the
  // persistent registers' `initial` blocks in pc9821_block_io.sv:341 and pc9821_iobus.sv:1318.
  initial begin
    rom_ready    = 1'b0;
    load_error   = 1'b0;
    cpu_run      = 1'b0;
  end
  // saw_download is a set-only flag, so its power-up 0 must sit on an internal register: on an
  // output port Quartus ignores the value, and ALLOW_POWER_UP_DONT_CARE then ties a register
  // whose data input is the constant 1 to VCC (docs/policies.md, the power-up rule), which would
  // raise rom_ready before any download.
  /* verilator lint_off PROCASSINIT */  // the power-up value, kept by Quartus on an internal register
  reg saw_download_r = 1'b0;
  /* verilator lint_on PROCASSINIT */
  assign saw_download = saw_download_r;

  // THE BIOS-TOP BANK IS TEED INTO THE TOP-WINDOW SHADOW. The shadow is a
  // 32 KiB store in the SDRAM reserve above the pack; the map reads it as the window's
  // writable layer. Its unwritten offsets must read as ROM, and the pack's BIOS-top bank
  // is exactly that image -- so a word whose pack offset falls in [0x20000, 0x28000) is
  // written a second time, at the shadow. WRITE-side only: no read is issued.
  localparam [31:0] TOP_BANK_OFF   = 32'h0002_0000;
  localparam [31:0] TOP_BANK_BYTES = 32'h0000_8000;
  wire [31:0] stage_off    = {5'd0, ioctl_addr[26:2], 2'b00};
  wire        stage_in_top = (stage_off >= TOP_BANK_OFF) &&
                             (stage_off < (TOP_BANK_OFF + TOP_BANK_BYTES));

  // THE REQUEST SEQUENCE: one request at a time, each with its own explicit
  // valid->ready->deassert. The pack write is one request; a BIOS-top word owes a second,
  // the shadow write. S_GAP holds mem_valid LOW for a full cycle between them, so mem_addr
  // is never re-pointed while mem_valid is high. busy spans the whole sequence, so
  // ioctl_wait does not release the next ioctl word until BOTH writes are accepted.
  localparam [1:0] S_IDLE   = 2'd0;   // nothing outstanding; the only state that latches a word
  localparam [1:0] S_PACK   = 2'd1;   // presenting the pack write
  localparam [1:0] S_GAP    = 2'd2;   // mem_valid LOW: the explicit deassert between the two
  localparam [1:0] S_SHADOW = 2'd3;   // presenting the shadow (tee) write

  reg  [1:0]  state;
  reg         tee_needed;
  reg  [31:0] tee_addr;
  wire        busy = (state != S_IDLE);

  // THE TWO PERSISTENT FLAGS' NEXT STATE, one expression each (R2), so `cpu_run` can be
  // registered from them and equal `rom_ready && !load_error` in every cycle (proven by
  // tools/check_cpu_run_inv.py, induction over this module).
  //   * The download's first selected cycle (`sel_edge`, the loader's own edge: download_d is
  //     reset, so the first selected cycle after a platform reset is one too) clears both.
  //   * An out-of-range word (`bad_word`, only while selected) raises load_error. In the edge
  //     cycle itself the two meet and the raise wins: the word is this download's.
  //   * rom_ready falls on the deselect cycle and rises once the request sequence is idle with
  //     no error; both arms need !selected, so they never meet the edge's clear.
  wire sel_edge = selected && !download_d;
  wire bad_word = (state == S_IDLE) && incoming && !address_ok;
  wire load_error_nx = bad_word ? 1'b1 : (sel_edge ? 1'b0 : load_error);
  wire rom_ready_nx  = sel_edge ? 1'b0 :
                       (download_d && !selected) ? 1'b0 :
                       (saw_download && !selected && !busy && !load_error) ? 1'b1 :
                       rom_ready;

  // One internal word buffer decouples ioctl from SDRAM. A word presented while
  // wait is low is captured even if the backend is stalled; wait then remains
  // high until its whole request sequence is accepted.
  assign ioctl_wait = selected && busy;
  assign mem_burstcount = 8'd1;
  assign mem_write = 1'b1;

  always @(posedge clk) begin
    if (reset) begin
      download_d <= 1'b0;
      mem_valid <= 1'b0;
      mem_addr <= 32'd0;
      mem_din <= 32'd0;
      mem_be <= 4'd0;
      state <= S_IDLE;
      tee_needed <= 1'b0;
      tee_addr <= 32'd0;
      // Keep saw_download/load_error/rom_ready (and cpu_run, their AND) across a core (OSD) reset: the
      // pack data lives in SDRAM, whose JEDEC re-initialization does not
      // disturb stored data, so a reset must not force a full re-download.
    end else begin
      download_d <= selected;

      rom_ready  <= rom_ready_nx;
      load_error <= load_error_nx;
      cpu_run    <= rom_ready_nx && !load_error_nx;
      if (sel_edge) saw_download_r <= 1'b1;

      case (state)
      S_IDLE: begin
        if (incoming) begin
          if (address_ok) begin
            mem_addr <= pack_base + stage_off;
            if (ioctl_addr[1]) begin
              mem_din <= {ioctl_dout, 16'd0};
              mem_be <= 4'b1100;
            end else begin
              mem_din <= {16'd0, ioctl_dout};
              mem_be <= 4'b0011;
            end
            tee_addr   <= shadow_base + (stage_off - TOP_BANK_OFF);
            tee_needed <= stage_in_top;
            mem_valid  <= 1'b1;
            state      <= S_PACK;
          end
          // else: an out-of-range word - load_error_nx (bad_word) raises the error.
        end
      end
      S_PACK: begin
        if (mem_ready) begin          // the pack write is accepted
          mem_valid <= 1'b0;          // deassert: one request is one valid->ready cycle
          state     <= tee_needed ? S_GAP : S_IDLE;
        end
      end
      S_GAP: begin
        mem_addr  <= tee_addr;        // re-point only while mem_valid is low
        mem_valid <= 1'b1;
        state     <= S_SHADOW;
      end
      S_SHADOW: begin
        if (mem_ready) begin          // the shadow write is accepted
          mem_valid <= 1'b0;
          state     <= S_IDLE;
        end
      end
      endcase

      // (ioctl_download may drop on the cycle the final request is accepted: rom_ready_nx waits
      // until the sequence is idle before publishing ready.)
    end
  end

endmodule

`default_nettype wire
