// The device-bus chip selects, decoded once: a pure function of the 16-bit port address, giving
// the selects pc9821_system routes on. It exists because the same decode was written twice - in
// pc9821_system and inside pc9821_interrupts - and because a module is the only shape
// a bench can sweep exhaustively over all 65,536 port addresses.
// The SHAPES matter as much as the duplication: a range test costs a carry chain, while the alias
// this core supports is a high-bit equality. Sparse devices decode as exact addresses.
`default_nettype none

module pc9821_device_select #(
    // Whether the MPU-PC98II exists (z486_mister.sv's MPU_EN). A parameter rather than a pin,
    // because it is a build-profile constant: with MPU_EN 0 `mpu_cs` is a constant 0 and
    // `gdc_cs` is the complement of exactly the list it had before the card existed.
    parameter MPU_EN = 1'b0,
    // Whether the run-time SDRAM_CLK phase instrument exists (z486_mister.sv's SDRAM_PHASE_DYN, a
    // TEST-ONLY build: build_profile.py --dbg-sdram-phase, off in every preset). With 0 `sdph_cs`
    // is a constant 0 and every other output is exactly what it was.
    parameter SDRAM_PHASE_DYN = 1'b0,
    // Whether a PC-9801-118's game port answers 0x1480-0x1487. The Xe10 has no -118 (its
    // sound is the -86-class OPNA, whose joystick register 0x0E is the machine's own stick
    // path, docs/probes/JOY.TXT), and NP2kai attaches the port only with that board
    // (cbus/board118.c `iocore_attachinp(0x1480+i, gameport_i1480);`), so the Xe10 reads open
    // bus there: 0, the default, makes `gameport_cs` a constant 0. 1 builds the -118 model.
    parameter GAMEPORT_118 = 1'b0
) (
    input  [15:0] addr,

    output wire pic_master_cs,   // 0x0000/0x0002, the master 8259
    output wire pic_slave_cs,    // 0x0008/0x000A, the slave 8259
    output wire pit_cs,          // 0x71/73/75/77 and 0x3FD9/DB/DD/DF
    output wire interrupt_cs,    // the 8259 pair and the PIT together
      // The calendar sits on the device bus, so it gets a real chip select and a real 4-bit decode.
    output wire cal_cs,          // 0x0020/0x0022/0x0128, the uPD4990
    output wire kbd_cs,          // 0x0041/0x0043, the uPD8251
    output wire ata_cs,          // the IDE connection ports and task file
      // The PC-9801-86's OPNA: the base pair and the extension pair the card adds. Both are decoded
      // because the card answers at both.
    output wire opna_cs,         // 0x0188/0x018A/0x018C/0x018E
      // The same board's OTHER device, the 86-PCM block: sparse, with nothing between its registers,
      // so it decodes as exact addresses rather than a range.
    output wire pcm_cs,          // 0x0A462/64/66/68/6A/6C/6E, the even ports
      // The PC-9801-118's game port, 0x1480-0x1487. The card answers all eight addresses and
      // does not distinguish them (NP2kai cbus/board118.c:816-822), so the claim is one range.
    output wire gameport_cs,
      // The Roland MPU-PC98II's two ports, 0xE0D0 (data) and 0xE0D2 (status/command). NP2kai
      // attaches the standalone card at `port` and `port | 2` (cbus/mpu98ii.c:1177-1179), which
      // is why the pair is +0/+2 and not +0/+1 (the PC-9801-118's variant is the +0/+1 pair).
      // MPU_EN 0 (the base build) leaves the decode exactly as it was: the card's two
      // addresses stay on the GDC's complement and the select never asserts.
    output wire mpu_cs,
      // The SDRAM phase instrument's two ports, 0x5FF0 (command/status) and 0x5FF2 (offset)
      // (pc9821_sdram_phase_ctl.sv). Neither is named by NP2kai's or MAME's PC-9821 port map and
      // nothing else here decodes them; the pair is chosen by this core, for its own test build.
    output wire sdph_cs,
      // THE DEVICE-BUS CLAIM: the set of ports that belong to the device bus at all, as opposed
      // to the CPU-local "system" ports pc9821_iobus decodes itself. This is the ONE place the
      // claim is written, so a port cannot be claimed in one list and unreachable in another
      // (for example the odd task-file lanes 0x643.. that ata_cs claims). The claim is a product
      // of the same decode that produces the selects: every chip select below is a bus port, and
      // the ports that reach their chip through `gdc_cs` rather than a select of their own (the
      // 8253 window's even lanes, which are the text CRTC's registers; the CRTC window; the CG
      // window) are the explicit sub-selects.
      // tb_pc9821_device_select sweeps all 65,536 ports against a recorded 85-port list.
    output wire dev_bus_cs,
    output wire gdc_cs           // everything else on the device bus
);
    assign pic_master_cs = (addr == 16'h0000) || (addr == 16'h0002);
    assign pic_slave_cs = (addr == 16'h0008) || (addr == 16'h000A);
    assign pit_cs = ((addr[15:3] == 13'h000E) || (addr[15:3] == 13'h07FB)) && addr[0];
    assign interrupt_cs = pic_master_cs || pic_slave_cs || pit_cs;
    assign cal_cs = (addr == 16'h0020) || (addr == 16'h0022) || (addr == 16'h0128);
    assign kbd_cs = (addr == 16'h0041) || (addr == 16'h0043);
      // The ATA task file is 0x0640-0x064E - one high-bit equality plus a low-bit range - so it is
      // cheap and it is the shape the alternate status port 0x074C shares.
    assign ata_cs = (addr == 16'h0430) || (addr == 16'h0432) ||
                    (addr == 16'h0433) || (addr == 16'h0435) ||
                    ((addr[15:4] == 12'h064) && (addr[3:0] != 4'hF)) ||
                    ((addr[15:4] == 12'h074) && (addr[3:0] != 4'hF));
    assign opna_cs = (addr == 16'h0188) || (addr == 16'h018A) ||
                     (addr == 16'h018C) || (addr == 16'h018E);
      // Every 86-PCM register is an exact address; the gaps between them answer nothing, which is
      // what the card does.
    assign pcm_cs = (addr == 16'h0A462) || (addr == 16'h0A464) ||
                    (addr == 16'h0A466) || (addr == 16'h0A468) ||
                    (addr == 16'h0A46A) || (addr == 16'h0A46C) ||
                    (addr == 16'h0A46E);
      // One high-bit equality covers the card's eight addresses: 0x1480-0x1487.
    assign gameport_cs = GAMEPORT_118 && (addr[15:3] == 13'h0290);
      // The MPU-PC98II's two exact addresses, and only when the build has the card. MAME's
      // PC-9821 map lists the whole four-byte window 0xE0D0-0xE0D3 (as `<undefined>`,
      // pc9821.cpp:768), but NP2kai attaches two ports, and that divergence
      // is recorded here: 0xE0D1/0xE0D3 stay undecoded here.
    assign mpu_cs = MPU_EN && ((addr == 16'hE0D0) || (addr == 16'hE0D2));
    assign sdph_cs = SDRAM_PHASE_DYN && ((addr == 16'h5FF0) || (addr == 16'h5FF2));
    assign gdc_cs = !(interrupt_cs || kbd_cs || ata_cs || cal_cs || opna_cs || pcm_cs ||
                      gameport_cs || mpu_cs || sdph_cs);

      // THE DEVICE-BUS SUB-SELECTS: the ports the bus presents to no chip select (they are the
      // GDC bucket's, `gdc_cs` below, which is deliberately UNCHANGED - the CRTC/GDC/CG/GRCG all
      // take `device_io_wr && gdc_cs` plus their own register code). They are here only so the
      // claim can be a sum of decodes instead of a second hand-kept list.
    wire gdc_text_cs, pit_window_cs, grcg_cs, cg_cs, ata_bus_cs;
      // 0x0060-0x006E: exactly the ports pc9821_crtc's port_code decodes there - the text GDC's
      // parameter and command ports, the VSYNC arm, both MODE FF registers and 0x6E. The even
      // lanes only: a word OUT to the GDC's pair reaches its odd half through the lane walk's
      // own address, not as a separate device port (0x66 is decoded by nothing; 0x6C is a
      // system port, pc9821_iobus's HX_006C latch).
    assign gdc_text_cs = (addr[15:8] == 8'h00) && (addr[7:4] == 4'h6) && !addr[0] &&
                         (addr[3:1] != 3'b011) && (addr[3:1] != 3'b110);
      // 0x0070-0x0077: the 8253 window. pit_cs above is the chip's own (odd) select; the even
      // lanes 0x70/0x72/0x74/0x76 are the text CRTC's PL/BL/CL/SSL registers (pc9821_crtc's
      // port_code 6-9, `8'h70:   port_code = 5'd6;`), which reach it through `gdc_cs`.
    assign pit_window_cs = (addr[15:3] == 13'h000E) && !addr[0];
      // 0x0078-0x007E even: the GRCG's two registers (0x7C/0x7E) and their 0x78/0x7A partners,
      // the same code pc9821_crtc's port_code decodes.
    assign grcg_cs = (addr[15:3] == 13'h000F) && !addr[0];
      // 0xA0-0xA6 EVERY LANE (the CG/graphics word ports: 0xA0/0xA2 are pc9821_gdc2's and
      // 0xA1/0xA3/0xA5/0xA9 pc9821_cg's, so the pairs are word-accessible), then 0xA8-0xAE's
      // even page registers plus 0xA9. 0xAB/0xAD/0xAF are decoded by nothing: they are not bus
      // ports on the machine and stay off it.
    assign cg_cs = (addr[15:4] == 12'h000A) &&
                   ((addr[3:0] <= 4'h6) || !addr[0] || (addr[3:0] == 4'h9));
      // THE IDE BUS PORTS ARE ata_cs MINUS THE LANES THE BUS NEVER STROKES. ata_cs's range
      // shape covers every task-file address (0x640-0x64E, 0x740-0x74E); the bus presents only
      // the even lanes plus 0x641 (the first file's odd partner), which is what the machine's
      // own device list holds. The mask is a subtraction from ata_cs, not a second decode, so
      // the two cannot disagree about the four 0x043x ports the card also lives at.
    assign ata_bus_cs = ata_cs &&
                        !(addr[0] && (addr[15:4] == 12'h064) && (addr[3:1] != 3'b000)) &&
                        !(addr[0] && (addr[15:4] == 12'h074));
      // The claim: the 8259 pair and the PIT, then every device above, then the three sub-selects.
      // interrupt_cs covers pic_master_cs/pic_slave_cs/pit_cs; every other member is disjoint
      // from every other (the bench asserts the leaf selects are one-hot).
    assign dev_bus_cs = interrupt_cs || kbd_cs || cal_cs || ata_bus_cs || opna_cs || pcm_cs ||
                        gameport_cs || mpu_cs || sdph_cs || gdc_text_cs || pit_window_cs ||
                        grcg_cs || cg_cs;
endmodule

`default_nettype wire
