// pc9821_disk_led - the access lamps: MiSTer LED_DISK (every drive's data transfers) and
// LED_USER (the floppy's alone). Display only: nothing the guest can read comes from here.
//
// WHAT LIGHTS THE LAMP: DATA TRANSFERS, NOT COMMANDS. The lamp lights while a drive moves data
// with its image and for HOLD_MS after:
//   * the hard disks: pc9821_ata's `xfer`, a sector read or write the block adapter has been
//     handed and has not finished answering;
//   * the CD drive: pc9821_atapi's `xfer`, the engine fetching data sectors for a READ;
//   * the floppy controller: its media data path out of X_IDLE (READ DATA, WRITE DATA, FORMAT,
//     READ ID, the missing-sector search), the x_st field of its dbg_state tap {IRQ, DRQ, st,
//     x_st} (pc9821_fdc.sv `assign dbg_state  = {irq, dma_drq, st, x_st};`).
// A command that moves no data - an ATA status poll or IDENTIFY, an ATAPI TEST UNIT READY or GET
// EVENT STATUS NOTIFICATION, an FDC SENSE INTERRUPT STATUS or SENSE DRIVE STATUS, a SEEK - leaves
// the lamp dark. This is how ao486 drives its lamps: from the HPS block requests alone
// (ao486.sv `led hdd_led(clk_sys, |mgmt_req[5:0], LED_DISK[0]);` and
// `led fdd_led(clk_sys, |mgmt_req[7:6], LED_USER);`), so a guest polling an idle drive does not
// blink it. (The previous lamp
// followed BSY|DRQ - the ATA DASP- condition - and a guest polling the CD drive blinked it.)
//
// WHICH LED. sys_top.v shows LED_DISK on the DE10-Nano board LED and on the I/O board's HDD LED
// (sys_top.v `assign LED_HDD   = av_dis ? 1'bZ : mcp_en ? (sog & ~cs1) : led_d ? 1'bZ : 1'b0;`),
// while LED_USER's I/O-board pin is shared with the VGA DAC clock
// (sys_top.v `assign LED_USER  = VGA_TX_CLK;`), so it is not a dependable lamp there. So led_disk
// carries all three devices - the floppy included, or an I/O-board user would never see a floppy
// access - and led_fdd keeps the floppy-only lamp on LED_USER that ao486 also has (its fdd_led
// above), so a board-LED user can still tell a floppy access from a hard-disk one.
//
// THE HOLD (HOLD_MS, display-only, NOT a guest-visible rate). A block transfer can complete in
// microseconds (a cached host read), which would never light an LED visibly, so each lamp is
// held on for HOLD_MS after its activity ends - 50 ms, the order of ao486's `led` module (a
// fixed `counter <= 4500000;` clk_sys reload).
// Continuous activity keeps the lamp lit. HOLD_MS derives a clk count from CLK_HZ
// (pc9821_system's SYS_FREQ), so it is the same wall time at every build clock.
//
// LEVELS, NOT EVENTS. Every input is a level and each lamp is one register written once per
// cycle (single-cycle-event-discipline R2): while the activity is high the hold counter is
// reloaded, so new activity restarts the full hold; once it drops the counter runs down and the
// lamp goes out at zero. No edge is detected and no pulse is produced.

`default_nettype none

module pc9821_disk_led #(
    parameter integer CLK_HZ  = 50_000_000,
    parameter integer HOLD_MS = 50
) (
    input  wire       clk,
    input  wire       reset,
    // pc9821_ata's `xfer` (both hard-disk contexts) and pc9821_atapi's (the CD drive).
    input  wire       ata_xfer,
    input  wire       cd_xfer,
    // pc9821_fdc's dbg_state[2:0] (x_st, X_IDLE = 0).
    input  wire [2:0] fdc_x_st,
    output wire       led_disk,
    output wire       led_fdd
);

  localparam integer HOLD = (CLK_HZ / 1000) * HOLD_MS;
  localparam integer W    = $clog2(HOLD + 1);
  localparam [W-1:0] HOLD_W = W'(HOLD);

  wire fdd_xfer  = (fdc_x_st != 3'd0);
  wire disk_xfer = ata_xfer | cd_xfer | fdd_xfer;

  // Cleared by `reset` (pc9821_system's, asserted from power-up until the PLL locks); the
  // outputs are plain wires of these registers.
  reg [W-1:0] disk_hold, fdd_hold;
  reg         disk_lit, fdd_lit;
  assign led_disk = disk_lit;
  assign led_fdd  = fdd_lit;

  always @(posedge clk) begin
    if (reset) begin
      disk_hold <= '0; disk_lit <= 1'b0;
      fdd_hold  <= '0; fdd_lit  <= 1'b0;
    end else begin
      disk_hold <= disk_xfer ? HOLD_W : (disk_hold != '0) ? disk_hold - 1'b1 : '0;
      disk_lit  <= disk_xfer | (disk_hold != '0);
      fdd_hold  <= fdd_xfer ? HOLD_W : (fdd_hold != '0) ? fdd_hold - 1'b1 : '0;
      fdd_lit   <= fdd_xfer | (fdd_hold != '0);
    end
  end

endmodule

`default_nettype wire
