// tb_pc9821_ata_regs — the ATA task-file read mux, ports only.
//
// Hardware contract: the guest reads every task-file register through its own
// port (0x0640..0x064E) and the alternate status through 0x074C. A wrong mux
// (a swapped pair, a byte-lane permutation, an error register returned on
// 0x0644) is invisible to a bench that inspects the RTL's internal registers,
// and exactly that class of bug -- a 16-bit data-read shift -- once slipped
// past all 17 unit checks. This bench reads every register back through its
// port and asserts the power-on values, with zero hierarchical references.
//
// This is a GUARD: it passes on the current RTL and pins the read path.
//
// Provenance:
//   * 0x064E / 0x074C = 0x50 is the drive's DRDY|DSC power-on status (ATA-1;
//     also what probes/PORTS.TXT reads with the block mapped).
//   * 0x0642 = 0x01 is the ATA-1 DIAGNOSTIC SIGNATURE: after EXECUTE DEVICE
//     DIAGNOSTIC and after a reset (including the post-SRST reset) device 0
//     reports 0x01 in the error register = "device 0 passed its self-test"
//     (ATA-1 X3T10/2008D, EXECUTE DEVICE DIAGNOSTIC / the reset device-0
//     signature; the value the PC-98 disk BIOS looks for after the device
//     power-on diagnostic). WAIVED DIVERGENCE (hierarchy note): NP2kai's
//     drvreset (cbus/ideio.c:356-374) does not model the signature - a named
//     gap in the primary reference, not grounds to assert the value bare.
//     Checked here through the port instead of the register.
//   * 0x0644/0x0646 = 0x01, 0x0648/0x064A = 0x00, 0x064C = 0xA0 are the
//     power-on task file (ATA-1 default device/head; the sector number/count
//     default to 1).
//   * 0x0640 = 0x00 while DRQ is clear (NP2kai ideio_r16 / qemu ide_data_readw); 0x0641 =
//     0xFF while DRQ is clear, the Xe10's own read in every task-file dump
//     (docs/probes/IDE.TXT:21 `0641=FF`, docs/probes/KIT1-XE10-IDEPROBE.TXT:21 `0641=FF`),
//     which outranks both references.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_REGS:
// Every ATA task-file register read back through its own port (0x0640..0x064E and the alternate status 0x074C), so a swapped pair or a lane permutation inside the ATA module is caught. The historical 16-bit data-read shift lived in pc9821_iobus.sv, which this bench does not build: that seam is guarded only by the integrated user-disk bench.


module tb_pc9821_ata_regs;

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
  reg [7:0] dstat, dlo, dlo2, dhi;   // data-port reads with DRQ set
  // ==== STIMULUS ====

  task write_byte(input [15:0] addr, input [7:0] data);
    begin
      @(negedge clk);
      io_addr = addr; io_din = data; io_wr = 1;
      @(posedge clk);
      @(negedge clk);
      io_wr = 0;
    end
  endtask

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

  task expect_port(input [15:0] addr, input [7:0] expected,
                   input [8*48-1:0] what);
    reg [7:0] got;
    begin
      read_byte(addr, got);
      if (got !== expected) begin
        $display("FAIL: %0s port %04x expected %02x got %02x @ %0t",
                 what, addr, expected, got, $time);
        errors = errors + 1;
      end
    end
  endtask

  // Write the port, then read the same port back: the mux must return what
  // the write path stored, byte for byte.
  task expect_writeback(input [15:0] addr, input [7:0] value,
                        input [8*48-1:0] what);
    begin
      write_byte(addr, value);
      expect_port(addr, value, what);
    end
  endtask
  // ==== CHECKS ====

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);

    // Select the bank the interface is on, the way the ROM does, then read the
    // whole task file. 0x0432 is a bank select, not a map gate: the task file
    // answers at the hard disk's bank (0x00, bank 0's master) and floats at a
    // bank with no interface (0x01 here: the CD's bank, which this bench does not build).
    write_byte(16'h0432, 8'h00);

    // 0x074C is the alternate status: the guest polls it instead of 0x64E so
    // the read does not clear the interrupt. It had no port read anywhere.
    expect_port(16'h074C, 8'h50, "0x74C alternate status");
    expect_port(16'h064E, 8'h50, "0x64E status");

    // The four registers with no port read anywhere before this bench.
    expect_port(16'h0642, 8'h01, "0x642 error (ATA-1 device-0 diagnostic signature)");
    expect_port(16'h0644, 8'h01, "0x644 sector count");
    expect_port(16'h064C, 8'hA0, "0x64C drive/head (power-on)");

    // The remaining task file.
    expect_port(16'h0646, 8'h01, "0x646 sector number");
    expect_port(16'h0648, 8'h00, "0x648 cylinder low");
    expect_port(16'h064A, 8'h00, "0x64A cylinder high");

    // Data register with DRQ clear: 0x0640 follows NP2kai ideio_r16 and qemu ide_data_readw
    // (0 when a drive is present but DRQ is clear); 0x0641 is the Xe10's measured 0xFF
    // (docs/probes/IDE.TXT:21 `0641=FF`; the capture outranks the references).
    expect_port(16'h0640, 8'h00, "0x640 data, DRQ clear");
    expect_port(16'h0641, 8'hFF, "0x641 data high, DRQ clear (Xe10 capture)");

    // Write each writable register and read it back through the port, so a
    // swapped or ignored decode fails here rather than silently.
    expect_writeback(16'h0644, 8'h07, "0x644 sector count writeback");
    expect_writeback(16'h0646, 8'h02, "0x646 sector number writeback");
    expect_writeback(16'h0648, 8'h34, "0x648 cylinder low writeback");
    expect_writeback(16'h064A, 8'h12, "0x64A cylinder high writeback");
    expect_writeback(16'h064C, 8'hB0, "0x64C drive/head writeback");

    // 0xB0 selects device 1, which is ABSENT: ALTERNATE STATUS reads 0x00 (ATA-3 r6 s.9.5.1;
    // the Linux/98 IDE driver's pc98_ide.c relies on it), and re-selecting device 0 reads the
    // drive's own status again.
    expect_port(16'h074C, 8'h00, "0x74C alternate status with absent device 1 selected");
    expect_writeback(16'h064C, 8'hA0, "0x64C drive/head writeback (device 0)");
    expect_port(16'h074C, 8'h50, "0x74C alternate status after re-selecting device 0");

    // ---------------------------------------------------------------
    // The data port WITH DRQ SET, which nothing read through a port before. This is
    // the contract the disk once broke on: 0x640 returns the low byte of the current
    // word and must NOT advance, 0x641 returns the high byte and advances to the next
    // word. A one-read shift -- the defect that made every 16-bit ATA read return the
    // next word's high byte -- shows up here immediately.
    // ---------------------------------------------------------------
    write_byte(16'h064C, 8'hA0);       // drive/head: master, LBA
    write_byte(16'h064E, 8'hEC);       // IDENTIFY DEVICE
    repeat (60) @(posedge clk);        // let the capacity-derived cylinder count settle
    read_byte(16'h064E, dstat);
    if ((dstat & 8'h08) === 8'h00) begin
      $display("FAIL: 0x64E shows no DRQ after IDENTIFY (status %02x)", dstat);
      errors = errors + 1;
    end
    read_byte(16'h0640, dlo);
    read_byte(16'h0640, dlo2);
    if (dlo !== dlo2) begin
      $display("FAIL: 0x640 advanced the word pointer (%02x then %02x)", dlo, dlo2);
      errors = errors + 1;
    end
    read_byte(16'h0641, dhi);
    if ({dhi, dlo} !== 16'h044A) begin
      $display("FAIL: IDENTIFY word 0 read through the ports = %04x, want 044A", {dhi, dlo});
      errors = errors + 1;
    end
    // 0x641 advanced: the next word's low byte is a different word.
    read_byte(16'h0640, dlo2);
    read_byte(16'h0641, dhi);
    if ({dhi, dlo2} === 16'h044A) begin
      $display("FAIL: reading 0x640/0x641 twice returned the same word (pointer did not advance)");
      errors = errors + 1;
    end
  // ==== VERDICT ====

    if (errors == 0) begin
      $display("TB_PC9821_ATA_REGS: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_ATA_REGS: FAIL (%0d errors)", errors);
    end
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_ATA_REGS: TIMEOUT");
  end

endmodule
