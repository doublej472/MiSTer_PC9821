# tools/timing/sdram_io.tcl: the SDRAM pin interface's worst slacks at EVERY timing corner, run by
# tools/build.py after every successful fit against the fitted database (cwd = the build scratch),
# into output_files/sdram_io.txt so the fit's own output_files copy (and a sweep's per-seed copy)
# keeps it. tools/fit_metrics.py parses the file into metrics.json / the sweep summary, and
# tools/seed_sweep.py gates on it (--min-sdram-io).
#
# WHY A SEPARATE SESSION: the flow's own STA summary is the slow 100C corner only (the qsf sets
# TIMEQUEST_MULTICORNER_ANALYSIS OFF), and its PC9821_SDRAM_CLK row is the OUTPUT paths alone (the
# clock that latches them). The read capture (SDRAM_DQ -> the DQ input cell, launched by
# PC9821_SDRAM_CLK and latched by clk_sys) is reported under clk_sys, buried under the core's own
# -5 ns cones, and its binding corner is the fast one. So neither half of the read window ever
# reached a sweep's ranking before this script.
#
# The SDCs are LOADED (create_timing_netlist; read_sdc; update_timing_netlist): a raw session
# auto-derives clocks and invents cross-domain paths (AGENTS.md, the Quartus build).
#   out_*: every path TO PC9821_SDRAM_CLK (command, address, BA, DQM, write data at the pins)
#   in_*:  every path FROM PC9821_SDRAM_CLK (the DQ read capture, the setup-2 pairing the SDC sets)
# Output, one line per corner, `na` where a group has no path:
#   corner=<name> out_setup=<ns> out_hold=<ns> in_setup=<ns> in_hold=<ns>
project_open z486_mister -revision z486_mister
create_timing_netlist
read_sdc
update_timing_netlist
file mkdir output_files
set sdp [get_clocks {PC9821_SDRAM_CLK}]
set fh [open output_files/sdram_io.txt w]
proc pc9821_worst {kind dir clk} {
  set r [report_timing $kind $dir $clk -npaths 1 -nworst 1 -quiet]
  if {[lindex $r 0] == 0} { return na }
  return [lindex $r 1]
}
foreach c [get_available_operating_conditions] {
  set_operating_conditions $c
  update_timing_netlist
  set os [pc9821_worst -setup -to_clock $sdp]
  set oh [pc9821_worst -hold -to_clock $sdp]
  set is [pc9821_worst -setup -from_clock $sdp]
  set ih [pc9821_worst -hold -from_clock $sdp]
  puts $fh "corner=$c out_setup=$os out_hold=$oh in_setup=$is in_hold=$ih"
}
close $fh
project_close
