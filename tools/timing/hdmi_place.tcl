# tools/timing/hdmi_place.tcl: where the framework pll_hdmi cone and the clk_vid cluster sit, run by
# tools/build.py as QUARTUS_POST_STA_TCL against the fitted database (cwd = the build scratch), into
# output_files/hplace/: hdmi_paths.rpt (3000 worst pll_hdmi setup paths), hdmi_worst.rpt (40, full
# path with cell locations), cells.txt.gz (every cell's location and name), regs_{hdmi,vid}.txt
# (the keepers each clock fans out to). Read by tools/timing/hdmi_place.py.
project_open z486_mister -revision z486_mister
create_timing_netlist
read_sdc
update_timing_netlist
set out output_files/hplace
file mkdir $out
set hclk [get_clocks {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}]
report_timing -setup -to_clock $hclk -npaths 3000 -detail summary -file $out/hdmi_paths.rpt
report_timing -setup -to_clock $hclk -npaths 40 -detail full_path -file $out/hdmi_worst.rpt
report_clocks -file $out/clocks.rpt
# Every cell's location, for an occupancy map by hierarchy.
set fh [open $out/cells.txt w]
set n 0
foreach_in_collection c [get_cells -hierarchical *] {
  set loc ""
  catch {set loc [get_cell_info -location $c]}
  puts $fh "$loc [get_cell_info -name $c]"
  incr n
}
close $fh
puts "cells dumped: $n"
# Registers per clock domain (the clocks' fanout keepers).
foreach {tag pat} {
  hdmi {pll_hdmi|pll_hdmi_inst|altera_pll_i|cyclonev_pll|counter[0].output_counter|divclk}
  vid  {*vpll*divclk*}
} {
  set fh [open $out/regs_$tag.txt w]
  set k 0
  foreach_in_collection clk [get_clocks -nowarn $pat] {
    set tg [get_clock_info -targets $clk]
    foreach_in_collection r [get_fanouts $tg] {
      puts $fh [get_node_info -name $r]
      incr k
    }
  }
  close $fh
  puts "regs $tag: $k"
}
catch {exec gzip -f $out/cells.txt}
project_close
