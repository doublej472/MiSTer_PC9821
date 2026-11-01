// SPDX-License-Identifier: MIT
// Copyright (c) 2026 Kevin Coleman. From https://github.com/birdybro/SDRAMsim_MiSTer.
// MIT licence text: NOTICE, part 6.

`timescale 1ns/1ps

// =============================================================================
// XSDS v3.0 128 MByte SDRAM module simulation model
// =============================================================================
// Models the XSDS RAM module addon board for the MiSTer FPGA platform — a
// 40-pin SDRAM module containing two AS4C32M16SB-6TIN chips on a shared bus.
//
// Module capacity:
//   128 MBytes = 1024 Mbits
//
// Physical memory:
//   2 x AS4C32M16SB-6TIN chips
//   each chip = 512 Mbits = 64 MBytes
//   Per chip: 4 banks x 8192 rows x 1024 columns x 16 bits
//
// Connector signals (matches XSDS v3.0 schematic, 40-pin header P1):
//   Clk, Cs1_n, Ras_n, Cas_n, We_n, Ba[1:0], Addr[12:0], Dq[15:0]
//
// Hidden by the board (NOT on the connector):
//   - CKE: tied to VCC permanently. No power-down / self-refresh / clock-
//     suspend possible through this connector. Hardwired to 1'b1 internally.
//   - DQML / DQMH: tied to Addr[11] / Addr[12] at the chip pins. The wrapper
//     extracts those bits and drives the chip-level Ldqm / Udqm internally.
//   - CS2: an internal-only net generated as ~Cs1_n via an LVC1G04 inverter
//     (U3 on the schematic). Cs1_n IS the high chip-select bit.
//
// Addressing the full 128 MB:
//   Cs1_n=0 selects chip 0 (lower 64 MB); chip 1 sees CS=1 and ignores cmds.
//   Cs1_n=1 selects chip 1 (upper 64 MB); chip 0 sees CS=1 and ignores cmds.
//   The hardware can never deselect both chips. Idle cycles must drive
//   {Ras_n, Cas_n, We_n} = 3'b111 (NOP) regardless of Cs1_n.
//
// Refresh:
//   Each chip independently requires 8192 AUTO REFRESH commands per 64 ms.
//   The controller must issue refreshes against both Cs1_n=0 and Cs1_n=1 to
//   keep both chips alive.
//
// See CONTROLLER_GUIDE.md for protocol/timing rules a controller must follow.
//
// -----------------------------------------------------------------------------
// LOCAL FIXES (PC-9821 core, 2026-10-10). This file is the community SDRAMsim model
// (a `diff` against the pristine upstream SDRAMsim copy must show exactly the blocks marked
// `LOCAL FIX` here and nothing else). All three concern
// READ data timing; none touches a protocol or AC-timing CHECK. They are pinned by
// tests/pc9821/tb_pc9821_xsds_readpipe.sv and make tb_pc9821_sdram_strict meaningful.
//   1. READs are pipelined. A real SDR SDRAM keeps an earlier READ's data in flight when a
//      later READ is issued (each READ's data appears CL clocks after its OWN command; a new
//      READ only replaces a burst that is already outputting, from its own CL slot on). The
//      upstream stop_burst() in do_read() restarted one latency counter per READ, so of two
//      back-to-back BL=1 READs the first word was lost. -> read_pipe, mature_read_pipe().
//   2. Read data is launched on clock edge CL-1 after the READ's edge (captured on edge CL),
//      not on edge CL; DQM's 2-clock read latency counts to that capture edge.
//   3. A burst that runs out no longer forces dq_oe low in the time step of the capture edge of
//      its previous beat (a race that lost words of any BL>=2 read); the idle branch releases
//      the bus tHZ later, as for a single read.
// LOCAL FIXES 4-7 (PC-9821 core). They add CHECKS the upstream model lacks, against the
// AS4C32M16SB datasheet (Alliance, Rev 1.4, Table 16; the PDF is not vendored):
//   4. GRADE: the wrapper selects the Table 16 column, -6 (the upstream default, the parts the
//      XSDS board carries) or -7 (the slowest part of the supported set, docs/sdram.md), for
//      both chips: tRC/tRFC 60/63, tRCD/tRP 18/21, tRRD/tMRD 12/14, tWR 12/14, tRAS 42, tCK at
//      CL3 6/7, tCH/tCL 2/2.5 ns.
//   5. tMRD from a MODE REGISTER SET to ANY following command (upstream checked MRS-to-MRS).
//   6. tRAS for both auto-precharge forms. The datasheet promises no tRAS lockout, so the
//      implied precharge begins where its command descriptions put it - one clock (the burst
//      length) after a READ with auto-precharge, tWR after a WRITE with auto-precharge's data -
//      and that point must be tRAS after the ACT (upstream deferred the precharge instead).
//   7. tRP before AUTO REFRESH and MODE REGISTER SET: every bank's precharge must have completed
//      (upstream checked only that no bank was open).
// -----------------------------------------------------------------------------

// Simulation-only. Not synthesizable.
// =============================================================================

module xsds_128mbyte_sdram_model #(
    parameter bit DEBUG               = 1'b0,
    parameter bit STRICT_TIMING       = 1'b1,
    parameter bit WARN_TREFI          = 1'b1,
    parameter bit INIT_UNWRITTEN_TO_X = 1'b1,
    parameter int GRADE               = 6        // LOCAL FIX 4: the Table 16 column, 6 or 7
) (
    input  wire        Clk,

    // Connector pin P1.33. Acts as the high chip-select bit:
    //   Cs1_n=0 -> chip 0 (lower 64 MB) selected, chip 1 deselected.
    //   Cs1_n=1 -> chip 0 deselected, chip 1 (upper 64 MB) selected.
    // The board has no separate ChipSel; the on-board LVC1G04 inverter (U3)
    // drives chip 1's CS# from ~Cs1_n. Both-chips-deselected is impossible.
    input  wire        Cs1_n,

    input  wire        Ras_n,
    input  wire        Cas_n,
    input  wire        We_n,

    input  wire [1:0]  Ba,
    input  wire [12:0] Addr,

    inout  wire [15:0] Dq
);

    // LOCAL FIX 4: the speed grade (AS4C32M16SB datasheet Rev 1.4, Table 16, ns).
    localparam realtime G_TRC  = (GRADE == 7) ? 63.0 : 60.0;   // tRC = tRFC
    localparam realtime G_TRCD = (GRADE == 7) ? 21.0 : 18.0;   // tRCD = tRP
    localparam realtime G_TRRD = (GRADE == 7) ? 14.0 : 12.0;   // tRRD = tMRD = tWR
    localparam realtime G_TCK3 = (GRADE == 7) ?  7.0 :  6.0;   // tCK at CL3
    localparam realtime G_TCHL = (GRADE == 7) ?  2.5 :  2.0;   // tCH = tCL
    initial if ((GRADE != 6) && (GRADE != 7))
        $fatal(1, "xsds_128mbyte_sdram_model: GRADE %0d: Table 16 has -6 and -7 only", GRADE);

    // CKE is tied to VCC on the XSDS board.
    wire chip_cke = 1'b1;

    // DQML / DQMH are tied to Addr[11] / Addr[12] at the chip pins.
    wire chip_ldqm = Addr[11];
    wire chip_udqm = Addr[12];

    // Chip 0 takes Cs1_n directly; chip 1 takes the inverted Cs1_n,
    // mirroring the LVC1G04 inverter (U3) on the board.
    wire chip0_cs_n =  Cs1_n;
    wire chip1_cs_n = ~Cs1_n;

    as4c32m16sb_6tin_chip_model #(
        .CHIP_NAME           ("XSDS_CHIP0_AS4C32M16SB"),
        .DEBUG               (DEBUG),
        .STRICT_TIMING       (STRICT_TIMING),
        .WARN_TREFI          (WARN_TREFI),
        .INIT_UNWRITTEN_TO_X (INIT_UNWRITTEN_TO_X),
        // LOCAL FIX 4: the speed grade's Table 16 column
        .tRC_MIN             (G_TRC),
        .tRFC_MIN            (G_TRC),
        .tRCD_MIN            (G_TRCD),
        .tRP_MIN             (G_TRCD),
        .tRRD_MIN            (G_TRRD),
        .tMRD_MIN            (G_TRRD),
        .tWR_MIN             (G_TRRD),
        .tCK_CL3_MIN         (G_TCK3),
        .tCH_MIN             (G_TCHL),
        .tCL_MIN             (G_TCHL)
    ) u_chip0 (
        .Clk   (Clk),
        .Cke   (chip_cke),
        .Cs_n  (chip0_cs_n),
        .Ras_n (Ras_n),
        .Cas_n (Cas_n),
        .We_n  (We_n),
        .Ba    (Ba),
        .Addr  (Addr),
        .Ldqm  (chip_ldqm),
        .Udqm  (chip_udqm),
        .Dq    (Dq)
    );

    as4c32m16sb_6tin_chip_model #(
        .CHIP_NAME           ("XSDS_CHIP1_AS4C32M16SB"),
        .DEBUG               (DEBUG),
        .STRICT_TIMING       (STRICT_TIMING),
        .WARN_TREFI          (WARN_TREFI),
        .INIT_UNWRITTEN_TO_X (INIT_UNWRITTEN_TO_X),
        // LOCAL FIX 4: the speed grade's Table 16 column
        .tRC_MIN             (G_TRC),
        .tRFC_MIN            (G_TRC),
        .tRCD_MIN            (G_TRCD),
        .tRP_MIN             (G_TRCD),
        .tRRD_MIN            (G_TRRD),
        .tMRD_MIN            (G_TRRD),
        .tWR_MIN             (G_TRRD),
        .tCK_CL3_MIN         (G_TCK3),
        .tCH_MIN             (G_TCHL),
        .tCL_MIN             (G_TCHL)
    ) u_chip1 (
        .Clk   (Clk),
        .Cke   (chip_cke),
        .Cs_n  (chip1_cs_n),
        .Ras_n (Ras_n),
        .Cas_n (Cas_n),
        .We_n  (We_n),
        .Ba    (Ba),
        .Addr  (Addr),
        .Ldqm  (chip_ldqm),
        .Udqm  (chip_udqm),
        .Dq    (Dq)
    );

    // Refresh tracking is per-chip because each chip only sees commands when
    // Cs1_n routes to it. A testbench that only refreshes one Cs1_n state will
    // get a violation from the other chip, not from the wrapper — call this
    // at end-of-test to print both chips' refresh state side by side.
    task automatic module_refresh_status();
        begin
            u_chip0.report_refresh_status();
            u_chip1.report_refresh_status();
        end
    endtask

    // Dump/restore the full 128 MB module to a pair of files:
    //   "<base>.chip0" — lower 64 MB
    //   "<base>.chip1" — upper 64 MB
    // Each file is the sparse-key format produced by the chip-level
    // dump_memory task and consumed by load_memory.
    task automatic module_dump_memory(input string base_filename);
        begin
            u_chip0.dump_memory({base_filename, ".chip0"});
            u_chip1.dump_memory({base_filename, ".chip1"});
        end
    endtask

    task automatic module_load_memory(input string base_filename);
        begin
            u_chip0.load_memory({base_filename, ".chip0"});
            u_chip1.load_memory({base_filename, ".chip1"});
        end
    endtask

    // Load a contiguous ROM image into the 128 MB module starting at
    // byte address `byte_base`. One 16-bit hex value per line; the file
    // may straddle the 64 MB chip boundary at byte 0x0400_0000 (word
    // index 2^25) — words on each side are dispatched to the matching
    // chip's poke task.
    // Aggregate violation counts across both chips. issue_error / issue_warn
    // in the chip model bump these on every violation regardless of whether
    // STRICT_TIMING downgrades $error to $warning, so a testbench can do
    //   if (dut.module_error_count() != 0) $fatal;
    // at end-of-test without parsing simulator output.
    function automatic int unsigned module_error_count();
        module_error_count = u_chip0.error_count + u_chip1.error_count;
    endfunction

    function automatic int unsigned module_warning_count();
        module_warning_count = u_chip0.warning_count + u_chip1.warning_count;
    endfunction

    task automatic module_dump_state();
        begin
            u_chip0.dump_state();
            u_chip1.dump_state();
        end
    endtask

    task automatic module_load_rom_hex(
        input string             filename,
        input longint unsigned   byte_base
    );
        int                fd;
        string             line;
        logic [15:0]       value;
        longint unsigned   global_word_idx;
        logic [24:0]       chip_local_word;
        int unsigned       loaded;
        int unsigned       bank;
        int unsigned       row;
        int unsigned       col;
        begin
            fd = $fopen(filename, "r");
            if (fd == 0) begin
                $error("xsds module_load_rom_hex: failed to open '%s'", filename);
                return;
            end

            if (byte_base[0]) begin
                $error("xsds module_load_rom_hex: byte_base=%0d is not 16-bit aligned",
                       byte_base);
                $fclose(fd);
                return;
            end

            global_word_idx = byte_base >> 1;
            loaded = 0;

            while ($fgets(line, fd) != 0) begin
                if ($sscanf(line, "%h", value) == 1) begin
                    if (global_word_idx >= (longint'(1) << 26)) begin
                        $error("xsds module_load_rom_hex: word offset %0d exceeds 128 MB capacity",
                               global_word_idx);
                        break;
                    end

                    chip_local_word = global_word_idx[24:0];
                    bank = int'(chip_local_word[24:23]);
                    row  = int'(chip_local_word[22:10]);
                    col  = int'(chip_local_word[9:0]);

                    if (global_word_idx[25] == 1'b0) begin
                        u_chip0.poke(bank, row, col, value);
                    end else begin
                        u_chip1.poke(bank, row, col, value);
                    end

                    global_word_idx++;
                    loaded++;
                end
            end
            $fclose(fd);
        end
    endtask

endmodule


// =============================================================================
// AS4C32M16SB-6TIN-compatible 512 Mbit x16 SDR SDRAM chip model
// =============================================================================
// Geometry:
//   512 Mbits = 64 MBytes
//   4 banks x 8192 rows x 1024 columns x 16 bits
//
// Features modeled:
//   - ACT, READ, WRITE, PRECHARGE, PRECHARGE ALL
//   - AUTO REFRESH
//   - SELF REFRESH entry/exit
//   - MODE REGISTER SET
//   - BURST STOP
//   - CAS latency 2 or 3
//   - Burst length 1, 2, 4, 8, full page
//   - Sequential and interleaved bursts
//   - Write burst single/burst mode
//   - LDQM/UDQM byte masking
//   - Read DQM two-clock output-mask latency
//   - Sparse memory backing store
//   - 8192 refresh commands per 64 ms checker
//
// Simulation-only. Not synthesizable.
// =============================================================================

module as4c32m16sb_6tin_chip_model #(
    parameter string   CHIP_NAME             = "AS4C32M16SB",
    parameter bit      DEBUG                 = 1'b0,
    parameter bit      STRICT_TIMING         = 1'b1,
    parameter bit      WARN_TREFI            = 1'b1,
    parameter bit      INIT_UNWRITTEN_TO_X   = 1'b1,

    // Geometry.
    parameter int      BANKS                 = 4,
    parameter int      ROW_BITS              = 13,
    parameter int      ROWS                  = 8192,
    parameter int      COL_BITS              = 10,
    parameter int      COLS                  = 1024,
    parameter int      DATA_BITS             = 16,

    // The physical column count is 1024 for this 512 Mbit x16 organization.
    // Some datasheet tables list 512 for full-page length; keep this as a
    // parameter so you can override it if your target controller expects that.
    parameter int      FULL_PAGE_LEN         = 1024,

    // AS4C32M16SB-6 speed-grade timing, ns.
    parameter realtime tCK_CL2_MIN           = 10.0,
    parameter realtime tCK_CL3_MIN           = 6.0,
    parameter realtime tCH_MIN               = 2.0,
    parameter realtime tCL_MIN               = 2.0,
    parameter realtime tRC_MIN               = 60.0,
    parameter realtime tRFC_MIN              = 60.0,
    parameter realtime tRCD_MIN              = 18.0,
    parameter realtime tRP_MIN               = 18.0,
    parameter realtime tRRD_MIN              = 12.0,
    parameter realtime tMRD_MIN              = 12.0,
    parameter realtime tRAS_MIN              = 42.0,
    parameter realtime tRAS_MAX              = 120_000.0,
    parameter realtime tWR_MIN               = 12.0,
    parameter realtime tWTR_MIN              = 7.5,
    parameter realtime tCCD_MIN              = 6.0,
    parameter realtime tXSR_MIN              = 70.0,
    parameter realtime tIS_MIN               = 1.5,
    parameter realtime tIH_MIN               = 0.8,
    parameter realtime tDS_MIN               = 1.5,
    parameter realtime tDH_MIN               = 0.8,
    // Read-path output timing (DQ pad). All three are intra-assignment NBA
    // delays so they take effect under any simulator that supports --timing
    // (Verilator with --timing, ModelSim, Questa, etc.).
    //
    //   tAC_MAX: clock-to-data-valid for read data on the DQ pad.
    //   tHZ_MAX: clock-to-Hi-Z when the chip stops driving DQ.
    //   tLZ_MIN: clock-to-driving when the chip starts driving DQ. Real
    //            silicon spec is "min", but we use it as the NBA delay
    //            here so the OE asserts that long after the clock edge.
    //
    // tOH (data-out hold time after the next clock edge) is not modeled
    // separately — under the NBA-with-tAC scheme it ends up roughly
    // equal to tAC, which exceeds the AS4C32M16SB-6TIN tOH spec of 2.5 ns.
    parameter realtime tAC_MAX               = 5.4,
    parameter realtime tHZ_MAX               = 5.4,
    parameter realtime tLZ_MIN               = 1.0,
    parameter realtime tREFI_MAX             = 7_800.0,

    // 8192 refresh cycles per 64 ms.
    parameter realtime tREF_WINDOW           = 64_000_000.0,
    parameter int      REFRESHES_PER_WINDOW  = 8192,

    parameter realtime POWERUP_STABLE_TIME   = 200_000.0
) (
    input  wire        Clk,
    input  wire        Cke,
    input  wire        Cs_n,
    input  wire        Ras_n,
    input  wire        Cas_n,
    input  wire        We_n,
    input  wire [1:0]  Ba,
    input  wire [12:0] Addr,
    input  wire        Ldqm,
    input  wire        Udqm,
    inout  wire [15:0] Dq
);

    // -------------------------------------------------------------------------
    // Command decode
    // -------------------------------------------------------------------------

    localparam int CMD_DESL = 0;
    localparam int CMD_NOP  = 1;
    localparam int CMD_ACT  = 2;
    localparam int CMD_READ = 3;
    localparam int CMD_WRIT = 4;
    localparam int CMD_PRE  = 5;
    localparam int CMD_AREF = 6;
    localparam int CMD_MRS  = 7;
    localparam int CMD_BST  = 8;
    localparam int CMD_SREF = 9;

    function automatic int decode_cmd(
        input bit cs_n,
        input bit ras_n,
        input bit cas_n,
        input bit we_n,
        input bit cke_now
    );
        begin
            if (cs_n) begin
                decode_cmd = CMD_DESL;
            end else begin
                unique case ({ras_n, cas_n, we_n})
                    3'b111: decode_cmd = CMD_NOP;
                    3'b011: decode_cmd = CMD_ACT;
                    3'b101: decode_cmd = CMD_READ;
                    3'b100: decode_cmd = CMD_WRIT;
                    3'b010: decode_cmd = CMD_PRE;
                    3'b001: decode_cmd = cke_now ? CMD_AREF : CMD_SREF;
                    3'b000: decode_cmd = CMD_MRS;
                    3'b110: decode_cmd = CMD_BST;
                    default: decode_cmd = CMD_NOP;
                endcase
            end
        end
    endfunction

    function automatic string cmd_name(input int cmd);
        begin
            unique case (cmd)
                CMD_DESL: cmd_name = "DESL";
                CMD_NOP : cmd_name = "NOP";
                CMD_ACT : cmd_name = "ACT";
                CMD_READ: cmd_name = "READ";
                CMD_WRIT: cmd_name = "WRITE";
                CMD_PRE : cmd_name = "PRECHARGE";
                CMD_AREF: cmd_name = "AUTO_REFRESH";
                CMD_MRS : cmd_name = "MODE_REGISTER_SET";
                CMD_BST : cmd_name = "BURST_STOP";
                CMD_SREF: cmd_name = "SELF_REFRESH";
                default : cmd_name = "UNKNOWN";
            endcase
        end
    endfunction

    // -------------------------------------------------------------------------
    // Sparse memory
    // -------------------------------------------------------------------------

    typedef bit   [24:0] mem_key_t;
    typedef logic [15:0] data_t;

    data_t mem [mem_key_t];

    function automatic mem_key_t make_key(
        input int unsigned bank,
        input int unsigned row,
        input int unsigned col
    );
        begin
            make_key = mem_key_t'({bank[1:0], row[12:0], col[9:0]});
        end
    endfunction

    function automatic data_t mem_read(
        input int unsigned bank,
        input int unsigned row,
        input int unsigned col
    );
        mem_key_t key;
        begin
            key = make_key(bank, row, col);

            if (mem.exists(key)) begin
                mem_read = mem[key];
            end else if (INIT_UNWRITTEN_TO_X) begin
                mem_read = 16'hxxxx;
            end else begin
                mem_read = 16'h0000;
            end
        end
    endfunction

    task automatic mem_write(
        input int unsigned bank,
        input int unsigned row,
        input int unsigned col,
        input data_t       data_in,
        input bit          mask_low,
        input bit          mask_high
    );
        mem_key_t key;
        data_t old_data;
        data_t new_data;
        begin
            key      = make_key(bank, row, col);
            old_data = mem_read(bank, row, col);
            new_data = old_data;

            if (!mask_low)  new_data[7:0]  = data_in[7:0];
            if (!mask_high) new_data[15:8] = data_in[15:8];

            mem[key] = new_data;

            if (DEBUG) begin
                $display("%0t %s WRITE bank=%0d row=%0d col=%0d data=%04h dqm=%b%b",
                         $time, CHIP_NAME, bank, row, col, new_data, mask_high, mask_low);
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Bank state
    // -------------------------------------------------------------------------

    bit          bank_open [BANKS];
    int unsigned open_row  [BANKS];

    realtime last_activate  [BANKS];
    realtime last_precharge [BANKS];
    realtime last_write     [BANKS];
    realtime last_read      [BANKS];

    realtime last_any_activate;
    realtime fix6_last_edge = -1.0e30;   // LOCAL FIX 6: the previous Clk posedge
    realtime fix6_tck       = 0.0;       // LOCAL FIX 6: the measured clock period
    realtime last_refresh;
    realtime last_mrs;
    realtime last_self_refresh_exit;
    realtime last_col_cmd;

    initial begin
        int i;

        for (i = 0; i < BANKS; i++) begin
            bank_open[i]      = 1'b0;
            open_row[i]       = 0;
            last_activate[i]  = -1.0e30;
            last_precharge[i] = -1.0e30;
            last_write[i]     = -1.0e30;
            last_read[i]      = -1.0e30;
        end

        last_any_activate      = -1.0e30;
        last_refresh           = -1.0e30;
        last_mrs               = -1.0e30;
        last_self_refresh_exit = -1.0e30;
        last_col_cmd           = -1.0e30;
    end

    function automatic bit all_banks_idle();
        int i;
        begin
            all_banks_idle = 1'b1;

            for (i = 0; i < BANKS; i++) begin
                if (bank_open[i]) all_banks_idle = 1'b0;
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // Mode register
    // -------------------------------------------------------------------------

    int unsigned burst_length;
    bit          burst_full_page;
    bit          burst_interleaved;
    int unsigned cas_latency;
    bit          write_burst_single;

    initial begin
        burst_length       = 1;
        burst_full_page    = 1'b0;
        burst_interleaved  = 1'b0;
        cas_latency        = 3;
        write_burst_single = 1'b0;
    end

    function automatic int unsigned decode_burst_length(input bit [2:0] bl);
        begin
            unique case (bl)
                3'b000: decode_burst_length = 1;
                3'b001: decode_burst_length = 2;
                3'b010: decode_burst_length = 4;
                3'b011: decode_burst_length = 8;
                3'b111: decode_burst_length = FULL_PAGE_LEN;
                default: decode_burst_length = 0;
            endcase
        end
    endfunction

    task automatic load_mode_register(input bit [12:0] mode);
        int unsigned bl;
        begin
            bl = decode_burst_length(mode[2:0]);

            if (Ba != 2'b00) begin
                issue_warn("MRS BA should be 00");
            end

            if (mode[10] != 1'b0) begin
                issue_warn("MRS A10 should be 0");
            end

            if (mode[12] != 1'b0 || mode[11] != 1'b0) begin
                issue_warn("MRS A12:A11 should be 00/RFU");
            end

            if (bl == 0) begin
                issue_error("reserved MRS burst length selected");
                bl = 1;
            end

            burst_length      = bl;
            burst_full_page   = (mode[2:0] == 3'b111);
            burst_interleaved = mode[3];

            unique case (mode[6:4])
                3'b010: cas_latency = 2;
                3'b011: cas_latency = 3;
                default: begin
                    issue_error("reserved MRS CAS latency selected");
                    cas_latency = 3;
                end
            endcase

            if (mode[8:7] != 2'b00) begin
                issue_error("MRS test mode bits A8:A7 must be 00");
            end

            write_burst_single = mode[9];

            if (burst_full_page && burst_interleaved) begin
                issue_error("full-page burst is not valid with interleaved burst type");
            end

            if (DEBUG) begin
                $display("%0t %s MRS BL=%0d full=%0b BT=%s CL=%0d WBL=%s",
                         $time,
                         CHIP_NAME,
                         burst_length,
                         burst_full_page,
                         burst_interleaved ? "interleaved" : "sequential",
                         cas_latency,
                         write_burst_single ? "single" : "burst");
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Burst address generation
    // -------------------------------------------------------------------------

    function automatic int unsigned next_col(
        input int unsigned start_col,
        input int unsigned index,
        input int unsigned len,
        input bit          interleaved
    );
        int unsigned low_mask;
        int unsigned base;
        int unsigned offset;
        begin
            if (len <= 1) begin
                next_col = start_col & (COLS - 1);
            end else if (interleaved) begin
                low_mask = len - 1;
                base     = start_col & ~low_mask;
                offset   = (start_col ^ index) & low_mask;
                next_col = (base | offset) & (COLS - 1);
            end else begin
                low_mask = len - 1;
                base     = start_col & ~low_mask;
                offset   = (start_col + index) & low_mask;
                next_col = (base | offset) & (COLS - 1);
            end
        end
    endfunction

    // -------------------------------------------------------------------------
    // DQ drive and DQM pipeline
    // -------------------------------------------------------------------------

    logic [15:0] dq_out;
    logic        dq_oe;

    assign Dq = dq_oe ? dq_out : 16'hzzzz;

    logic [1:0] dqm_pipe [0:1];

    initial begin
        dq_out      = 16'h0000;
        dq_oe       = 1'b0;
        dqm_pipe[0] = 2'b11;
        dqm_pipe[1] = 2'b11;
    end

    // -------------------------------------------------------------------------
    // Active burst state
    // -------------------------------------------------------------------------

    typedef struct {
        bit          active;
        bit          is_read;
        bit          is_write;
        int unsigned bank;
        int unsigned row;
        int unsigned start_col;
        int unsigned index;
        int unsigned len;
        int unsigned latency;
        bit          auto_precharge;
        bit          full_page;
        bit          interleaved;
    } burst_state_t;

    burst_state_t burst;

    // LOCAL FIX (PC-9821 core, 2026-10-10): READs whose CAS latency is still
    // running. A real SDR SDRAM pipelines READs - each READ's data appears CL
    // cycles after ITS OWN command, and a later READ does not cancel it
    // (JEDEC SDR SDRAM / AS4C32M16SB datasheet: a new READ only replaces the
    // burst that is already outputting, from the new read's own CL slot on).
    // The upstream model restarted one latency counter per READ via
    // stop_burst(), so two back-to-back BL=1 READs lost the first word.
    burst_state_t read_pipe [$];

    initial begin
        burst.active         = 1'b0;
        burst.is_read        = 1'b0;
        burst.is_write       = 1'b0;
        burst.bank           = 0;
        burst.row            = 0;
        burst.start_col      = 0;
        burst.index          = 0;
        burst.len            = 1;
        burst.latency        = 0;
        burst.auto_precharge = 1'b0;
        burst.full_page      = 1'b0;
        burst.interleaved    = 1'b0;
    end

    task automatic stop_burst();
        begin
            burst.active   = 1'b0;
            burst.is_read  = 1'b0;
            burst.is_write = 1'b0;
            dq_oe          = 1'b0;
        end
    endtask

    // LOCAL FIX 3: a burst that RAN OUT ends without touching dq_oe. The upstream
    // stop_burst() forced dq_oe low at the very edge that launched the last beat's
    // successor slot, which is the edge the controller captures the PREVIOUS beat on, so
    // the bus went Hi-Z in the same time step as the capture (a race: any BL>=2 read, or
    // two reads back to back, could lose a word). The next edge's idle branch
    // (dq_oe <= #tHZ_MAX 0) already releases the bus tHZ after the capture edge.
    task automatic end_burst();
        begin
            burst.active   = 1'b0;
            burst.is_read  = 1'b0;
            burst.is_write = 1'b0;
        end
    endtask

    // LOCAL FIX: a COMMAND that cuts the data path (PRE, AREF, SREF, BST, a WRITE
    // or an ACT-over-write) also kills reads still in their CAS latency. A burst
    // that merely RAN OUT must not: the next READ's data is already in the pipe.
    task automatic cut_burst();
        begin
            stop_burst();
            read_pipe.delete();
        end
    endtask

    // LOCAL FIX: once per clock, before the burst engine runs. A pending READ
    // whose latency has elapsed becomes the outputting burst (replacing, i.e.
    // truncating, any earlier burst still outputting); the rest count down.
    task automatic mature_read_pipe();
        burst_state_t e;
        begin
            for (int i = 0; i < read_pipe.size(); ) begin
                if (read_pipe[i].latency == 0) begin
                    e = read_pipe[i];
                    read_pipe.delete(i);
                    burst = e;
                end else begin
                    read_pipe[i].latency--;
                    i++;
                end
            end
        end
    endtask

    task automatic maybe_auto_precharge(
        input int unsigned bank,
        input bit          from_write = 1'b0,
        input bit          from_read  = 1'b0
    );
        begin
            if (burst.auto_precharge && !burst.full_page) begin
                do_precharge(bank, 1'b0, "auto-precharge", from_write, from_read);
            end
        end
    endtask

    task automatic advance_read_burst();
        int unsigned col;
        int unsigned ap_trigger_idx;
        data_t data_read;
        data_t outgoing;
        logic [1:0] read_dqm;
        begin
            if (!burst.active || !burst.is_read) begin
                // Going / staying Hi-Z: schedule with tHZ_MAX.
                dq_oe <= #(tHZ_MAX) 1'b0;
            end else if (burst.latency != 0) begin
                burst.latency--;
                dq_oe <= #(tHZ_MAX) 1'b0;
            end else begin
                col       = next_col(burst.start_col, burst.index, burst.len, burst.interleaved);
                data_read = mem_read(burst.bank, burst.row, col);
                // LOCAL FIX 2: DQM has a 2-clock read latency counted to the CAPTURE edge
                // (CONTROLLER_GUIDE: "drive DQM two clocks before the data clock you want
                // to mask"). This edge LAUNCHES the word, one clock before it is captured,
                // so the DQM that applies is the one sampled on the previous edge. (The
                // upstream model used dqm_pipe[1], two edges back, matching its late launch.)
                read_dqm  = dqm_pipe[0];

                outgoing = data_read;
                if (read_dqm[0]) outgoing[7:0]  = 8'hzz;
                if (read_dqm[1]) outgoing[15:8] = 8'hzz;

                // Data drive: tAC for the value, tLZ for the OE assertion.
                // tLZ is typically smaller than tAC, so the OE goes high
                // before the data is fully valid — real silicon shows the
                // pad transitioning out of Hi-Z while data settles.
                dq_out <= #(tAC_MAX) outgoing;
                dq_oe  <= #(tLZ_MIN) 1'b1;

                if (DEBUG) begin
                    $display("%0t %s READ bank=%0d row=%0d col=%0d data=%04h dqm_latency2=%b",
                             $time, CHIP_NAME, burst.bank, burst.row, col, data_read, read_dqm);
                end

                burst.index++;

                // Real silicon launches a READ+AP's implied PRECHARGE about
                // BL-CL cycles into the burst (so tRP overlaps the trailing
                // CL data cycles and a same-bank ACT can come sooner).
                // Trigger AP after max(1, BL-CL) data cycles have been
                // output; remaining cycles still drive Dq from the snapshot.
                if (burst.auto_precharge && !burst.full_page) begin
                    ap_trigger_idx = (burst.len > cas_latency) ?
                                     (burst.len - cas_latency) : 1;
                    if (burst.index >= ap_trigger_idx) begin
                        do_precharge(burst.bank, 1'b0, "auto-precharge (read)",
                                     1'b0, 1'b1);
                        burst.auto_precharge = 1'b0;
                    end
                end

                if (!burst.full_page && burst.index >= burst.len) begin
                    maybe_auto_precharge(burst.bank);
                    end_burst();
                end
            end
        end
    endtask

    task automatic consume_write_data();
        int unsigned col;
        begin
            col = next_col(burst.start_col, burst.index, burst.len, burst.interleaved);

            // tDS: Dq must have been stable for at least tDS_MIN before
            // this posedge captured the write data. last_dq_sample records
            // this capture edge so the @(Dq) block can check tDH on the
            // next transition.
            check_time_min("tDS on Dq during write",
                           last_dq_change, tDS_MIN);
            last_dq_sample = $realtime;

            mem_write(
                burst.bank,
                burst.row,
                col,
                Dq,
                Ldqm,
                Udqm
            );

            // Stamp at every data cycle so tWR (write-to-precharge) and tWTR
            // (write-to-read) measure from the LAST DQ input, not from the
            // WRITE command. Matters once BL > 1.
            last_write[burst.bank] = $realtime;

            burst.index++;

            if (!burst.full_page && burst.index >= burst.len) begin
                maybe_auto_precharge(burst.bank, 1'b1);
                end_burst();
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Initialization and refresh tracking
    // -------------------------------------------------------------------------

    bit init_seen_cke_high;
    bit init_seen_precharge_all;
    bit init_seen_mrs;
    int init_auto_refresh_count;

    realtime refresh_times [$];

    bit in_power_down;
    bit in_self_refresh;
    bit in_clock_suspend;

    initial begin
        init_seen_cke_high      = 1'b0;
        init_seen_precharge_all = 1'b0;
        init_seen_mrs           = 1'b0;
        init_auto_refresh_count = 0;
        in_power_down           = 1'b0;
        in_self_refresh         = 1'b0;
        in_clock_suspend        = 1'b0;
    end

    task automatic record_refresh();
        realtime span;
        begin
            if (WARN_TREFI && refresh_times.size() != 0) begin
                if (($realtime - refresh_times[refresh_times.size()-1]) > tREFI_MAX) begin
                    issue_warn($sformatf("AUTO REFRESH interval %0.3f ns exceeds tREFI target %0.3f ns",
                                         $realtime - refresh_times[refresh_times.size()-1],
                                         tREFI_MAX));
                end
            end

            last_refresh = $realtime;
            refresh_times.push_back($realtime);

            while (refresh_times.size() > REFRESHES_PER_WINDOW) begin
                void'(refresh_times.pop_front());
            end

            if (refresh_times.size() == REFRESHES_PER_WINDOW) begin
                span = refresh_times[refresh_times.size()-1] - refresh_times[0];

                if (span > tREF_WINDOW) begin
                    issue_error($sformatf("refresh requirement violated: %0d AUTO REFRESH commands span %0.3f ns; limit is %0.3f ns",
                                          REFRESHES_PER_WINDOW,
                                          span,
                                          tREF_WINDOW));
                end
            end
        end
    endtask

    task automatic check_init_before_normal_cmd(input int cmd);
        begin
            // Any real command (anything other than NOP/DESL) issued before
            // POWERUP_STABLE_TIME violates the chip's 200 us power-up
            // requirement. Encoded here rather than at the CKE rising edge
            // so it works on the XSDS connector (Cke tied to VCC) where the
            // first clock cycle observes Cke=1 by definition.
            if ((cmd != CMD_NOP) && (cmd != CMD_DESL)) begin
                if ($realtime < POWERUP_STABLE_TIME) begin
                    issue_error($sformatf("command %s issued at %0.3f ns before %0.0f us power-up delay",
                                          cmd_name(cmd),
                                          $realtime,
                                          POWERUP_STABLE_TIME / 1000.0));
                end
            end

            if ((cmd == CMD_ACT) || (cmd == CMD_READ) || (cmd == CMD_WRIT)) begin
                if (!init_seen_cke_high) begin
                    issue_error("normal command before CKE high");
                end

                if (!init_seen_precharge_all) begin
                    issue_error("normal command before initialization PRECHARGE ALL");
                end

                if (!init_seen_mrs) begin
                    issue_error("normal command before MODE REGISTER SET");
                end

                if (init_auto_refresh_count < 2) begin
                    issue_error("normal command before two initialization AUTO REFRESH cycles");
                end
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Diagnostics and timing helpers
    // -------------------------------------------------------------------------

    // TB-readable counters. Bumped on every issue_error / issue_warn call,
    // regardless of whether STRICT_TIMING routes the violation to $error or
    // downgrades it to $warning. Lets a testbench assert no-violations at
    // end-of-test without parsing simulator output.
    int unsigned error_count;
    int unsigned warning_count;

    initial begin
        error_count   = 0;
        warning_count = 0;
    end

    task automatic issue_error(input string msg);
        begin
            error_count++;
            if (STRICT_TIMING) begin
                $error("%0t %s %s", $time, CHIP_NAME, msg);
            end else begin
                $warning("%0t %s %s", $time, CHIP_NAME, msg);
            end
        end
    endtask

    task automatic issue_warn(input string msg);
        begin
            warning_count++;
            $warning("%0t %s %s", $time, CHIP_NAME, msg);
        end
    endtask

    task automatic check_time_min(
        input string label_name,
        input realtime last_time,
        input realtime required
    );
        realtime delta;
        begin
            delta = $realtime - last_time;

            if ((last_time > -1.0e20) && (delta < required)) begin
                issue_error($sformatf("%s violation: delta=%0.3f ns, required=%0.3f ns",
                                      label_name,
                                      delta,
                                      required));
            end
        end
    endtask

    // -------------------------------------------------------------------------
    // Input setup / hold tracking (tIS, tIH, tDS)
    //
    // Records the last transition timestamp for each command-pin group
    // (command, address, DQ) and checks setup at posedge Clk plus hold at
    // each subsequent transition. Aggregated per-group to keep the code
    // compact; the violation message names the group rather than the
    // specific signal, which is good enough for catching TB / controller
    // bugs.
    //
    // All checks are gated on init_seen_cke_high so the pre-init / power-up
    // window (when many TBs idle their signals without a defined transition
    // history) does not generate spurious violations.
    // -------------------------------------------------------------------------

    realtime last_cmdpin_change   = -1.0e30;
    realtime last_addrpin_change  = -1.0e30;
    realtime last_dq_change       = -1.0e30;
    realtime last_dq_sample       = -1.0e30;  // posedge of last write-data capture
    // last_clk_posedge is shared with the clock-period checks block below.

    task automatic check_input_hold(input string group, input realtime required);
        realtime delta;
        begin
            if (last_clk_posedge > -1.0e20) begin
                delta = $realtime - last_clk_posedge;
                // delta == 0.0 means the signal changed via an NBA at the
                // same simulation time as the posedge — the standard sync-
                // logic pattern where real silicon's tCO propagation delay
                // would put the actual change slightly after the edge.
                // Behavioral sim can't tell that apart from a real tIH
                // violation, so accept delta == 0 and only flag narrow-
                // window changes in (0, tIH_MIN).
                if (delta > 0.0 && delta < required) begin
                    issue_error($sformatf("tIH on %s violation: delta=%0.3f ns, required=%0.3f ns",
                                          group, delta, required));
                end
            end
        end
    endtask

    always @(Cs_n or Ras_n or Cas_n or We_n) begin
        if (init_seen_cke_high) check_input_hold("command pins", tIH_MIN);
        last_cmdpin_change = $realtime;
    end

    always @(Ba or Addr or Ldqm or Udqm) begin
        if (init_seen_cke_high) check_input_hold("address / DQM pins", tIH_MIN);
        last_addrpin_change = $realtime;
    end

    always @(Dq) begin : dq_xition
        realtime delta;
        if (last_dq_sample > -1.0e20) begin
            delta = $realtime - last_dq_sample;
            // Same delta > 0.0 guard as tIH: NBA-at-posedge changes that
            // happen to fall on the same simulation time as the capture
            // edge are the standard sync pattern, not real tDH violations.
            if (delta > 0.0 && delta < tDH_MIN) begin
                issue_error($sformatf("tDH on Dq violation: delta=%0.3f ns, required=%0.3f ns",
                                      delta, tDH_MIN));
            end
        end
        last_dq_change = $realtime;
    end

    // -------------------------------------------------------------------------
    // Command handlers
    // -------------------------------------------------------------------------

    task automatic do_activate(input int unsigned bank, input int unsigned row);
        begin
            if (bank >= BANKS) begin
                issue_error($sformatf("illegal bank index %0d", bank));
                return;
            end

            if (bank_open[bank]) begin
                issue_error($sformatf("ACT to bank %0d while already active", bank));
            end

            check_time_min($sformatf("tRP bank %0d PRE-to-ACT", bank),
                           last_precharge[bank],
                           tRP_MIN);

            check_time_min($sformatf("tRC bank %0d ACT-to-ACT", bank),
                           last_activate[bank],
                           tRC_MIN);

            check_time_min("tRRD ACT-to-ACT",
                           last_any_activate,
                           tRRD_MIN);

            check_time_min("tRFC refresh-to-command",
                           last_refresh,
                           tRFC_MIN);

            check_time_min("tXSR self-refresh-exit-to-command",
                           last_self_refresh_exit,
                           tXSR_MIN);

            bank_open[bank]     = 1'b1;
            open_row[bank]      = row;
            last_activate[bank] = $realtime;
            last_any_activate   = $realtime;

            if (DEBUG) begin
                $display("%0t %s ACT bank=%0d row=%0d", $time, CHIP_NAME, bank, row);
            end
        end
    endtask

    task automatic do_precharge(
        input int unsigned bank,
        input bit          all_banks,
        input string       why,
        // Set when called for WRITE+AP. The chip schedules the implied
        // PRECHARGE tWR after the last data cycle, so skip the tWR check
        // (last_write was just stamped this cycle) and incorporate tWR
        // into the deferred PRE event timestamp.
        input bit          auto_from_write = 1'b0,
        // Set when called for READ+AP. Real silicon also handles tRAS
        // internally for READ+AP; skip the tRAS check on this path so
        // controllers like NES that issue ACT then WRITE/READ-with-AP a
        // cycle later don't get false-positive tRAS errors.
        input bit          auto_from_read  = 1'b0
    );
        realtime base_pre_time;
        realtime tras_target;
        bit      is_auto;
        int      i;
        begin
            is_auto = auto_from_write || auto_from_read;

            if (all_banks) begin
                for (i = 0; i < BANKS; i++) begin
                    if (bank_open[i]) begin
                        check_time_min($sformatf("tRAS bank %0d ACT-to-PRE", i),
                                       last_activate[i],
                                       tRAS_MIN);

                        check_time_min($sformatf("tWR bank %0d WRITE-to-PRE", i),
                                       last_write[i],
                                       tWR_MIN);
                    end

                    bank_open[i]      = 1'b0;
                    last_precharge[i] = $realtime;
                end

                if (DEBUG) begin
                    $display("%0t %s PRECHARGE ALL (%s)", $time, CHIP_NAME, why);
                end
            end else begin
                if (bank >= BANKS) begin
                    issue_error($sformatf("illegal bank index %0d", bank));
                    return;
                end

                if (bank_open[bank]) begin
                    // For explicit PRE, both checks fire. For AP, the chip
                    // handles tRAS / tWR internally — skip the checks and
                    // build the deferred PRE event time below instead.
                    if (!is_auto) begin
                        check_time_min($sformatf("tRAS bank %0d ACT-to-PRE", bank),
                                       last_activate[bank],
                                       tRAS_MIN);

                        check_time_min($sformatf("tWR bank %0d WRITE-to-PRE", bank),
                                       last_write[bank],
                                       tWR_MIN);
                    end
                end

                bank_open[bank] = 1'b0;

                // LOCAL FIX 6: WRITE with auto-precharge - the precharge begins tWR after this
                // data, with no tRAS lockout (the deferral below stays for the tRP stamp).
                if (auto_from_write && (($realtime + tWR_MIN) - last_activate[bank] < tRAS_MIN)) begin
                    issue_error($sformatf("tRAS bank %0d ACT-to-auto-precharge (WRITE) violation: delta=%0.3f ns, required=%0.3f ns",
                                          bank, ($realtime + tWR_MIN) - last_activate[bank], tRAS_MIN));
                end

                if (is_auto) begin
                    // Real silicon defers the implied PRECHARGE so that
                    // both tRAS (from ACT) and tWR (from last write) are
                    // satisfied at the moment the row actually closes.
                    // Stamp last_precharge at the later of:
                    //   - $realtime + tWR_MIN (write-AP) or $realtime (read-AP)
                    //   - last_activate + tRAS_MIN
                    // so the next ACT's tRP check measures from the real
                    // (deferred) precharge event rather than this cycle.
                    base_pre_time = auto_from_write ? ($realtime + tWR_MIN)
                                                    :  $realtime;
                    tras_target   = last_activate[bank] + tRAS_MIN;

                    last_precharge[bank] = (base_pre_time > tras_target) ?
                                           base_pre_time : tras_target;
                end else begin
                    last_precharge[bank] = $realtime;
                end

                if (DEBUG) begin
                    $display("%0t %s PRECHARGE bank=%0d (%s)", $time, CHIP_NAME, bank, why);
                end
            end
        end
    endtask

    task automatic do_read(
        input int unsigned bank,
        input int unsigned col,
        input bit auto_precharge
    );
        burst_state_t rpend;   // LOCAL FIX
        begin
            if (bank >= BANKS) begin
                issue_error($sformatf("illegal bank index %0d", bank));
                return;
            end

            if (!bank_open[bank]) begin
                issue_error($sformatf("READ to inactive bank %0d", bank));
            end

            // LOCAL FIX 6: READ with auto-precharge - the precharge begins one clock (the
            // burst length) after this command, with no tRAS lockout.
            if (auto_precharge && (fix6_tck > 0.0) &&
                (($realtime + fix6_tck * burst_length) - last_activate[bank] < tRAS_MIN)) begin
                issue_error($sformatf("tRAS bank %0d ACT-to-auto-precharge (READ) violation: delta=%0.3f ns, required=%0.3f ns",
                                      bank, ($realtime + fix6_tck * burst_length) - last_activate[bank], tRAS_MIN));
            end

            check_time_min("tCCD READ/WRITE-to-READ",
                           last_col_cmd,
                           tCCD_MIN);

            check_time_min($sformatf("tRCD bank %0d ACT-to-READ", bank),
                           last_activate[bank],
                           tRCD_MIN);

            check_time_min($sformatf("tWTR bank %0d WRITE-to-READ", bank),
                           last_write[bank],
                           tWTR_MIN);

            last_col_cmd = $realtime;

            // LOCAL FIX: no stop_burst() here - an earlier read's data (in its
            // CAS latency, or still outputting) must survive this command. Only
            // a write burst is cut by a READ.
            if (burst.is_write) stop_burst();

            rpend.active         = 1'b1;
            rpend.is_read        = 1'b1;
            rpend.is_write       = 1'b0;
            rpend.bank           = bank;
            rpend.row            = open_row[bank];
            rpend.start_col      = col & (COLS - 1);
            rpend.index          = 0;
            rpend.len            = burst_length;
            // LOCAL FIX 2: CAS latency CL = the controller CAPTURES the first word on the
            // CL-th clock edge after the READ's own edge, so the chip LAUNCHES it on edge
            // CL-1 (tAC after that edge - tAC is spec'd to fit inside one clock - is why a
            // CL=2 part at 100 MHz can hand a word to a register one clock later). The
            // upstream model launched on edge CL, one clock late: a controller that
            // captures at CL (every SDR controller, and this core's) read the previous
            // bus value. mature_read_pipe() launches on the edge its latency reaches 0.
            // Re-checked against MiSTer usage:
            // Micron's own BFM launches a CL=2 READ's word `#tAC` after edge T1
            // (SDRAMsim_MiSTer ref/mt48lc16m16a2.v:666 and
            // :1025), the datasheet's word is "valid by" edge CL (the AS4C32M16SB
            // datasheet, page 9), and upstream's own PSX bring-up
            // notes the model's data "appears one posedge later than real silicon"
            // (SDRAMsim_MiSTer/xsds_tb_psx.sv:274-277). No pin-clock phase or board delay can
            // stand in for this: the upstream window starts tAC after edge CL, the part's
            // ends tOH after it, and tOH < tAC.
            rpend.latency        = cas_latency - 2;
            rpend.auto_precharge = auto_precharge;
            rpend.full_page      = burst_full_page;
            rpend.interleaved    = burst_interleaved;
            read_pipe.push_back(rpend);

            last_read[bank] = $realtime;

            if (DEBUG) begin
                $display("%0t %s READ bank=%0d row=%0d col=%0d len=%0d ap=%0b",
                         $time,
                         CHIP_NAME,
                         bank,
                         open_row[bank],
                         col,
                         burst.len,
                         auto_precharge);
            end
        end
    endtask

    task automatic do_write(
        input int unsigned bank,
        input int unsigned col,
        input bit auto_precharge
    );
        int unsigned actual_len;
        begin
            if (bank >= BANKS) begin
                issue_error($sformatf("illegal bank index %0d", bank));
                return;
            end

            if (!bank_open[bank]) begin
                issue_error($sformatf("WRITE to inactive bank %0d", bank));
            end

            check_time_min("tCCD READ/WRITE-to-WRITE",
                           last_col_cmd,
                           tCCD_MIN);

            check_time_min($sformatf("tRCD bank %0d ACT-to-WRITE", bank),
                           last_activate[bank],
                           tRCD_MIN);

            last_col_cmd = $realtime;

            cut_burst();

            actual_len = write_burst_single ? 1 : burst_length;

            burst.active         = 1'b1;
            burst.is_read        = 1'b0;
            burst.is_write       = 1'b1;
            burst.bank           = bank;
            burst.row            = open_row[bank];
            burst.start_col      = col & (COLS - 1);
            burst.index          = 0;
            burst.len            = actual_len;
            burst.latency        = 0;
            burst.auto_precharge = auto_precharge;
            burst.full_page      = burst_full_page && !write_burst_single;
            burst.interleaved    = burst_interleaved;

            consume_write_data();

            if (DEBUG) begin
                $display("%0t %s WRITE bank=%0d row=%0d col=%0d len=%0d ap=%0b",
                         $time,
                         CHIP_NAME,
                         bank,
                         open_row[bank],
                         col,
                         actual_len,
                         auto_precharge);
            end
        end
    endtask

    task automatic do_auto_refresh();
        begin
            if (!all_banks_idle()) begin
                issue_error("AUTO REFRESH while one or more banks are active");
            end

            check_time_min("tRFC AUTO_REFRESH-to-AUTO_REFRESH",
                           last_refresh,
                           tRFC_MIN);

            // LOCAL FIX 7: every bank's precharge has completed (tRP) before the refresh.
            for (int i = 0; i < BANKS; i++) begin
                check_time_min($sformatf("tRP bank %0d PRE-to-AUTO_REFRESH", i),
                               last_precharge[i],
                               tRP_MIN);
            end

            record_refresh();

            // JEDEC init order is PRE-ALL -> 2 AREF -> MRS. Only count
            // refreshes that arrive after PRE-ALL so out-of-order init
            // sequences (e.g. MRS before PRE-ALL) trip the check later
            // instead of being silently accepted.
            if (init_seen_precharge_all) begin
                if (init_auto_refresh_count < 2) begin
                    init_auto_refresh_count++;
                end
            end

            if (DEBUG) begin
                $display("%0t %s AUTO REFRESH init_count=%0d window_count=%0d",
                         $time,
                         CHIP_NAME,
                         init_auto_refresh_count,
                         refresh_times.size());
            end
        end
    endtask

    task automatic do_burst_stop();
        begin
            if (DEBUG && burst.active) begin
                $display("%0t %s BURST STOP", $time, CHIP_NAME);
            end

            cut_burst();
        end
    endtask

    // -------------------------------------------------------------------------
    // Clock high/low checks
    // -------------------------------------------------------------------------

    realtime last_clk_posedge;
    realtime last_clk_negedge;

    initial begin
        last_clk_posedge = -1.0e30;
        last_clk_negedge = -1.0e30;
    end

    always @(posedge Clk) begin
        if (last_clk_negedge > -1.0e20) begin
            if (($realtime - last_clk_negedge) < tCL_MIN) begin
                issue_error($sformatf("tCL violation: low=%0.3f ns required=%0.3f ns",
                                      $realtime - last_clk_negedge,
                                      tCL_MIN));
            end
        end

        last_clk_posedge = $realtime;
    end

    always @(negedge Clk) begin
        if (last_clk_posedge > -1.0e20) begin
            if (($realtime - last_clk_posedge) < tCH_MIN) begin
                issue_error($sformatf("tCH violation: high=%0.3f ns required=%0.3f ns",
                                      $realtime - last_clk_posedge,
                                      tCH_MIN));
            end
        end

        last_clk_negedge = $realtime;
    end

    // -------------------------------------------------------------------------
    // Main synchronous behavior
    // -------------------------------------------------------------------------

    bit cke_prev;

    initial begin
        cke_prev = 1'b0;
    end

    always @(posedge Clk) begin : main_proc
        int cmd;
        int unsigned bank;
        int unsigned row;
        int unsigned col;
        bit auto_precharge;
        bit precharge_all;

        // LOCAL FIX 6: this clock's period (the READ-with-auto-precharge check's one clock).
        if (fix6_last_edge > -1.0e20) fix6_tck = $realtime - fix6_last_edge;
        fix6_last_edge = $realtime;

        // Setup checks: every command / address pin must have been stable
        // for at least tIS_MIN before this edge. Gated on init_seen_cke_high
        // so pre-init transients (which many TBs leave undefined) don't
        // spam errors during the 200 us power-up window.
        // (last_clk_posedge is updated by the tCL/tCH always block below
        //  on the same edge, so the input-hold checks see it as $realtime.)
        if (init_seen_cke_high) begin
            check_time_min("tIS on command pins",
                           last_cmdpin_change, tIS_MIN);
            check_time_min("tIS on address / DQM pins",
                           last_addrpin_change, tIS_MIN);
        end

        // X-prop check on command pins. decode_cmd's bit-typed args silently
        // coerce X/Z to 0, which would let undefined controller outputs
        // collapse into a defined (often dangerous) command — e.g. an X on
        // Cs_n becomes "selected" and an X on Ras/Cas/We becomes MRS. Flag
        // X/Z explicitly so those bugs surface here instead of as confusing
        // downstream state corruption.
        //
        // Use $isunknown() rather than `=== 1'bx` so the check works under
        // 2-state simulators (e.g. Verilator default mode), where `1'bx`
        // collapses to 0 and `Cs_n === 1'bx` becomes a false positive every
        // time Cs_n is 0.
        if ($isunknown(Cke)) begin
            issue_error("X/Z on Cke");
            disable main_proc;
        end
        if (Cke === 1'b1 && init_seen_cke_high) begin
            if ($isunknown(Cs_n)) begin
                issue_error("X/Z on Cs_n while Cke=1");
                disable main_proc;
            end
            if ($isunknown(Ras_n)) begin
                issue_error("X/Z on Ras_n while Cke=1");
                disable main_proc;
            end
            if ($isunknown(Cas_n)) begin
                issue_error("X/Z on Cas_n while Cke=1");
                disable main_proc;
            end
            if ($isunknown(We_n)) begin
                issue_error("X/Z on We_n while Cke=1");
                disable main_proc;
            end
        end

        cmd            = decode_cmd(Cs_n, Ras_n, Cas_n, We_n, Cke);
        bank           = int'(Ba);
        row            = int'(Addr[ROW_BITS-1:0]);
        col            = int'(Addr[COL_BITS-1:0]);
        auto_precharge = Addr[10];
        precharge_all  = Addr[10];

        dqm_pipe[1] <= dqm_pipe[0];
        dqm_pipe[0] <= {Udqm, Ldqm};

        // Stamp init_seen_cke_high on the first CKE-high cycle. Don't error
        // on it being early — on the XSDS connector Cke is tied to VCC and
        // the very first clock cycle observes it high, which is fine. The
        // power-up window is enforced against the first real command in
        // check_init_before_normal_cmd, where it actually matters.
        if (!init_seen_cke_high && Cke) begin
            init_seen_cke_high = 1'b1;
        end

        if (in_self_refresh) begin
            dq_oe = 1'b0;

            if (!cke_prev && Cke) begin
                in_self_refresh        = 1'b0;
                last_self_refresh_exit = $realtime;
                refresh_times.delete();

                if (DEBUG) begin
                    $display("%0t %s SELF REFRESH EXIT", $time, CHIP_NAME);
                end
            end

            cke_prev <= Cke;
            disable main_proc;
        end

        if (!cke_prev && Cke) begin
            if (in_power_down) begin
                in_power_down = 1'b0;

                if (DEBUG) begin
                    $display("%0t %s POWER DOWN EXIT", $time, CHIP_NAME);
                end

                cke_prev <= Cke;
                disable main_proc;
            end

            if (in_clock_suspend) begin
                in_clock_suspend = 1'b0;

                if (DEBUG) begin
                    $display("%0t %s CLOCK SUSPEND EXIT", $time, CHIP_NAME);
                end

                cke_prev <= Cke;
                disable main_proc;
            end
        end

        if (cke_prev && !Cke) begin
            if (cmd == CMD_SREF) begin
                if (!all_banks_idle()) begin
                    issue_error("SELF REFRESH entry while banks active");
                end

                in_self_refresh = 1'b1;
                dq_oe = 1'b0;

                if (DEBUG) begin
                    $display("%0t %s SELF REFRESH ENTRY", $time, CHIP_NAME);
                end
            end else if (burst.active) begin
                // Clock-suspend during an active burst: the chip freezes
                // the burst engine and holds DQ at its current value. Do
                // not clear dq_oe — the previous cycle's NBA-with-tAC
                // delay sets the held output.
                in_clock_suspend = 1'b1;
            end else if (all_banks_idle()) begin
                in_power_down = 1'b1;
                dq_oe = 1'b0;
            end else begin
                // Clock-suspend with banks open but no active burst: no
                // DQ output to hold, but also no need to force Hi-Z here.
                in_clock_suspend = 1'b1;
            end

            cke_prev <= Cke;
            disable main_proc;
        end

        if (!Cke) begin
            // Generic CKE-low fallback for cycles after the falling edge.
            // PD / SREF entries already set dq_oe = 0 above and we don't
            // touch dq_oe in clock-suspend (the burst engine's held value
            // persists). So this branch leaves dq_oe alone.
            cke_prev <= Cke;
            disable main_proc;
        end

        mature_read_pipe();   // LOCAL FIX
        if (burst.active && burst.is_read) begin
            advance_read_burst();
        end else begin
            // Stay Hi-Z when no read burst is active: tHZ_MAX delay matches
            // the read-end Hi-Z transition above.
            dq_oe <= #(tHZ_MAX) 1'b0;
        end

        if (DEBUG && cmd != CMD_NOP && cmd != CMD_DESL) begin
            $display("%0t %s CMD=%s BA=%0d ADDR=%04h DQM=%b%b CS#=%b",
                     $time,
                     CHIP_NAME,
                     cmd_name(cmd),
                     bank,
                     Addr,
                     Udqm,
                     Ldqm,
                     Cs_n);
        end

        check_init_before_normal_cmd(cmd);

        // LOCAL FIX 5: tMRD from a MODE REGISTER SET to ANY following command.
        if ((cmd != CMD_NOP) && (cmd != CMD_DESL) && (cmd != CMD_MRS)) begin
            check_time_min("tMRD MRS-to-command", last_mrs, tMRD_MIN);
        end

        unique case (cmd)
            CMD_DESL,
            CMD_NOP: begin
                if (burst.active && burst.is_write) begin
                    consume_write_data();
                end
            end

            CMD_ACT: begin
                if (burst.active && burst.is_write) begin
                    issue_warn("ACT issued while write burst active; terminating write burst");
                    cut_burst();
                end

                do_activate(bank, row);
            end

            CMD_READ: begin
                do_read(bank, col, auto_precharge);
            end

            CMD_WRIT: begin
                do_write(bank, col, auto_precharge);
            end

            CMD_PRE: begin
                if (burst.active) begin
                    cut_burst();
                end

                do_precharge(
                    bank,
                    precharge_all,
                    precharge_all ? "command all" : "command"
                );

                if (precharge_all) begin
                    init_seen_precharge_all = 1'b1;
                end
            end

            CMD_AREF: begin
                cut_burst();
                do_auto_refresh();
            end

            CMD_MRS: begin
                if (!all_banks_idle()) begin
                    issue_error("MRS while one or more banks active");
                end

                check_time_min("tMRD MRS-to-MRS/command",
                               last_mrs,
                               tMRD_MIN);

                // LOCAL FIX 7: every bank's precharge has completed (tRP) before the MRS.
                for (int i = 0; i < BANKS; i++) begin
                    check_time_min($sformatf("tRP bank %0d PRE-to-MRS", i),
                                   last_precharge[i],
                                   tRP_MIN);
                end

                load_mode_register(Addr);
                last_mrs      = $realtime;
                init_seen_mrs = 1'b1;
            end

            CMD_BST: begin
                do_burst_stop();
            end

            CMD_SREF: begin
                if (!all_banks_idle()) begin
                    issue_error("SELF REFRESH command while banks active");
                end

                in_self_refresh = 1'b1;
                cut_burst();
            end

            default: begin
                issue_warn($sformatf("unhandled command %0d", cmd));
            end
        endcase

        for (int i = 0; i < BANKS; i++) begin
            if (bank_open[i]) begin
                if (($realtime - last_activate[i]) > tRAS_MAX) begin
                    issue_error($sformatf("tRAS(max) violation bank %0d active for %0.3f ns max=%0.3f ns",
                                          i,
                                          $realtime - last_activate[i],
                                          tRAS_MAX));
                end
            end
        end

        cke_prev <= Cke;
    end

    // -------------------------------------------------------------------------
    // Testbench helper tasks
    // -------------------------------------------------------------------------

    task automatic clear_memory();
        begin
            mem.delete();
        end
    endtask

    task automatic poke(
        input int unsigned bank,
        input int unsigned row,
        input int unsigned col,
        input data_t value
    );
        begin
            mem[make_key(bank, row, col)] = value;
        end
    endtask

    task automatic peek(
        input int unsigned bank,
        input int unsigned row,
        input int unsigned col,
        output data_t value
    );
        begin
            value = mem_read(bank, row, col);
        end
    endtask

    // Sparse snapshot format: "<key_hex> <data_hex>" per line.
    //   key  = 7 hex digits = {bank[1:0], row[12:0], col[9:0]} (25 bits)
    //   data = 4 hex digits (16 bits)
    // Lines whose first two tokens don't match this layout are skipped, so
    // "//" or "#" comment lines and blank lines pass through harmlessly.
    task automatic dump_memory(input string filename);
        int       fd;
        mem_key_t k;
        int unsigned count;
        begin
            fd = $fopen(filename, "w");
            if (fd == 0) begin
                $error("%s: dump_memory failed to open '%s' for write",
                       CHIP_NAME, filename);
                return;
            end

            $fdisplay(fd, "// %s memory dump @ %0t", CHIP_NAME, $time);
            count = 0;
            if (mem.first(k) != 0) begin
                do begin
                    $fdisplay(fd, "%07h %04h", k, mem[k]);
                    count++;
                end while (mem.next(k) != 0);
            end
            $fclose(fd);

            if (DEBUG) begin
                $display("%0t %s dumped %0d entries to '%s'",
                         $time, CHIP_NAME, count, filename);
            end
        end
    endtask

    task automatic load_memory(input string filename);
        int       fd;
        int       code;
        string    line;
        mem_key_t key;
        data_t    value;
        int unsigned loaded;
        begin
            fd = $fopen(filename, "r");
            if (fd == 0) begin
                $error("%s: load_memory failed to open '%s' for read",
                       CHIP_NAME, filename);
                return;
            end

            loaded = 0;
            while ($fgets(line, fd) != 0) begin
                code = $sscanf(line, "%h %h", key, value);
                if (code == 2) begin
                    mem[key] = value;
                    loaded++;
                end
            end
            $fclose(fd);

            if (DEBUG) begin
                $display("%0t %s loaded %0d entries from '%s'",
                         $time, CHIP_NAME, loaded, filename);
            end
        end
    endtask

    // Load a contiguous ROM image into this chip starting at `word_base`,
    // one 16-bit value per non-blank/non-comment line of `filename` (the
    // standard $readmemh-style format, minus the @address syntax). word_base
    // is a chip-local 25-bit word address: bits [24:23]=bank, [22:10]=row,
    // [9:0]=col, matching make_key().
    task automatic load_rom_hex(input string filename, input int unsigned word_base);
        int          fd;
        string       line;
        data_t       value;
        logic [24:0] word_idx;
        int unsigned loaded;
        begin
            fd = $fopen(filename, "r");
            if (fd == 0) begin
                $error("%s: load_rom_hex failed to open '%s' for read",
                       CHIP_NAME, filename);
                return;
            end

            word_idx = word_base[24:0];
            loaded   = 0;

            while ($fgets(line, fd) != 0) begin
                if ($sscanf(line, "%h", value) == 1) begin
                    if ((word_base + loaded) >= (1 << 25)) begin
                        $error("%s: load_rom_hex word %0d overflows chip (32M words)",
                               CHIP_NAME, word_base + loaded);
                        break;
                    end
                    mem[mem_key_t'(word_idx)] = value;
                    word_idx++;
                    loaded++;
                end
            end
            $fclose(fd);

            if (DEBUG) begin
                $display("%0t %s load_rom_hex loaded %0d words from '%s' (word_base=%0d)",
                         $time, CHIP_NAME, loaded, filename, word_base);
            end
        end
    endtask

    // Post-mortem state dump. Prints every piece of chip state a controller
    // bug might depend on: counters, mode register, per-bank activity, the
    // current burst, power-management flags, init-checker progress, and a
    // one-line refresh summary. Cheap to call repeatedly during a failing
    // test or once at end-of-test.
    task automatic dump_state();
        int i;
        begin
            $display("===== %s state @ %0t =====", CHIP_NAME, $time);
            $display("  counters: errors=%0d warnings=%0d",
                     error_count, warning_count);
            $display("  mode reg: BL=%0d full_page=%0b BT=%s CL=%0d WBL=%s",
                     burst_length,
                     burst_full_page,
                     burst_interleaved ? "interleaved" : "sequential",
                     cas_latency,
                     write_burst_single ? "single" : "burst");
            $display("  power:    pd=%0b sref=%0b clk_susp=%0b",
                     in_power_down, in_self_refresh, in_clock_suspend);
            $display("  init:     cke_high=%0b pre_all=%0b mrs=%0b aref_count=%0d",
                     init_seen_cke_high,
                     init_seen_precharge_all,
                     init_seen_mrs,
                     init_auto_refresh_count);
            $display("  refresh:  queued=%0d / %0d last_refresh=%0.3f ns",
                     refresh_times.size(), REFRESHES_PER_WINDOW, last_refresh);

            for (i = 0; i < BANKS; i++) begin
                $display("  bank %0d:   open=%0b row=%0d last_act=%0.3f last_rd=%0.3f last_wr=%0.3f last_pre=%0.3f",
                         i,
                         bank_open[i],
                         open_row[i],
                         last_activate[i],
                         last_read[i],
                         last_write[i],
                         last_precharge[i]);
            end

            if (burst.active) begin
                $display("  burst:    %s bank=%0d row=%0d start_col=%0d idx=%0d len=%0d lat=%0d ap=%0b full=%0b il=%0b",
                         burst.is_read ? "READ" : (burst.is_write ? "WRITE" : "?"),
                         burst.bank,
                         burst.row,
                         burst.start_col,
                         burst.index,
                         burst.len,
                         burst.latency,
                         burst.auto_precharge,
                         burst.full_page,
                         burst.interleaved);
            end else begin
                $display("  burst:    idle");
            end
        end
    endtask

    task automatic report_refresh_status();
        begin
            $display("%0t %s REFRESH_STATUS count=%0d last_refresh=%0.3f ns",
                     $time,
                     CHIP_NAME,
                     refresh_times.size(),
                     last_refresh);

            if (refresh_times.size() == REFRESHES_PER_WINDOW) begin
                $display("%0t %s REFRESH_WINDOW span=%0.3f ns limit=%0.3f ns",
                         $time,
                         CHIP_NAME,
                         refresh_times[refresh_times.size()-1] - refresh_times[0],
                         tREF_WINDOW);
            end
        end
    endtask

endmodule
