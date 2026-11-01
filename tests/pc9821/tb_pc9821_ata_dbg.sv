// tb_pc9821_ata_dbg - the ATA's two diagnostic bytes, which the stall watchdog prints.
//
// Why this exists. The watchdog message's A, K, X and Z fields are these two outputs,
// and they are the project's ONLY view of the drive on real hardware: a MiSTer
// was diagnosed from a capture whose `A=0x40` and `K=0/X=0/Z=0` came from here. Three
// benches declare and connect these wires and NOT ONE of them asserts a value - so the
// byte the machine is read through has never been checked. That is the "a check that
// cannot fail is not a check" class this project has already found six times.
//
// Where the expectations come from, because a test must capture how the MACHINE behaves
// and not how the RTL is written:
//
//   * 0x40 on a card with an image mounted and no IDE bank selected - this is a
//     real card's capture, and it is the first assertion in this file. It decodes as
//     device_present=0, mounted=1, channel_reg[0]=0, X_IDLE, BSY=0, DRQ=0. The
//     interesting part is that it is CORRECT: the Xe10's ITF never writes 0x0432 at all
//     (the bytes 32 04 do not occur anywhere in bios/xe10/BANK4.BIN), so at the point
//     the ITF stalls the bank really is unprogrammed and the drive really is not present.
//   * 0x00 for both counters when nothing has been issued - the same capture.
//   * The field ORDER is not an internal detail: it is what tools/decode_telemetry.py
//     reads, so it is a contract between this module and the telemetry decoder, which is
//     why the order is pinned by construction below rather than by inspection.
//
// The port comment used to describe this byte as {DP,MOUNT,CH0,DRV4,state,BSY,DRQ} - a
// seven-field list for a six-field concatenation, with no DRV4 in the RTL. It is fixed
// in the module, and this bench is what stops the two drifting apart again.

`default_nettype none

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_DBG:
// The ATA's two diagnostic bytes, which the watchdog prints as the telemetry's A, K, X and Z fields and from which a MiSTer was diagnosed, are asserted for the first time: the state byte packs {device_present, mounted, channel_reg[0], xfer_state, BSY, DRQ} and reads 0xC0 with an image mounted and the bank at its power-up 0x00 - the disk's bank 0 since the layout was fixed (an A=0x40 is the same byte with the disk on bank 1) - selecting bank 0x01 drops device_present (0x60) and re-selecting bank 0x00 raises it again and so bit 7, the command word packs {aborts, last_cmd, commands, reason} and is zero on a card that has issued nothing, an accepted command increments only the command count while a rejected one increments both and carries its reason, and the IDENTIFY state is visible in the packed xfer_state field with DRQ set and BSY clear.

module tb_pc9821_ata_dbg;

  reg clk = 0;
  always #5 clk = ~clk;
  reg rst_n = 0;
  reg io_rd = 0, io_wr = 0;
  reg [15:0] io_addr = 0;
  reg [7:0] io_din = 0;
  wire [7:0] io_dout;
  reg mounted = 1, readonly = 0;
  reg [31:0] capacity = 32'd1000;
  wire block_read, block_write;
  wire [31:0] block_lba;
  reg block_done = 0, block_error = 0, block_buf_we = 0;
  reg [7:0] block_buf_addr = 0;
  reg [15:0] block_buf_data = 0;
  reg [7:0] block_rd_addr = 0;
  wire [15:0] block_rd_data;
  wire irq;
  wire [7:0] dbg_state;
  wire [31:0] dbg_cmd;

  // ==== DUT ====
  pc9821_ata dut (
      // The channel's slave (device 1): no image, so the master answers for DEV=1 as before.

      .clk(clk), .rst_n(rst_n),
      .io_rd(io_rd), .io_wr(io_wr), .io_addr(io_addr), .io_din(io_din),
      .io_dout(io_dout),
      .mounted(mounted), .readonly(readonly), .capacity(capacity),
      .block_read(block_read), .block_write(block_write), .block_lba(block_lba),
      .block_done(block_done), .block_error(block_error),
      .block_buf_we(block_buf_we), .block_buf_addr(block_buf_addr),
      .block_buf_data(block_buf_data),
      .block_rd_addr(block_rd_addr), .block_rd_data(block_rd_data),
      .irq(irq), .dbg_state(dbg_state), .dbg_cmd(dbg_cmd));

  integer errors = 0;

  // ==== STIMULUS ====

  task fail(input [8*110-1:0] message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  task write_byte(input [15:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr; io_din = data; io_wr = 1;
      @(posedge clk);
      @(negedge clk);
      io_wr = 0;
    end
  endtask

  // expect_state: the packing, written out field by field so the assertion states the
  // LAYOUT rather than the value. Each argument is one field in emission order, which is
  // what makes a reordered concatenation fail here instead of in a telemetry decode
  // months later.
  task expect_state(input dp, input mnt, input ch0, input [2:0] st,
                    input bsy, input drq, input [8*72-1:0] what);
    reg [7:0] want;
    begin
      want = {dp, mnt, ch0, st, bsy, drq};
      if (dbg_state !== want) begin
        $display("       wanted %02x, got %02x", want, dbg_state);
        fail({what, " -- dbg_state"});
      end
    end
  endtask

  task expect_cmd(input [7:0] aborts, input [7:0] last, input [7:0] cmds,
                  input [3:0] reason, input [8*72-1:0] what);
    reg [31:0] want;
    begin
      want = {aborts, last, cmds, 4'b0, reason};
      if (dbg_cmd !== want) begin
        $display("       wanted %08x, got %08x", want, dbg_cmd);
        fail({what, " -- dbg_cmd"});
      end
    end
  endtask

  reg [7:0] ignored;

  initial begin
    rst_n = 0;
    repeat (4) @(negedge clk);
    rst_n = 1;
    repeat (4) @(negedge clk);

    // ==== CHECKS ====

    // 1. THE OWNER'S OWN CAPTURE. The card reads A=0x40 with the image mounted and the
    //    IDE bank never selected, and that is not a defect: the Xe10's ITF does not write
    //    0x0432 anywhere in its 32 KiB bank, so the bank is genuinely unprogrammed when
    //    the ITF stalls. Two fields carry the meaning -- mounted=1 says the host has the
    //    image, device_present=0 says the guest has not selected the interface -- and
    //    they are deliberately different facts.
    //    SINCE THE LAYOUT WAS FIXED the disk is bank 0's master, so the
    //    unprogrammed bank 0x00 IS the disk's bank and the same card now reads 0xC0: the
    //    capture's 0x40 was the old layout, the disk on bank 1. Step 3 makes the 0x40-shaped
    //    case (mounted, not present) at bank 0x01, where it now lives.
    expect_state(1'b1, 1'b1, 1'b0, 3'd0, 1'b0, 1'b0,
                 "mounted, bank unprogrammed (0x00, the disk's bank)");
    if (dbg_state !== 8'hC0) begin
      $display("       wanted C0, got %02x", dbg_state);
      fail("that combination is 0xC0");
    end

    // 2. AND THE COUNTERS ARE ZERO, which is the same capture's K=0, X=0, Z=0. The
    //    module's own port comment says what R=0 with E=0 means: no block read was ever
    //    requested. Nothing has been issued yet, so nothing may have been counted.
    expect_cmd(8'd0, 8'd0, 8'd0, 4'd0, "nothing issued: the captured K=X=Z=0");
    if (dbg_cmd !== 32'd0) begin
      $display("       wanted 00000000, got %08x", dbg_cmd);
      fail("a card that issued no command reports a zero command word");
    end

    // 3. The bank select is what turns a mounted image into a present device. channel_reg[0]
    //    follows it because bit 0 IS the connection test: the disk answers at bank 0x00 and
    //    bank 0x01 (the CD's, or an empty connector) has no disk.
    write_byte(16'h0432, 8'h01);
    expect_state(1'b0, 1'b1, 1'b1, 3'd0, 1'b0, 1'b0,
                 "bank 0x01 selected: device_present clear (0x60)");
    if (dbg_state !== 8'h60) fail("mounted at the other bank is 0x60");
    write_byte(16'h0432, 8'h00);
    expect_state(1'b1, 1'b1, 1'b0, 3'd0, 1'b0, 1'b0,
                 "bank 0x00 selected: device_present rises as channel_reg[0] clears");

    // 4. An ACCEPTED command increments the command count and nothing else. FLUSH CACHE
    //    is used because it completes without a data phase, so the state stays X_IDLE and
    //    the state byte is unmoved -- which is itself the assertion that a completion
    //    does not disturb the packed state.
    write_byte(16'h064E, 8'hE7);
    expect_cmd(8'd0, 8'hE7, 8'd1, 4'd0, "an accepted command counts one command");
    expect_state(1'b1, 1'b1, 1'b0, 3'd0, 1'b0, 1'b0,
                 "an accepted command leaves the packed state idle");

    // 5. A REJECTED command increments BOTH counters and carries its reason. This is the
    //    distinction the byte exists for: commands=0,aborts=0 and commands>0,aborts>0 are
    //    the two cases a hardware log cannot otherwise tell apart. An unimplemented
    //    command is used: READ MULTIPLE (0xC4) now completes (see set_multiple).
    write_byte(16'h064E, 8'h9A);
    expect_cmd(8'd1, 8'h9A, 8'd2, 4'd8,
               "a rejected command counts an abort and records reason 8");

    // 6. THE FIELD ORDER, pinned by construction. IDENTIFY enters X_PIO_IDENT (2) with
    //    DRQ set and BSY clear, so the packed state must read 2 in bits 4..2 with the two
    //    flag bits below it. A swapped BSY/DRQ, a shifted state field or a reordered
    //    concatenation all fail here rather than in decode_telemetry.py.
    write_byte(16'h064E, 8'hEC);
    expect_state(1'b1, 1'b1, 1'b0, 3'd2, 1'b0, 1'b1,
                 "IDENTIFY: xfer_state=2 with DRQ set and BSY clear");
    expect_cmd(8'd1, 8'hEC, 8'd3, 4'd8, "IDENTIFY counts a command and no abort");

    // 7. A soft reset returns that data phase to idle. This is not decoration: IDENTIFY
    //    left the drive in X_PIO_IDENT with DRQ set, and every check below reads the
    //    packed state, so without this the byte would still be carrying the IDENTIFY
    //    phase and the mount checks would fail for a reason that has nothing to do with
    //    mounting. It also asserts something real: SRST with no block transfer in flight
    //    ends a data phase and publishes READY, rather than staying stuck in it.
    write_byte(16'h074C, 8'h04);
    write_byte(16'h074C, 8'h00);
    expect_state(1'b1, 1'b1, 1'b0, 3'd0, 1'b0, 1'b0,
                 "soft reset returns the IDENTIFY data phase to idle");

    // 8. A mount change is one of the few paths that rewrites status_reg, and the module
    //    documents that it must publish READY only when an image is present. The unmount
    //    is asserted through the same byte the watchdog prints, so the diagnostic and the
    //    task file cannot disagree about whether a device is there.
    mounted = 0;
    repeat (3) @(negedge clk);
    expect_state(1'b0, 1'b0, 1'b0, 3'd0, 1'b0, 1'b0,
                 "unmounted: device_present and mounted both clear");
    mounted = 1;
    repeat (3) @(negedge clk);
    expect_state(1'b1, 1'b1, 1'b0, 3'd0, 1'b0, 1'b0,
                 "remounted: the device returns with the image");

    // A status read acknowledges the pending IRQ; it must not disturb the byte.
    read_byte(16'h064E, ignored);
    expect_state(1'b1, 1'b1, 1'b0, 3'd0, 1'b0, 1'b0,
                 "a status read leaves the diagnostic byte alone");

    // The else is load-bearing: Verilator's $finish returns from the current process
    // rather than aborting it, so a bare trailing $fatal would also run after a pass.
  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_ATA_DBG: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_ATA_DBG: FAIL (%0d errors)", errors);
    end
  end

  task read_byte(input [15:0] addr, output [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr; io_rd = 1;
      #1 data = io_dout;
      @(posedge clk);
      @(negedge clk);
      io_rd = 0;
    end
  endtask

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_ATA_DBG: TIMEOUT");
  end

endmodule

`default_nettype wire
