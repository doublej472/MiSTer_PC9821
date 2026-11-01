#!/usr/bin/env bash
# Shared ordered source list for Verilator full-system PC-9821 benches.
# The caller must run from the repository root.
#
# src/z486 is vendored with the local patch already applied.
Z=src/z486
X=$Z/x87
PC9821_Z486_RTL=(
  "$Z/z486_pkg.sv" "$Z/z486_cache_map_pkg.sv" "$X/x87_pkg.sv" "$X/x87_ucode_pkg.sv"
  "$Z/ucode_rom.sv" "$Z/microsequencer.sv" "$Z/hardwired_control.sv"
  "$Z/cpu_throttle.sv" "$Z/interrupt_controller.sv"
  "$Z/data_unit.sv" "$Z/gpr_write_merge.sv" "$Z/address_unit.sv" "$Z/shifter.sv"
  "$Z/mul_div.sv" "$Z/decoder.sv" "$Z/alu.sv" "$Z/alu_alt.sv" "$Z/prefetch.sv"
  "$Z/paging_unit.sv" "$Z/paging_tlb.sv" "$Z/paging_walker.sv"
  "$Z/memory.sv" "$Z/cache_unit.sv" "$Z/bus_unit.sv" "$Z/l1_cache.sv" "$Z/l1_icache.sv"
  "$X/x87_bridge.sv" "$X/x87_cordic_rom.sv" "$X/x87_cordic_scratch.sv"
  "$X/x87_ucode_rom.sv" "$X/x87_sequencer.sv" "$X/x87_executor.sv"
  "$X/x87_transfer_fifo.sv" "$X/x87_stack_mem.sv"
  "$X/x87_command_rom.sv" "$X/x87_control.sv" "$X/x87_unit.sv"
  "$Z/dsp_mul.sv" "$Z/protection.sv" "$Z/segmentation_unit.sv"
  "$Z/data_access.sv" "$Z/event_control.sv" "$Z/z486.sv"
  src/pc9821/storage/pc9821_ata.sv src/pc9821/storage/pc9821_atapi.sv
  src/pc9821/storage/pc9821_block_io.sv
  src/pc9821/storage/pc9821_block_share.sv
  src/pc9821/storage/pc9821_hdd_image.sv
  src/pc9821/storage/pc9821_hps_slot_demux.sv
  src/pc9821/storage/pc9821_fdc.sv src/pc9821/storage/pc9821_fdd_media.sv
  src/pc9821/common/pc9821_dpram.sv
  src/pc9821/video/pc9821_crtc.sv src/pc9821/core/pc9821_text_mem.sv src/pc9821/video/pc9821_gdc2.sv
  src/pc9821/video/pc9821_cg.sv src/pc9821/video/pc9821_grcg.sv
  src/pc9821/video/pc9821_egc_mem_gate.sv
  src/pc9821/video/pc9821_plane_fold.sv src/pc9821/video/pc9821_gfx_palette.sv
  src/pc9821/video/pc9821_video_mixer.sv
  src/pc9821/video/pc9821_vclk_pkg.sv src/pc9821/video/pc9821_dot_ce.sv
  src/pc9821/interrupts/pc9821_inta_bridge.sv
  src/pc9821/interrupts/pc9821_interrupts.sv src/pc9821/core/pc9821_ports_pkg.sv
  src/pc9821/core/pc9821_dmac.sv
  src/pc9821/core/pc9821_iobus.sv
  src/pc9821/core/pc9821_cpu_reset_gate.sv
  src/pc9821/core/pc9821_cpu_clk.sv src/pc9821/core/pc9821_cpu_bus_bridge.sv
  src/pc9821/input/pc9821_kbd.sv src/pc9821/input/pc9821_mouse.sv src/pc9821/interrupts/pc9821_pic.sv
  src/pc9821/timers/pc9821_pit.sv src/pc9821/rtc/pc9821_calendar.sv
  src/pc9821/core/pc9821_window_responder.sv
  src/pc9821/core/pc9821_memory_map.sv src/pc9821/core/pc9821_open_bus.sv
  src/pc9821/video/pc9821_pegc.sv
  src/pc9821/core/pc9821_rom_loader.sv src/pc9821/core/pc9821_memory_subsystem.sv
  src/pc9821/core/pc9821_pegc_storebuf.sv
  src/pc9821/core/pc9821_rhythm_loader.sv
  src/pc9821/core/pc9821_egc.sv
  src/pc9821/core/pc9821_device_select.sv
  src/pc9821/core/pc9821_gameport.sv
  src/pc9821/core/pc9821_watchdog_msg.sv
  src/pc9821/core/pc9821_perf_msg.sv
  src/pc9821/core/pc9821_gfx_msg.sv
  src/pc9821/core/pc9821_wdg_trigger.sv
  src/pc9821/core/pc9821_dbg_record.sv
  src/pc9821/core/pc9821_dbg_ring.sv
  src/pc9821/core/pc9821_dbg_mux.sv
  src/pc9821/core/pc9821_dbg_cpu.sv
  src/pc9821/video/pc9821_gdc_log.sv
  src/pc9821/core/pc9821_gvram_arb.sv src/pc9821/core/pc9821_gvram_share.sv src/pc9821/core/pc9821_gvram_scan.sv
  src/pc9821/core/pc9821_pegc_scan.sv
  src/pc9821/core/pc9821_gvram_mem.sv
  src/pc9821/core/pc9821_system.sv
  # PC-9801-86 sound (vendored YM2608 OPNA + glue).
  src/opna/pc9821_opna.sv
  # PC-9801-86 sound: the 86-PCM block, the card's other device.
  src/pcm86/pc9821_pcm86.sv
  src/pcm86/pc9821_pcm86_buf.sv
  src/opna/jtopna.v
  src/opna/jt12/hdl/jt08.v
  src/opna/jt12/hdl/jt08_acc.v
  src/opna/jt12/hdl/jt12_acc.v
  src/opna/jt12/hdl/jt12_csr.v
  src/opna/jt12/hdl/jt12_div.v
  src/opna/jt12/hdl/jt12_dout.v
  src/opna/jt12/hdl/jt12_eg.v
  src/opna/jt12/hdl/jt12_eg_cnt.v
  src/opna/jt12/hdl/jt12_eg_comb.v
  src/opna/jt12/hdl/jt12_eg_ctrl.v
  src/opna/jt12/hdl/jt12_eg_final.v
  src/opna/jt12/hdl/jt12_eg_pure.v
  src/opna/jt12/hdl/jt12_eg_step.v
  src/opna/jt12/hdl/jt12_exprom.v
  src/opna/jt12/hdl/jt12_kon.v
  src/opna/jt12/hdl/jt12_lfo.v
  src/opna/jt12/hdl/jt12_logsin.v
  src/opna/jt12/hdl/jt12_mmr.v
  src/opna/jt12/hdl/jt12_mod.v
  src/opna/jt12/hdl/jt12_op.v
  src/opna/jt12/hdl/jt12_pcm.v
  src/opna/jt12/hdl/jt12_pg.v
  src/opna/jt12/hdl/jt12_pg_comb.v
  src/opna/jt12/hdl/jt12_pg_dt.v
  src/opna/jt12/hdl/jt12_pg_inc.v
  src/opna/jt12/hdl/jt12_pg_sum.v
  src/opna/jt12/hdl/jt12_pm.v
  src/opna/jt12/hdl/jt12_reg.v
  src/opna/jt12/hdl/jt12_reg_ch.v
  src/opna/jt12/hdl/jt12_rst.v
  src/opna/jt12/hdl/jt12_sh.v
  src/opna/jt12/hdl/jt12_sh24.v
  src/opna/jt12/hdl/jt12_sh_rst.v
  src/opna/jt12/hdl/jt12_single_acc.v
  src/opna/jt12/hdl/jt12_sumch.v
  src/opna/jt12/hdl/jt12_timers.v
  src/opna/jt12/hdl/jt12_top.v
  src/opna/jt12/hdl/mixer/jt12_comb.v
  src/opna/jt12/hdl/mixer/jt12_decim.v
  src/opna/jt12/hdl/mixer/jt12_fm_uprate.v
  src/opna/jt12/hdl/mixer/jt12_genmix.v
  src/opna/jt12/hdl/mixer/jt12_interpol.v
  src/opna/jt12/hdl/adpcm/jt08_adpcm_acc.v
  src/opna/jt12/hdl/adpcm/jt08_adpcm_cnt.v
  src/opna/jt12/hdl/adpcm/jt08_adpcm_drvA.v
  src/opna/jt12/hdl/adpcm/jt08_adpcm_drvB.v
  src/opna/jt12/hdl/adpcm/jt08_adpcm_gain.v
  src/opna/jt12/hdl/adpcm/jt08_adpcm_rmul.v
  src/opna/jt12/hdl/adpcm/jt08_adpcmb_cnt.v
  src/opna/jt12/hdl/adpcm/jt08_adpcmb_interpol.v
  src/opna/jt12/hdl/adpcm/jt10_adpcm.v
  src/opna/jt12/hdl/adpcm/jt10_adpcm_dbrom.v
  src/opna/jt12/hdl/adpcm/jt10_adpcma_lut.v
  src/opna/jt12/hdl/adpcm/jt10_adpcmb.v
  src/opna/jt12/hdl/adpcm/jt10_adpcmb_gain.v
  src/opna/jt12/hdl/adpcm/jt10_cen_burst.v
  src/opna/jt49/hdl/jt49.v
  src/opna/jt49/hdl/jt49_bus.v
  src/opna/jt49/hdl/jt49_cen.v
  src/opna/jt49/hdl/jt49_div.v
  src/opna/jt49/hdl/jt49_eg.v
  src/opna/jt49/hdl/jt49_exp.v
  src/opna/jt49/hdl/jt49_noise.v
  src/opna/rhythm_rom/RHYTHM_ROM.v
)
