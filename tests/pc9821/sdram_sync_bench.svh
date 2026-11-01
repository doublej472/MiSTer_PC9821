// The SDRAM bench clock, for a bench that drives sdram_sync_bridge directly.
//
// The SDRAM controller runs on clk_sys in every build (the split-clock configuration and its
// clock-domain bridge were removed on 2026-10-09), so a
// bridge bench clocks the controller AND its device model from its own clk_sys. The benches that
// include this file run clk_sys at 50 MHz (a `--custom --clk-sys-mhz 50` build; the shipped build
// is 90 MHz, which tb_pc9821_sdram_sync and tb_pc9821_sdram_bw run), so the controller is a 50 MHz
// one and the device model's tRP/tWR are sdram.v's own derivation there (ceil(20 ns)/ceil(15 ns)
// at 20 ns = 1 cycle each).
`ifndef SDRAM_SYNC_BENCH_SVH
`define SDRAM_SYNC_BENCH_SVH
  `define TB_SDRAM_FREQ     50_000_000
  `define TB_SDRAM_CYCLE_NS 20       // a bench's controller-clock pin monitors run at clk_sys
  `define TB_CHIP_TRP       1
  `define TB_CHIP_TWR       1
`endif
