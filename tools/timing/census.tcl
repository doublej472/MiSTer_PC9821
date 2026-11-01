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
#   keepdb.tar          the fitted database (db/, qdb/ if present, qpf/qsf, sdc) for later queries
project_open z486_mister -revision z486_mister
create_timing_netlist
read_sdc
update_timing_netlist
file mkdir output_files/census
set out output_files/census
set sys [get_clocks {emu|pll|pll_inst|altera_pll_i|general[0]*|divclk emu|pll|pll_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter*|divclk}]
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
set_operating_conditions $worst_h_c
update_timing_netlist
report_timing -hold -from_clock $sys -to_clock $sys -npaths 1000 -nworst 1 -detail path_only -file $out/ends_sys_hold.rpt
project_close
set keep [list]
foreach f [concat [glob -nocomplain db qdb] [glob -nocomplain *.qpf *.qsf *.sdc] [glob -nocomplain sys/*.sdc]] { lappend keep $f }
catch {exec tar -cf $out/../keepdb.tar {*}$keep} err
puts "keepdb: $err"
