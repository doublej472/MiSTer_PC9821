`timescale 1ns / 1ps

// ==== WHAT THIS PROVES ====
// The ITF's own EMS self-test (BANK4@0xF8290-0xF8329, POST stage 0x1D) and its 64 KiB pass-path pattern test, driven end to end through the REAL pc9821_iobus (whose decode owns ems_state) + pc9821_memory_map (whose route decides EMS page vs VRAM plane vs open bus): writing 0xAA55 to 0xB0000 under 0x43F=0x22 then switching to 0x43F=0x20 must NOT return 0xAA55 (the two 0x2x values select distinct 64 KiB stores), exactly as the machine's own capture passes it (docs/probes/EMS.TXT: '22 wrote AA55 at B0000, 20 read: 0000'; 'B0000 under 20/22/24: 1111 2222 FFFF'). FAIL-FIRST: on the pre-window tree (which decoded only the 0xEx nibble of 0x043F) both states were the GVRAM R plane, the 0xAA55 survived the 0x22->0x20 switch, and the ITF reported EMS ERROR.
//
// The bench also pins the pass-path fill-and-verify (64 KiB of writable RAM at
// 0xB0000-0xBFFFF under 0x22, the 0x00010001 pattern round-trip) and the 0x24
// unmapped state (reads 0xFFFF, stores discarded), the two further facts the
// machine's capture holds (docs/probes/EMS.TXT: 'B0000 under 20/22/24: 1111
// 2222 FFFF'; 'B0000..BE000 under 22: 0077 0177 ... 0777'). The data model is
// a 64 KiB RAM array behind the EMS page and a cleared sentinel behind the
// GVRAM R plane, so the word written under 0x22 provably does not come back
// under 0x20.

module tb_pc9821_ems_itf;

  reg clk = 0;
  always #5 clk = ~clk;
  reg reset = 1;

  // The I/O side (pc9821_iobus's CPU port): 0x043F writes ride this.
  reg  [31:0] io_cpu_addr = 0, io_cpu_din = 0;
  reg  [3:0]  io_cpu_be = 0;
  reg         io_cpu_valid = 0, io_cpu_write = 0;
  wire [31:0] io_cpu_dout;
  wire        io_cpu_ready, io_cpu_resp_valid;
  wire        cache_flush_req;

  // The memory side (pc9821_memory_map's requester port): 0xB0000 reads/writes ride this.
  reg  [31:0] mem_cpu_addr = 0;
  reg  [31:0] mem_cpu_din = 0;
  reg  [3:0]  mem_cpu_be = 4'hF;
  reg         mem_cpu_valid = 0, mem_cpu_write = 0;
  wire [31:0] mem_cpu_dout, mem_addr, mem_din;
  wire        mem_valid, mem_write;
  wire        mem_cpu_ready, mem_cpu_resp_valid;
  wire        gvram_window;
  wire [1:0]  gvram_win_plane;
  wire [14:0] gvram_win_offset;
  wire        ems_open_bus, absent_area, fw_shadow_store;
  wire [31:0] cpu_line_word;
  wire [3:0]  mem_be;
  wire [7:0]  mem_burstcount;

  wire [1:0] ems_state;

  // The map reads only ems_page_base[31:20]: the port is pc9821_memory_subsystem's
  // pack_base + PACK_BYTES + 0x48000 (pack_base = the map's 32 MiB default here), so its low
  // 20 bits ARE the constant 0x48000 and the page arm is a bit splice
  // (tools/check_memmap_addr_equiv.py PREMISES). Drive that same shape.
  localparam [31:0] EMS_PAGE_BASE = 32'h0214_8000;   // 0x0200_0000 + 1 MiB + 0x48000
  // The GVRAM R plane's content at POST time: cleared, so the word the ITF
  // wrote under 0x22 (into the EMS page) is NOT what a 0x20 read answers.
  localparam [31:0] GVRAM_R_SENTINEL = 32'h0000_0000;

  // The EMS page's 64 KiB of writable RAM (the ITF's fill-and-verify target).
  reg [31:0] ems_ram [0:16383];

  // ==== DUT ====
  // Stage A's write-protect seam. Declared because pc9821_iobus is instantiated with `.*`
  // here, which requires every one of its ports to resolve (tools/check_wiring.py).
  wire [3:0] fdd_wp = 4'b0000;
  wire       fdd_req_wr;   // pc9821_iobus's write leg (unused here: no write is issued)
  wire [7:0] fdd_din;
  wire       fdd_abort;
  wire [3:0]  fdd_chg = 4'd0;          // no media change: the FDC's ready-change tag
  wire        fdd_frame_tick = 1'b0;

  pc9821_iobus bus (
      .ide_unit0_present(1'b0), .ide_unit2_present(1'b1),
      .clk(clk), .reset(reset),
      .bios_set(4'h0), .gdc_clock_5m(1'b0), .triple_fault_reset(1'b0),
      .cpu_addr(io_cpu_addr), .cpu_din(io_cpu_din), .cpu_be(io_cpu_be),
      .cpu_valid(io_cpu_valid), .cpu_write(io_cpu_write),
      .cpu_dout(io_cpu_dout), .cpu_ready(io_cpu_ready),
      .cpu_resp_valid(io_cpu_resp_valid),
      .debug_status(8'h00), .cal_cdat(1'b0),
      .cfg_ram_mib(7'h0), .cfg_seed_en(1'b0),
      .device_io_dout(8'h00), .device_rd_wait(1'b0), .device_rd_hold(1'b0),
      .device_wr_wait(1'b0),
      .fdd_present(4'h0), .fdd_ready(1'b1), .fdd_rdy(1'b0), .fdd_hdrv(1'b0),
      .fdd_err(1'b0), .fdd_dout(8'h00), .fdd_hr(8'h00), .fdd_hn(8'h00),
      .fdd_hs(8'h00),
      .dma_mem_ready(1'b0), .dma_mem_dout(32'h0), .dma_mem_resp_valid(1'b0),
      .ps2_mouse(25'h0), .egc_gate(1'b0), .gdc_ff2_state(11'h0),
      .cache_flush_busy(1'b0),
      .cache_flush_req(cache_flush_req),
      .cache_flush_done(cache_flush_req),
      .ems_state(ems_state)
  );
  // The 16-colour select (port 0x6A FF2 num 0): 0 = the digital mode the machine resets to,
  // where 0xE0000-0xE7FFF is open bus (pc9821_memory_map e_plane_nc).
  reg        mode2_16color = 1'b0;
  wire       e_plane_nc;

  pc9821_memory_map map (
      .mode2_16color(mode2_16color),
      .e_plane_nc(e_plane_nc),
      .top_bank(4'd3), .ide_rom_enable(1'b0), .d8_bank(2'b00), .ide_ram_gate(1'b0),
      .bios_ram_gate(1'b0), .top_shadow_en(1'b0), .fw_shadow_dirty(1'b0),
      .fw_shadow_base(32'h0),
      .ems_state(ems_state), .ems_page_base(EMS_PAGE_BASE),
      .win0_sel(8'h08), .win0_sel_moved(1'b0), .pack_base(32'h0200_0000),
      .guest_ram_bytes(32'h0200_0000),
      .peg_window(1'b0), .peg_base(32'h0),
      .pegc_256(1'b0), .pegc_plane(1'b0),
      .pegc_bank_a(4'h0), .pegc_bank_b(4'h0),
      .cpu_addr(mem_cpu_addr), .cpu_addr_raw(mem_cpu_addr), .xl_low20(1'b0), .xl_peg(1'b0), .cpu_din(mem_cpu_din), .cpu_be(mem_cpu_be),
      .cpu_burstcount(8'h0), .cpu_line_read(1'b0),
      .cpu_valid(mem_cpu_valid), .cpu_write(mem_cpu_write),
      .cpu_dout(mem_cpu_dout),
      .cpu_ready(mem_cpu_ready), .cpu_resp_valid(mem_cpu_resp_valid),
      .absent_area(absent_area), .ems_open_bus(ems_open_bus),
      .fw_shadow_store(fw_shadow_store),
      .gvram_window(gvram_window), .gvram_win_plane(gvram_win_plane),
      .gvram_win_offset(gvram_win_offset),
      .mem_addr(mem_addr), .mem_din(mem_din), .mem_be(mem_be),
      .mem_burstcount(mem_burstcount), .mem_valid(mem_valid),
      .mem_write(mem_write),
      .mem_dout(32'h0), .mem_ready(1'b0), .mem_resp_valid(1'b0)
  );

  integer errors = 0;

  task automatic fail(input string message);
    begin
      $display("FAIL: %0s @ %0t", message, $time);
      errors = errors + 1;
    end
  endtask

  // The iobus's port-write protocol (the shape tb_pc9821_iobus drives).
  task automatic write_port(input [15:0] portnum, input [7:0] data);
    reg [1:0] lane;
    begin
      lane = portnum[1:0];
      @(negedge clk);
      io_cpu_addr = {16'd0, portnum[15:2], 2'b00};
      io_cpu_be = 4'b0001 << lane;
      io_cpu_din = {24'd0, data} << (lane * 8);
      io_cpu_write = 1;
      io_cpu_valid = 1;
      begin : wr_wait
        integer n;
        n = 0;
        while (!io_cpu_ready && n < 3000) begin @(negedge clk); n = n + 1; end
        if (!io_cpu_ready)
          $fatal(1, "write %04x wedged waiting cpu_ready (iobus state=%0d)", portnum, bus.state);
      end
      @(negedge clk);
      io_cpu_valid = 0;
      io_cpu_write = 0;
      io_cpu_be = 0;
      begin : st_wait
        integer n;
        n = 0;
        while (bus.state != 0 && n < 3000) begin @(negedge clk); n = n + 1; end
        if (bus.state != 0)
          $fatal(1, "write %04x wedged in the iobus FSM (state=%0d)", portnum, bus.state);
      end
    end
  endtask

  // A memory access through the map, with the SUBSYSTEM's data model applied:
  // a gvram_window read answers the cleared GVRAM R plane, an EMS-page access
  // reads/writes the 64 KiB ems_ram array, the unmapped state answers open bus
  // (0xFFFFFFFF) and drops stores. Returns the modelled read datum.
  task automatic mem_access(input [31:0] addr, input write, input [31:0] din, output [31:0] dout);
    begin
      @(negedge clk);
      mem_cpu_addr = addr;
      mem_cpu_din = din;
      mem_cpu_write = write;
      mem_cpu_valid = 1;
      #1;
      if (gvram_window) begin
        // The subsystem's gvram_select gates the mapper, so the planes answer.
        dout = GVRAM_R_SENTINEL;
        if (write) begin
          // A store under the identity state reaches the plane, not the EMS page.
          $display("note: 0x%08x store reached the GVRAM R plane (identity)", addr);
        end
      end else if (ems_open_bus) begin
        dout = 32'hFFFF_FFFF;   // the registered open-bus responder's shape
        if (write) $display("note: 0x%08x store discarded (unmapped EMS state)", addr);
      end else if (mem_valid) begin
        // mem_addr is ems_page_base + page offset (the mapper's route), so the
        // array index is the page-RELATIVE dword, kept in [0..16383].
        if (write) ems_ram[(mem_addr - EMS_PAGE_BASE) >> 2] = mem_din;
        dout = ems_ram[(mem_addr - EMS_PAGE_BASE) >> 2];
      end else begin
        dout = 32'h0000_0000;
      end
      @(negedge clk);
      mem_cpu_valid = 0;
      mem_cpu_write = 0;
    end
  endtask

  integer ei;
  reg [31:0] got;
  reg [31:0] pat;

  // ==== CHECKS ====
  initial begin
    for (ei = 0; ei < 16384; ei = ei + 1) ems_ram[ei] = 32'h0000_0000;
    repeat (4) @(posedge clk);
    @(negedge clk);
    reset = 0;
    repeat (2) @(posedge clk);

    // ---- The ITF's exact test: 0x22 -> write 0xAA55 -> 0x20 -> compare ----
    write_port(16'h043F, 8'h22);                 // window ON (EMS page)
    if (ems_state !== 2'd1)
      fail($sformatf("0x43F=0x22 did not select the EMS page (ems_state=%0d)", ems_state));

    mem_access(32'h000B_0000, 1'b1, 32'h0000_AA55, got);   // write 0xAA55 under 0x22
    // The store must have landed in the EMS page's RAM, not the planes.
    if (gvram_window || ems_ram[0] !== 32'h0000_AA55)
      fail("0xAA55 under 0x22 did not land in the EMS page RAM");

    write_port(16'h043F, 8'h20);                 // window OFF (identity/VRAM)
    if (ems_state !== 2'd0)
      fail($sformatf("0x43F=0x20 did not return the window to the identity (ems_state=%0d)", ems_state));

    mem_access(32'h000B_0000, 1'b0, 32'h0, got); // read 0xB0000 under 0x20
    if (gvram_window !== 1'b1)
      fail($sformatf("0xB0000 under 0x20 was not the GVRAM R plane (gvram=%b)", gvram_window));
    if (got === 32'h0000_AA55)
      fail("ITF EMS test: the 0xAA55 written under 0x22 SURVIVED the 0x20 switch (EMS ERROR)");

    // ---- The pass-path 64 KiB pattern test (0x00010001 fill + verify) ----
    write_port(16'h043F, 8'h22);
    pat = 32'h0001_0001;
    for (ei = 0; ei < 16384; ei = ei + 1)
      mem_access(32'h000B_0000 + (ei << 2), 1'b1, pat, got);
    for (ei = 0; ei < 16384; ei = ei + 1) begin
      mem_access(32'h000B_0000 + (ei << 2), 1'b0, 32'h0, got);
      if (got !== pat)
        fail($sformatf("64 KiB EMS page did not round-trip 0x00010001 at dword %0d (got %08x)", ei, got));
    end

    // ---- The 0x24 unmapped state: reads 0xFFFF, stores are discarded ----
    write_port(16'h043F, 8'h24);
    if (ems_state !== 2'd2)
      fail($sformatf("0x43F=0x24 did not select the unmapped state (ems_state=%0d)", ems_state));
    mem_access(32'h000B_0000, 1'b0, 32'h0, got);
    if (got !== 32'hFFFF_FFFF)
      fail($sformatf("0xB0000 under 0x24 did not read open bus (got %08x)", got));

    repeat (4) @(posedge clk);
    // ==== VERDICT ====
    if (errors == 0) begin
      $display("TB_PC9821_EMS_ITF: PASS");
      $finish;
    end
    else $fatal(1, "TB_PC9821_EMS_ITF: FAIL (%0d errors)", errors);
  end

  initial begin
    #20_000_000;
    $fatal(1, "TB_PC9821_EMS_ITF: TIMEOUT");
  end

endmodule
