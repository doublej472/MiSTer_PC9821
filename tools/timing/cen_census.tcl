# tools/timing/cen_census.tcl: the clock-enable census, sourced by tools/timing/census.tcl inside its
# quartus_sta session (project SDCs read, the worst setup corner selected).
#
# For every failing clk_sys -> clk_sys setup path (the worst path per endpoint) it writes one row of
# $out/ena_paths.tsv with the structure of BOTH ends, read from the fitted netlist:
#   slack, from, to,
#   from_ena, to_ena      the node driving the register's ENA pin ("" = no clock enable: the
#                         register loads every cycle; "<const>" = the pin has no synch edge to
#                         walk back: tied, or fed from a node -synch_edges does not traverse;
#                         cen_census.py counts these apart from the no-enable ends),
#   from_sclr, to_sclr    the node driving the synchronous clear,
#   from_sload, to_sload  the node driving the synchronous load,
#   from_cone, to_cone    the registers in the ENA driver's fan-in (a backward walk through
#                         combinational nodes, at most CEN_DEPTH levels and CEN_CAP registers;
#                         "+" appended when the walk was cut short), comma-separated.
# tools/timing/cen_census.py groups the rows by the enable generators it knows (their minimum
# number of clk_sys cycles between enables comes from the generator's RTL) and says which groups a
# `set_multicycle_path -setup N -hold N-1` could cover exactly. The netlist names are the fitter's
# (`emu|core|...|q` pins for cone members, `emu:emu|...` for path ends).
#
# Needs: $out, $sys (the clk_sys clock collection).

set CEN_DEPTH 48
set CEN_CAP 128

proc cen_nm {n} { return [get_node_info -name $n] }

# The node that drives a register's control pin <suffix>, "" if the pin is absent.
proc cen_ctl {r suffix} {
    foreach e [get_node_info -synch_edges $r] {
        set s [get_edge_info -src $e]
        if {[string match "*|$suffix" [cen_nm $s]]} {
            set ed [get_node_info -synch_edges $s]
            if {[llength $ed] == 0} { return "<const>" }
            return [get_edge_info -src [lindex $ed 0]]
        }
    }
    return ""
}

array set cen_cone {}
proc cen_keepers {drv} {
    global cen_cone CEN_DEPTH CEN_CAP
    if {[info exists cen_cone($drv)]} { return $cen_cone($drv) }
    set out {}; set seen [dict create]; set front [list $drv]; set depth 0; set cut 0
    while {[llength $front]} {
        if {$depth >= $CEN_DEPTH || [llength $out] >= $CEN_CAP} { set cut 1; break }
        set nf {}
        foreach n $front {
            if {[dict exists $seen $n]} continue
            dict set seen $n 1
            set name [cen_nm $n]
            if {[get_node_info -type $n] eq "reg" || [string match {*|q} $name] ||
                [string match {*portadataout*} $name] || [string match {*portbdataout*} $name]} {
                lappend out $name; continue
            }
            foreach e [get_node_info -synch_edges $n] { lappend nf [get_edge_info -src $e] }
        }
        set front $nf; incr depth
    }
    set res [join [lsort -unique $out] ","]
    if {$cut} { append res ",+" }
    set cen_cone($drv) $res
    return $res
}

array set cen_reg {}
proc cen_info {r} {
    global cen_reg
    set k [cen_nm $r]
    if {[info exists cen_reg($k)]} { return $cen_reg($k) }
    if {[get_node_info -type $r] ne "reg"} { set cen_reg($k) [list "-" "-" "-" "-"]; return $cen_reg($k) }
    set res {}
    set ena [cen_ctl $r ena]
    foreach d [list $ena [cen_ctl $r sclr] [cen_ctl $r sload]] {
        if {$d eq "" || $d eq "<const>"} { lappend res $d } else { lappend res [cen_nm $d] }
    }
    if {$ena ne "" && $ena ne "<const>"} { lappend res [cen_keepers $ena] } else { lappend res "" }
    set cen_reg($k) $res
    return $res
}

set cen_fh [open $out/ena_paths.tsv w]
puts $cen_fh "# slack\tfrom\tto\tfrom_ena\tto_ena\tfrom_sclr\tto_sclr\tfrom_sload\tto_sload\tfrom_cone\tto_cone"
foreach_in_collection p [get_timing_paths -setup -from_clock $sys -to_clock $sys -npaths 100000 -nworst 1 -less_than_slack 0] {
    set s [get_path_info -from $p]; set d [get_path_info -to $p]
    set si [cen_info $s]; set di [cen_info $d]
    puts $cen_fh [join [list [get_path_info -slack $p] [cen_nm $s] [cen_nm $d] \
        [lindex $si 0] [lindex $di 0] [lindex $si 1] [lindex $di 1] [lindex $si 2] [lindex $di 2] \
        [lindex $si 3] [lindex $di 3]] "\t"]
}
close $cen_fh
