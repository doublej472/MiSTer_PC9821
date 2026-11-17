# tools/timing/sdc_audit.tcl: the timing-exception audit, sourced by tools/timing/census.tcl inside
# its quartus_sta session (project open, timing netlist built, the project SDCs read). cwd is the
# fit's tree (tools/build.py's scratch), so the registry is read from the tree being fitted.
#
# For every row of tools/timing/sdc_exceptions.tsv it writes to $out/exceptions.txt:
#   COUNT id n min max         objects the row's pattern matches on THIS fitted netlist
#   LINES id n                 SDC command lines the row's match starts (its source file)
#   EXC file text              every exception command line of the two SDCs as fitted, so an
#                              exception the registry does not know fails the check
#   XEND s2v|v2s endpoint source   every endpoint of a clk_sys <-> video clock path
#   XENDN s2v|v2s n            the crossing audit RAN for that direction and wrote n XEND rows
#   XENDSKIP n                 the crossing audit did NOT run: the video clock pattern matched n
#                              clocks, not 1 (the check fails this; zero rows alone is not proof)
#   XFALL id node / XFALLN id n     the launches a measure=fall row hides
#   WOULD id kind corner n worst neg
#                              with every measured exception removed (the measure column),
#                              the paths this row's pattern covers: count, worst slack and the
#                              negative count, setup at the worst setup corner and hold at the
#                              worst hold corner. This is what each exception hides.
# tools/check_sdc_exceptions.py --fit judges the file. The session ends with the project SDCs
# re-read, so a caller can keep reporting after this script.
#
# Needs: $out (the output directory), $worst_s_c / $worst_h_c (corner names) and the proc
# pc9821_sys_clock (the clk_sys collection); census.tcl defines all three.

proc sdca_objs {kind pat} {
    switch -- $kind {
        registers { return [get_registers -nowarn $pat] }
        registers_nodup { return [get_registers -nowarn -no_duplicates $pat] }
        keepers   { return [get_keepers -nowarn $pat] }
        pins      { return [get_pins -nowarn $pat] }
        ports     { return [get_ports -nowarn $pat] }
        clocks    { return [get_clocks -nowarn $pat] }
        sdcvar_nodup {
            # a collection the SDC built (a global variable), its fitter ~DUPLICATE copies left out
            if {![info exists ::$pat]} { return {} }
            set keep {}
            foreach_in_collection r [set ::$pat] {
                if {![string match {*~DUPLICATE} [get_node_info -name $r]]} { lappend keep [get_node_info -name $r] }
            }
            return $keep
        }
    }
    error "sdc_audit: unknown kind $kind"
}

proc sdca_read_rows {path} {
    set rows {}
    set fh [open $path r]
    while {[gets $fh line] >= 0} {
        if {$line eq "" || [string index $line 0] eq "#"} continue
        set f [split $line "\t"]
        if {[llength $f] != 10} { error "sdc_audit: $path: expected 10 fields: $line" }
        lappend rows $f
    }
    close $fh
    return $rows
}

proc sdca_src_file {src} {
    switch -- $src {
        template - profile_gen { return z486_mister.sdc }
        sys_top                { return sys/sys_top.sdc }
    }
    return ""
}

# Copy an SDC with every line that starts (after leading blanks) with one of `matches` commented
# out. A continued command (a trailing backslash) is commented out to its end.
proc sdca_strip {src dst matches} {
    set in [open $src r]; set o [open $dst w]
    set cont 0
    while {[gets $in line] >= 0} {
        set t [string trimleft $line]
        set hit $cont
        if {!$hit} { foreach m $matches { if {[string first $m $t] == 0} { set hit 1; break } } }
        if {$hit} {
            puts $o "# sdc_audit removed: $line"
            set cont [expr {[string index $line end] eq "\\"}]
        } else {
            puts $o $line
            set cont 0
        }
    }
    close $in; close $o
}

set sdca_rows [sdca_read_rows tools/timing/sdc_exceptions.tsv]
set sdca_fh [open $out/exceptions.txt w]
puts $sdca_fh "# tools/timing/sdc_audit.tcl on [clock format [clock seconds] -gmt 1]"
foreach row $sdca_rows {
    lassign $row id src when kind pat mn mx measure match proof
    set objs [sdca_objs $kind $pat]
    if {$kind eq "sdcvar_nodup"} { set n [llength $objs] } else { set n [get_collection_size $objs] }
    puts $sdca_fh "COUNT $id $n $mn $mx"
    set file [sdca_src_file $src]
    if {$file ne ""} {
        set n 0
        set fh [open $file r]
        while {[gets $fh line] >= 0} {
            if {[string first $match [string trimleft $line]] == 0} { incr n }
        }
        close $fh
        puts $sdca_fh "LINES $id $n"
    }
}
foreach file {z486_mister.sdc sys/sys_top.sdc} {
    set fh [open $file r]
    while {[gets $fh line] >= 0} {
        set t [string trim $line]
        if {[regexp {^(set_false_path|set_multicycle_path|set_max_delay|set_min_delay|set_clock_groups)\M} $t]} {
            puts $sdca_fh "EXC $file $t"
        }
    }
    close $fh
}
# The clk_sys <-> video clock crossings are bounded by max-delays with their hold cut: every
# endpoint they reach must be one docs/clock-domains.md lists (tools/check_sdc_exceptions.py holds
# the whitelist), so a new unsynchronised word between the domains fails the check.
set sdca_sys [pc9821_sys_clock]
set sdca_vid [get_clocks -nowarn {*vpll|vpll_inst|altera_pll_i|*[0].*|divclk}]
if {[get_collection_size $sdca_vid] == 1} {
    foreach {tag f t} [list s2v $sdca_sys $sdca_vid v2s $sdca_vid $sdca_sys] {
        set seen [dict create]
        foreach_in_collection p [get_timing_paths -setup -from_clock $f -to_clock $t -npaths 20000 -nworst 1] {
            set n [get_node_info -name [get_path_info -to $p]]
            if {![dict exists $seen $n]} {
                dict set seen $n 1
                puts $sdca_fh "XEND $tag $n [get_node_info -name [get_path_info -from $p]]"
            }
        }
        puts $sdca_fh "XENDN $tag [dict size $seen]"
    }
} else {
    puts $sdca_fh "XENDSKIP [get_collection_size $sdca_vid]"
}
flush $sdca_fh

# What each measured exception hides: re-read both SDCs with the measured lines removed.
set sdca_rm(z486_mister.sdc) {}
set sdca_rm(sys/sys_top.sdc) {}
foreach row $sdca_rows {
    lassign $row id src when kind pat mn mx measure match proof
    set file [sdca_src_file $src]
    if {$measure ne "-" && $file ne ""} { lappend sdca_rm($file) $match }
}
sdca_strip sys/sys_top.sdc $out/noexc_sys_top.sdc $sdca_rm(sys/sys_top.sdc)
sdca_strip z486_mister.sdc $out/noexc_z486_mister.sdc $sdca_rm(z486_mister.sdc)
reset_design
read_sdc $out/noexc_sys_top.sdc
read_sdc $out/noexc_z486_mister.sdc
foreach {corner kind} [list $worst_s_c setup $worst_h_c hold] {
    set_operating_conditions $corner
    update_timing_netlist
    foreach row $sdca_rows {
        lassign $row id src when kind_ pat mn mx measure match proof
        if {$measure eq "-" || $measure eq "fall"} continue
        set k [sdca_objs $kind_ $pat]
        if {[get_collection_size $k] == 0} { puts $sdca_fh "WOULD $id $kind $corner 0 0 0"; continue }
        set a [report_timing -$kind -$measure $k -npaths 200000 -nworst 1 -quiet]
        set b [report_timing -$kind -$measure $k -npaths 200000 -nworst 1 -less_than_slack 0 -quiet]
        puts $sdca_fh "WOULD $id $kind $corner [lindex $a 0] [lindex $a 1] [lindex $b 0]"
    }
    flush $sdca_fh
}
# measure "fall" (the SDRAM output cells' falling-edge cut): the launches it hides must all be the
# DDIO cells' clock-phase mux (their ~DFFHI/~DFFLO halves), never a real falling-edge register.
set_operating_conditions $worst_s_c
update_timing_netlist
# reset_design re-created the clocks: fetch them again
set sdca_sys [pc9821_sys_clock]
foreach row $sdca_rows {
    lassign $row id src when kind_ pat mn mx measure match proof
    if {$measure ne "fall"} continue
    set seen [dict create]
    foreach_in_collection p [get_timing_paths -setup -fall_from_clock $sdca_sys -to [get_ports {SDRAM_*}] -npaths 2000 -nworst 1] {
        set n [get_node_info -name [get_path_info -from $p]]
        if {![dict exists $seen $n]} { dict set seen $n 1; puts $sdca_fh "XFALL $id $n" }
    }
    puts $sdca_fh "XFALLN $id [dict size $seen]"
}
close $sdca_fh
reset_design
read_sdc
update_timing_netlist
