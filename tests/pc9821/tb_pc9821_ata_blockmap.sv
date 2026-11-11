// tb_pc9821_ata_blockmap - port 0x0432, the IDE bank select, ports only.
//
// The contract, and where it comes from:
//
//   * 0x0432 is a latched bank select, not a map gate. The authentic IDE option
//     ROM re-selects its bank at *every* drive access by writing
//     `(slot & 0x0E) >> 1` -- values 0x00..0x03, bit 7 always clear
//     (BANK3@0x0D0D: `mov al,[bp+0] / and al,0x0E / shr al,1 / mov dx,0x0432 /
//     out dx,al`), and its ISR writes the per-drive bank byte before reading
//     0x0642/0x064E (BANK3@0x1A17-0x1A24). A bit-7 gate is therefore wrong in
//     both directions: it floated banks the machine answers in, and it answered
//     a bank the machine floats in.
//   * A write with bit 7 SET is a no-op. The ROM's three 0x80 writes are
//     save/restore brackets (BANK3 file offsets 0x0143, 0x0290, 0x1A0C): each
//     writes 0x80, READS THE REGISTER BACK, keeps that value in its work area
//     (es:0x2074/0x2076/0x2075), writes the real bank, and restores the saved
//     value afterwards. That bracket only works if the 0x80 write does not take
//     effect -- under a latching model the read-back is 0x80 and the restore
//     re-writes 0x80, leaving the interface DISCONNECTED for the whole of the
//     ROM's data phase. NP2kai (`ideio_o430`: `if (!(dat & 0x80))`) and QEMU
//     (`pc98_ide_chsel_write`: "A write with bit 7 set is a no-op guard") both
//     say so explicitly.
//   * Which bank is CONNECTED is bit 0 -- the channel select -- not a byte
//     comparison. QEMU keeps the stored byte masked and selects the bus with
//     `cur_bus = &bus[val & 1]` (hw/ide/pc98-ide.c:120-137, a lead); NP2kai's
//     task file follows `(bank & 0x7f) < 2` (cbus/ideio.c:42). Byte equality
//     made a write of `0x09` -- bank|bit 3, which QEMU defines as the
//     DWORD-transfer enable -- drop the whole task file on the floor, and a
//     DWORD PIO driver would have had every sector silently discarded.
//   * The machine answers at bank 0x01 and floats at 0x00, measured:
//       - 0x0432 = 0x01 -> 0x064E = 0x50, DRDY|DSC, and
//         0640=00 0642=00 0644=00 0646=02 0648=BC 064A=0E 064C=A0 074C=50
//         (the machine's probe results, "ATA and the task file");
//       - 0x0432 = 0x00 -> the task file floats: 0x0642-0x064E at 0x0E, the
//         odd partner of each register at 0xFF, and 0x74C/0x74E at 0x0F -- read
//         at the DOS prompt with the register untouched in probes/JOY.TXT and
//         probes/WIN.TXT. 0x0640 reads 0xFF in the fresh ATA.TXT (confirmed twice); the older captures had 0x0E there. The ROM's own
//         probe ends with `out 0x432,0` (BANK3@0x87D4), which is why DOS leaves
//         it at 0x00.
//   * Bank 0 is the slot pair with no interface on this machine: the ROM's rule
//     maps slots 0/1 to bank 0, 2/3 to 1, 4/5 to 2, 6/7 to 3, and the ITF's own
//     candidate-drive bitmap selects slot 2 alone -- it computes 0x04 from the
//     0xF0 strap byte (0xA9: `shr al,5 / and al,1 / shr ah,4 / and ah,4 /
//     or al,ah / xor al,5` at BANK4@0x19D4) and stores it at 0xF8E90, which is
//     what the ROM walks asking which slots to probe (BANK3@0x0879E). Slot 2 is
//     bank 1, which is exactly the bank the machine answers at. So the modelled
//     interface answers at the channel bit 0 = 1, the bank the firmware puts
//     its drive in.
//   * Consequences of the old bit-7 gate: the ROM's pre-command DRDY poll read
//     the 0x0E float on its first iteration, the dispatcher at BANK3@0x905F
//     skipped the command handler, and ZERO commands reached the drive. The
//     gate's justification was never the machine: the one disk-tier log that
//     reached the IPL was built with the FREE BIOS
//     (firmware/freebios/pc98ide.bin), which read-modify-writes 0x0432 and so
//     satisfied bit 7; commit ad01e35 deleted that firmware, leaving the gate
//     with no evidence at all.
//   * THE CORE'S LAYOUT IS FIXED, and it is NOT the probed machine's: the
//     hard disk is always bank 0's master and bank 1 is the CD-ROM's (or empty), the stock
//     CD-equipped Xe10's layout and NP2kai's default (HDD unit 0, CD unit 2). The probed Xe10
//     answers at bank 1 only because its CF card sits in the CD connector. So this bench takes
//     the machine's VALUES (the live-bank answers, the empty-bank float) and puts them at the
//     core's banks: the disk answers at channel bit 0 CLEAR and the float is at bit 0 set. The
//     port 0xF0 strap follows the same layout (pc9821_iobus), so the ITF's bitmap above then
//     selects slot 0 - bank 0 - for the disk.
//   * Banks 0x02 and 0x03 are UNMEASURED. Under the channel bit they are the two
//     channels again: 0x02 (bit 0 clear) answers with the disk and 0x03 (bit 0
//     set) floats. The probe that settles them
//     drives 0x0432 over {0x00, 0x01, 0x02, 0x03, 0x2A, 0x80} and prints the
//     task file for each (hwprobe open question 1).
//
// What this bench asserts, all of it through ports:
//   1. 0x0432 latches the byte it is given and reads it back; a write with bit 7
//      set is ignored and the previous value stays.
//   2. At a bank whose channel bit is set (0x01, 0x03): 0x064E reads the
//      measured 0x0E float, 0x074C the measured 0x0F, 0x0640 and its odd partner
//      0x0641 both read 0xFF. At a bank whose channel bit is clear
//      (0x00, and 0x02/0x08 by the same rule): 0x064E/0x074C report DRDY|DSC and
//      0x0640 follows the ATA data-register rule with DRQ clear.
//   3. A task-file write at a floating bank does not reach the drive, and the
//      same write at a connected bank does (the register is a window on the
//      interface, in both directions).
//   4. A command issued after the ROM's bank select reaches the drive: it
//      completes, the task file the drive accepted is readable, 0x0433 reports
//      bank 0's pending interrupt (01, the Xe10's IRQ433 row), and the
//      status read clears the interrupt and that bit with it.
//   5. The ROM's own ISR bracket (BANK3 file offset 0x1A0C), in order: the 0x80
//      park write leaves the register alone, the drive's bank byte connects the
//      interface, ERROR/STATUS are readable inside the bracket, and the restored
//      value leaves the interface connected -- which is the state the ROM's data
//      phase then runs in.
//
// Provenance: the mapped values are the machine's own ATA captures
// (the machine's probe results and probes/{JOY,WIN}.TXT), the drive status
// 0x50 is the ATA-1 DRDY|DSC power-on value the drive itself defines, and the
// bracket is read off the machine's own IDE option ROM.

`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// TB_PC9821_ATA_BLOCKMAP:
// The 0x0432 IDE bank select as the machine has it: a write with bit 7 set is a no-op (so the ROM's own save-and-restore bracket leaves the interface connected), which channel is connected is decided by bit 0 rather than a byte comparison, the task file answers at the hard disk's channel - bit 0 clear, bank 0's master, the fixed layout (the stock Xe10's and NP2kai's unit 0) - and floats at the other (the values measured on the probed Xe10, whose empty bank was 0x00 and live bank 0x01: an empty bank leaves every task-file register at 0x0E with 0x74C/0x74E at 0x0F and their odd partners at 0xFF; the live bank answers 0x064E = 0x50 with 0x074C = 0x50 and 0x074E = 0x00), a task-file write follows the same window, and a command issued after the bank select reaches the drive.


module tb_pc9821_ata_blockmap;

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

  task fail(input [8*96-1:0] message);
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

  // Assert one port reads an exact expected byte; the message names the port
  // and both values, and the caller names the contract under test.
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

  // The ROM's own sequence at the bank its drive is on: select the bank, poll
  // DRDY, and require the drive to answer. The live read-backs are the machine's
  // at ITS live bank (the machine's probe results, "ATA and the task file", with 0x0432 = 0x01:
  // 0640=00 0642=00 0644=00 0646=02 0648=BC 064A=0E 064C=A0 064E=50 074C=50
  // 074E=00).
  task expect_bank_answers(input [8*40-1:0] what);
    integer i;
    begin
      write_byte(16'h0432, 8'h00);
      expect_port(16'h064E, 8'h50, what);
      expect_port(16'h074C, 8'h50, "0x74C mirrors the live status");
      // 0x74E does NOT mirror it with the bank mapped: 0x00 there, 0x50 on
      // 0x74C. The synthesised {2'b11,~head,2'b00}|unit form read 0xD6.
      expect_port(16'h074E, 8'h00, "0x74E reads 0x00 with the bank mapped");
      // The live bank's SECOND-CHANNEL task file (0x740-0x74A): the machine reads 0x00 at
      // every even register and 0xFF at its odd partner, in all three of its own captures
      // (docs/probes/IDE.TXT, "task file with 0432=01 (live bank)":
      // `0740=00 0741=FF 0742=00 0744=00 0746=00 0748=00 074A=00`). With the bank mapped
      // there was no arm for these and they fell through to io_dout's initial 0xFF (the read-back
      // weak spot AGENTS.md names).
      for (i = 0; i < 6; i = i + 1)
        expect_port(16'h0740 + (i * 2), 8'h00, "0x740-0x74A even: 00, live bank");
      expect_port(16'h0741, 8'hFF, "its odd partner stays 0xFF");
      // The data port follows the primary reference (NP2kai ideio_r16 / qemu
      // ide_data_readw): 0 with a drive present and DRQ clear, not the ATA 0xFF.
      expect_port(16'h0640, 8'h00, "0x640 data port, DRQ clear");
    end
  endtask

  // The measured float of a bank with no interface behind it, byte for byte
  // from probes/R10.TXT ("ATA BLOCK as left by POST/DOS", identical in all four
  // snapshots, with 0x0432 = 0x00): every task-file register at 0x0E with its
  // odd partner at 0xFF, and the 0x74C/0x74E pair at 0x0F.
  task expect_bank_floats(input [7:0] bank, input [8*40-1:0] what);
    integer i;
    begin
      write_byte(16'h0432, bank);
      expect_port(16'h064E, 8'h0E, what);
      for (i = 0; i < 7; i = i + 1) begin
        expect_port(16'h0642 + (i * 2), 8'h0E, "every task-file register floats");
        expect_port(16'h0643 + (i * 2), 8'hFF, "its odd partner floats at 0xFF");
      end
      expect_port(16'h074C, 8'h0F, "0x74C floats at 0x0F");
      expect_port(16'h074E, 8'h0F, "0x74E floats at 0x0F like 0x74C");
      // The second channel's task file (0x740-0x74A) is the same measured float
      //: the machine reads 0x0F at each even register and 0xFF at each
      // odd partner (probes/PORTS.TXT `0740 0F 0742 0F 0744 0F 0746 0F 0748 0F
      // 074A 0F`, with 0741/0743/.../074B at 0xFF). Undecoded before this
      // change, so every one of them answered open bus 0xFF.
      for (i = 0; i < 6; i = i + 1) begin
        expect_port(16'h0740 + (i * 2), 8'h0F, "second-channel task file floats at 0x0F");
        expect_port(16'h0741 + (i * 2), 8'hFF, "its odd partner floats at 0xFF");
      end
      // Called with 0x01 and 0x03, which both read back 01 on the machine
      // (docs/probes/KIT1-XE10-IDE1.TXT:6 `w=01 r432=01`, :10 `w=03 r432=01`).
      expect_port(16'h0432, {7'd0, bank[0]}, "0x0432 still reads back the bank");
    end
  endtask
  // ==== CHECKS ====

  integer bank;
  reg [7:0] value;
  reg [7:0] saved_bank;

  initial begin
    repeat (4) @(posedge clk);
    @(negedge clk);
    rst_n = 1;
    repeat (4) @(posedge clk);

    // 1. 0x0432 latches the byte it is given and reads it back. The power-on
    //    value is 0x00, which is the bank the DOS-prompt capture shows the
    //    register left at -- the disk's bank in this layout. A write with bit 7 set
    //    is ignored, which is the whole point of the ROM's bracket (step 7).
    expect_port(16'h0432, 8'h00, "0x0432 reset readback");

    // 2. A bank whose channel bit is set floats, at the values the machine
    //    showed at ITS empty bank (probes/JOY.TXT, probes/WIN.TXT at the DOS prompt).
    expect_bank_floats(8'h01, "bank 0x01 floats (R10.TXT values)");

    // 3. Banks 0x02/0x03 read a task file of their own on the machine (status 00 / 04,
    //    docs/probes/KIT1-XE10-IDE1.TXT:8,10), which is not modelled; they differ under
    //    the channel rule: 0x03 has bit 0 set (the empty channel) and 0x02 has
    //    bit 0 clear, i.e. the disk's channel. Byte equality
    //    floated both. QEMU models the channel select as `val & 1` and masks
    //    only the stored byte; NP2kai's task file follows `(bank & 0x7f) < 2`.
    expect_bank_floats(8'h03, "bank 0x03 has no disk (bit 0 set)");
    write_byte(16'h0432, 8'h02);
    expect_port(16'h064E, 8'h50, "bank 0x02 is the same channel as 0x00");
    // The read-back drops bit 1 without bit 5 (KIT1-XE10-IDE1.TXT:8 `w=02 r432=00`).
    expect_port(16'h0432, 8'h00, "0x0432 <- 02 reads back 00");

    // 4. A task-file write at a floating bank does not reach the drive; the
    //    same write at 0x00 does (step 6). The register is a window on the
    //    interface in both directions, which is what the float means.
    write_byte(16'h0432, 8'h01);
    write_byte(16'h0644, 8'h03);
    write_byte(16'h0432, 8'h00);
    expect_port(16'h0644, 8'h01, "a floating-bank write reached nothing");

    // 0x0640 is consume-on-read, so the machine's own probe does not sample it
    // (R10.TXT marks it "--", with 0x0641). The fresh ATA.TXT reads it 0xFF
    // with the bank floating -- the second fresh confirmation --
    // which is also the ATA data register's own rule while DRQ is clear. Reading
    // it is safe in this bench because no transfer is in flight.
    write_byte(16'h0432, 8'h01);
    expect_port(16'h0640, 8'hFF, "0x0640 floats at 0xFF");

    // 5. The bank the machine answers at: the ROM's own sequence. The readback
    //    carries content in the low bits too, so a decoder that only stored
    //    bit 7 would be caught here.
    expect_bank_answers("0x64E status at the disk's bank");

    // 5b. A DWORD-capable driver writes bank|0x08: QEMU's bit 3 is the
    //     DWORD-transfer enable and its channel select is still `val & 1`, so the
    //     task file has to stay connected. Under byte equality this dropped the
    //     whole task file and every sector of a DWORD PIO transfer was silently
    //     discarded while the DRQ poll read the float's bit 3 and reported
    //     success.
    write_byte(16'h0432, 8'h08);
    expect_port(16'h064E, 8'h50, "bank 0x08 is still channel 0 (bit 3 is not a bank bit)");
    // Bit 3 never reads back (KIT1-XE10-IDE1.TXT:12 `w=2A r432=22`).
    expect_port(16'h0432, 8'h00, "0x0432 <- 08 reads back 00 (bit 3 never)");
    expect_bank_answers("the disk's bank again after 0x08");

    // 6. A command issued after the bank select reaches the drive. This is the
    //    case the bit-7 gate broke: the task file floated, so the DRDY poll
    //    above failed and no command was ever written.
    write_byte(16'h0644, 8'h03);          // sector count: the drive must keep it
    expect_port(16'h0644, 8'h03, "0x644 sector count write reached the drive");
    expect_port(16'h064E, 8'h50, "status before the command");
    write_byte(16'h064E, 8'h10);          // RECALIBRATE
    // 0x0433 is the interrupt-pending port: bit 0 is bank 0's interrupt, 01 while the
    // completion pends and 00 once the status read acknowledges it
    // (docs/probes/KIT1-XE10-IDE1.TXT:18, the IRQ433 row `00 10 01 12 01 50 50 00`).
    expect_port(16'h0433, 8'h01, "0x0433 reports bank 0's pending interrupt");
    expect_port(16'h064E, 8'h50, "RECALIBRATE completed READY|DSC");
    expect_port(16'h0642, 8'h00, "0x642 ERROR clear after a completed command");
    expect_port(16'h0433, 8'h00, "0x0433 clears with the status ack");
    // 7. The ROM's own ISR bracket, in its own order (BANK3 file offset 0x1A0C):
    //      `mov dx,0x432 / mov al,0x80 / out dx,al / in al,dx / mov es:0x2075,al`
    //    then the drive's bank byte, then the ERROR/STATUS reads, then the ack to
    //    0x0433, then `mov al,es:0x2075 / out dx,al`. The read-back saved by the
    //    bracket is the value the interface is addressed with for the rest of the
    //    command, and that is where the 512-byte data phase runs -- so the 0x80
    //    write MUST NOT take effect. Under a latching model the save is 0x80 and
    //    the restore re-writes 0x80, leaving the task file floating: the ROM's
    //    next `rep insw` from 0x0640 (BANK3@0x9917) then reads 0x0E/0xFF instead
    //    of IPL data, which is exactly the `reached IPL = 0` symptom.
    write_byte(16'h0432, 8'h00);          // the handler's bank select
    expect_port(16'h064E, 8'h50, "task file live before the bracket");
    write_byte(16'h0432, 8'h80);          // the ISR's park write
    expect_port(16'h0432, 8'h00, "the 0x80 park write is a no-op: the readback is unchanged");
    expect_port(16'h064E, 8'h50, "the task file stays connected through the park write");
    // The value the ROM saves is the read-back of the 0x80 write, and it restores
    // exactly that. Save it here the way the ISR does.
    read_byte(16'h0432, saved_bank);
    if (saved_bank !== 8'h00) fail("0x0432 readback of the park write (the ISR's es:0x2075)");
    write_byte(16'h0432, 8'h00);          // es:0x2077, the drive's own bank byte
    expect_port(16'h0642, 8'h00, "ERROR readable inside the bracket");
    expect_port(16'h064E, 8'h50, "STATUS readable inside the bracket");
    write_byte(16'h0433, 8'h01);          // the ISR's acknowledge
    write_byte(16'h0432, saved_bank);     // the restore of es:0x2075
    expect_port(16'h0432, 8'h00, "0x0432 after the bracket restore");
    expect_port(16'h064E, 8'h50, "task file live after the bracket restore");

    // The else is load-bearing: Verilator's $finish returns from the
    // current process rather than aborting it, so a bare trailing $fatal
    // would also run after a pass.
  // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_ATA_BLOCKMAP: PASS");
      $finish;
    end else begin
      $fatal(1, "TB_PC9821_ATA_BLOCKMAP: FAIL (%0d errors)", errors);
    end
  end

  initial begin
    #2_000_000;
    $fatal(1, "TB_PC9821_ATA_BLOCKMAP: TIMEOUT");
  end

endmodule
