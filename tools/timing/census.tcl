# tools/timing/census.tcl: the per-endpoint path census, run by tools/build.py as QUARTUS_POST_STA_TCL
# against the fitted database (cwd = the build scratch), into output_files/census/ so a sweep's
# per-seed output_files copy keeps it. The SDCs are LOADED (create_timing_netlist; read_sdc;
# update_timing_netlist) - a raw session auto-derives clocks and invents cross-domain paths.
#   clk_sys = general[0] (the core clock; the CPU's gated clock and the SDRAM controller are timed
#   on it); PC9821_SDRAM_CLK = the generated clock on the SDRAM_CLK pin (from general[1]).
# Outputs:
#   ends_sys.rpt        setup, clk_sys->clk_sys, one worst path per endpoint, 4000 endpoints, at
#                       the corner with the worst clk_sys setup slack
#   ends_sys_hold.rpt   hold, same pairing, 1000 endpoints, at the fast corner with the worst hold
#   sdram_io_<corner>_{setup,hold}.rpt  every path into/out of PC9821_SDRAM_CLK, 200 endpoints
#   corners.txt         worst setup/hold per corner for both groups
#   ends_all_setup.rpt  every endpoint (any clock pair) with setup slack < 0.5 ns at the worst
#                       setup corner, summary rows (from, to, slack): the cone classifiers' input
#   aud_<tag>_<corner>_{setup,hold}.rpt  the audio hierarchy at every corner
#   iocone_<tag>.rpt    the iobus-launched device cone per launch family, full paths
#   cones.txt           named cones under the project SDC (CONE tag n worst neg): the reset
#                       release, the hps_io configuration-word writes, which the SDC times,
#                       and the clock-enable multicycles' destinations (mc_*);
#                       cones_hold.txt the multicycles' hold slack at the worst hold corner
#   ena_paths.tsv       the clock-enable census (tools/timing/cen_census.tcl; cen_census.py)
#   exceptions.txt      the timing-exception audit (tools/timing/sdc_audit.tcl;
#                       tools/check_sdc_exceptions.py --fit), with noexc_*.sdc beside it
#   keepdb.tar          the fitted database (db/, qdb/ if present, qpf/qsf, sdc) for later queries
# The two sourced scripts are read from the fitted tree (cwd), so a copy of this file can serve as
# a fit host's QUARTUS_POST_STA_TCL for any tree that carries them.
project_open z486_mister -revision z486_mister
create_timing_netlist
read_sdc
update_timing_netlist
file mkdir output_files/census
set out output_files/census
# clk_sys under either name the PLL's output takes (general[0] or counter[0]); sdc_audit.tcl,
# sourced below, takes it from this proc too, so the two scripts cannot name different clocks.
proc pc9821_sys_clock {} {
  return [get_clocks -nowarn {emu|pll|pll_inst|altera_pll_i|general[0]*|divclk emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter*|divclk}]
}
set sys [pc9821_sys_clock]
set sdp [get_clocks {PC9821_SDRAM_CLK}]
set fh [open $out/corners.txt w]
set worst_s 1e9; set worst_s_c ""
set worst_h 1e9; set worst_h_c ""
foreach c [get_available_operating_conditions] {
  set_operating_conditions $c
  update_timing_netlist
  set s [lindex [report_timing -setup -from_clock $sys -to_clock $sys -npaths 1 -nworst 1 -quiet] 1]
  set h [lindex [report_timing -hold  -from_clock $sys -to_clock $sys -npaths 1 -nworst 1 -quiet] 1]
  set os [lindex [report_timing -setup -to_clock $sdp -npaths 1 -nworst 1 -quiet] 1]
  set oh [lindex [report_timing -hold  -to_clock $sdp -npaths 1 -nworst 1 -quiet] 1]
  set is [lindex [report_timing -setup -from_clock $sdp -npaths 1 -nworst 1 -quiet] 1]
  set ih [lindex [report_timing -hold  -from_clock $sdp -npaths 1 -nworst 1 -quiet] 1]
  puts $fh "$c sys_setup $s sys_hold $h sdram_out_setup $os sdram_out_hold $oh sdram_in_setup $is sdram_in_hold $ih"
  if {$s ne "" && $s < $worst_s} { set worst_s $s; set worst_s_c $c }
  if {$h ne "" && $h < $worst_h} { set worst_h $h; set worst_h_c $c }
  foreach {dir k} {-to_clock out -from_clock in} {
    report_timing -setup $dir $sdp -npaths 200 -nworst 1 -detail path_only -file $out/sdram_io_${k}_${c}_setup.rpt
    report_timing -hold  $dir $sdp -npaths 200 -nworst 1 -detail path_only -file $out/sdram_io_${k}_${c}_hold.rpt
  }
}
puts $fh "WORST sys_setup $worst_s at $worst_s_c ; sys_hold $worst_h at $worst_h_c"
close $fh
set_operating_conditions $worst_s_c
update_timing_netlist
report_timing -setup -from_clock $sys -to_clock $sys -npaths 4000 -nworst 1 -detail path_only -file $out/ends_sys.rpt
report_timing -setup -npaths 300000 -nworst 1 -less_than_slack 0.5 -detail summary -file $out/ends_all_setup.rpt
set fh [open $out/cones.txt w]
foreach {tag dir pat} {
  reset_release from {*reset_sync_r*}
  reset_tree    from {*pc9821_reset_tree:*|q_r[*]}
  status_write  to   {*hps_io|status[*]}
  sdramsz_write to   {*hps_io|sdram_sz[*]}
  imgsz_write   to   {*hps_io|img_size[*]}
} {
  set k [get_keepers -nowarn $pat]
  if {[get_collection_size $k] == 0} { puts $fh "CONE $tag 0 0 0"; continue }
  set a [report_timing -setup -$dir $k -npaths 200000 -nworst 1 -quiet]
  set b [report_timing -setup -$dir $k -npaths 200000 -nworst 1 -less_than_slack 0 -quiet]
  puts $fh "CONE $tag [lindex $a 0] [lindex $a 1] [lindex $b 0]"
  report_timing -setup -$dir $k -npaths 200 -nworst 1 -detail summary -file $out/cone_${tag}.rpt
}
# the clock-enable multicycles' destinations (the SDC's own collections): what still limits them
foreach g {crtc jt12 hpsio rhythm sysio} {
  if {![info exists ::pc9821_mc_${g}_dst]} { puts $fh "CONE mc_$g 0 0 0"; continue }
  set k [set ::pc9821_mc_${g}_dst]
  set a [report_timing -setup -to $k -npaths 200000 -nworst 1 -quiet]
  set b [report_timing -setup -to $k -npaths 200000 -nworst 1 -less_than_slack 0 -quiet]
  puts $fh "CONE mc_$g [lindex $a 0] [lindex $a 1] [lindex $b 0]"
  report_timing -setup -to $k -npaths 200 -nworst 1 -detail summary -file $out/cone_mc_${g}.rpt
}
set rt [get_registers -nowarn {*pc9821_reset_tree:*|q_r[*]}]
puts $fh "COPIES [get_collection_size $rt]"
foreach_in_collection r $rt { puts $fh "COPY [get_object_info -name $r]" }
close $fh
if {[catch {source tools/timing/cen_census.tcl} err]} { puts "cen_census: $err" }
foreach c [get_available_operating_conditions] {
  set_operating_conditions $c
  update_timing_netlist
  foreach pat {*u_audio_mix* *u_audio_out* *cdda_inst* *opna* *pcm86* *audio* *beep* *jt12* *jt10*} {
    set tg [get_keepers $pat]
    if {[get_collection_size $tg] == 0} continue
    regsub -all {[^A-Za-z0-9]} $pat {} tag
    report_timing -setup -to $tg -npaths 20000 -nworst 1 -less_than_slack 2.0 -detail summary -file $out/aud_${tag}_${c}_setup.rpt
    report_timing -hold -to $tg -npaths 2000 -nworst 1 -less_than_slack 0.3 -detail summary -file $out/aud_${tag}_${c}_hold.rpt
  }
}
set_operating_conditions $worst_s_c
update_timing_netlist
foreach {tag from} {base {*pc9821_iobus:iobus|base_addr[*]} lane {*pc9821_iobus:iobus|lane[*]} wdata {*pc9821_iobus:iobus|write_data[*]} selq {*pc9821_iobus:iobus|sel_q[*]} state {*pc9821_iobus:iobus|state*} dev {*pc9821_iobus:iobus|dev_*} hitq {*pc9821_iobus:iobus|hit_q*}} {
  set k [get_keepers $from]
  if {[get_collection_size $k] == 0} continue
  report_timing -setup -from $k -npaths 400 -nworst 1 -less_than_slack 0.0 -detail full_path -file $out/iocone_${tag}.rpt
}
set_operating_conditions $worst_h_c
update_timing_netlist
report_timing -hold -from_clock $sys -to_clock $sys -npaths 1000 -nworst 1 -detail path_only -file $out/ends_sys_hold.rpt
set fh [open $out/cones_hold.txt w]
foreach g {crtc jt12 hpsio rhythm sysio} {
  if {![info exists ::pc9821_mc_${g}_src]} continue
  set a [report_timing -hold -from [set ::pc9821_mc_${g}_src] -to [set ::pc9821_mc_${g}_dst] -npaths 100 -nworst 1 -quiet]
  puts $fh "HOLD mc_$g [lindex $a 0] [lindex $a 1]"
}
close $fh
if {[catch {source tools/timing/sdc_audit.tcl} err]} { puts "sdc_audit: $err" }
project_close
set keep [list]
foreach f [concat [glob -nocomplain db qdb] [glob -nocomplain *.qpf *.qsf *.sdc] [glob -nocomplain sys/*.sdc]] { lappend keep $f }
catch {exec tar -cf $out/../keepdb.tar {*}$keep} err
puts "keepdb: $err"
