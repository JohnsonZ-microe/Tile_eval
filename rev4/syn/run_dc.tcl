# Rev4 Design Compiler script (run by scripts/run.py dc; cwd = snapshot).
# Environment: TOP, TARGET_DB, DC_RUN_DIR, FILELIST (all set by run.py);
# DC_CORES, FIX_HOLD, CLK_PERIOD and the I/O budget defaults live in
# syn/constraints.tcl. Default mode is LOGIC CHECK: PE4_MEM_BLACKBOX turns
# every large array and the sigmoid ROM into unmapped macros (listed in
# reports/unmapped_macros.rpt). Set DC_FULL_MEM=1 to disable blackboxing --
# NOT recommended: the RRAM model and ROMs map to tens of Mbit of gates.
proc setting {name default} {
    if {[info exists ::env($name)]} { return $::env($name) }
    return $default
}
if {[catch {
    set top $::env(TOP)
    set target $::env(TARGET_DB)
    set rundir $::env(DC_RUN_DIR)
    set filelist [setting FILELIST ""]
    if {$filelist eq ""} {
        error "FILELIST not provided; run through scripts/run.py dc"
    }
    set full_mem [setting DC_FULL_MEM 0]
    set reportdir $rundir/reports
    file mkdir $reportdir
    set_app_var search_path ". $rundir"
    set_app_var target_library $target
    set_app_var link_library "* $target"
    # Read the filelist and pass files as a direct list: DC's analyze has
    # argument-parsing issues when -define and -f are combined (rtl.f path
    # gets mis-bound to -format in syn-vv2023.12)
    set fh [open $filelist r]
    set flist [read $fh]
    close $fh
    set files {}
    foreach line [split $flist "\n"] {
        set line [string trim $line]
        if {$line ne ""} {
            regsub -all {"} $line {} line
            lappend files $line
        }
    }
    puts "DC: analyzing [llength $files] source files"
    if {$full_mem eq "1"} {
        analyze -format sverilog $files
    } else {
        analyze -format sverilog -define PE4_MEM_BLACKBOX $files
    }
    elaborate $top
    current_design $top
    link
    source syn/constraints.tcl
    # ---- unmapped macro list (logic-check mode evidence) ----
    set fh [open $reportdir/unmapped_macros.rpt w]
    if {$full_mem eq "1"} {
        puts $fh "# mode: FULL-MEMORY MAP (behavioural arrays synthesised; NOT silicon SRAM/ROM area)"
    } else {
        puts $fh "# mode: LOGIC CHECK (memories and sigmoid ROM blackboxed)"
    }
    foreach_in_collection d [get_designs *] {
        if {![catch {get_attribute $d is_black_box} bb] && $bb} {
            puts $fh "black_box: [get_attribute $d name]"
        }
    }
    close $fh
    # ---- checks ----
    redirect $reportdir/check_design.rpt { check_design }
    redirect $reportdir/check_timing.rpt { check_timing }
    # ---- compile ----
    compile_ultra -no_autoungroup
    # ---- reports ----
    redirect $reportdir/area.rpt { report_area -hierarchy }
    redirect $reportdir/timing_setup.rpt { report_timing -delay max -max_paths 20 -input_pins -nets -transition_time }
    redirect $reportdir/timing_hold.rpt { report_timing -delay min -max_paths 20 }
    redirect $reportdir/timing_registers.rpt { report_registers }
    redirect $reportdir/constraints.rpt { report_constraints -all_violators }
    redirect $reportdir/qor.rpt { report_qor }
    redirect $reportdir/units.rpt { report_units }
    # ---- netlist ----
    write -format verilog -hierarchy -output $rundir/netlist.v
    write -format ddc -hierarchy -output $rundir/netlist.ddc
    set fh [open $rundir/SYNTHESIS_COMPLETED w]
    puts $fh "top=$top full_mem=$full_mem"
    close $fh
    puts "DC flow completed for $top (mapping done; review reports)"
} msg]} {
    puts "Error: $msg"
    exit 1
}
exit 0
