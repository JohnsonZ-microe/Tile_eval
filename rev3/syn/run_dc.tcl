proc setting {name default} {
    if {[info exists ::env($name)] && $::env($name) ne ""} {return $::env($name)}
    return $default
}
set root [file dirname [file dirname [file normalize [info script]]]]
if {[catch {
    set top $::env(TOP)
    set target $::env(TARGET_DB)
    set run_dir $::env(DC_RUN_DIR)
    cd $run_dir
    file mkdir work reports netlist
    define_design_lib WORK -path [file join $run_dir work]
    set_app_var search_path [concat [list [file dirname $target]] $search_path]
    set_app_var target_library [list $target]
    set_app_var link_library [concat [list *] $target_library]
    set_app_var hdlin_check_no_latch true
    set_host_options -max_cores [setting DC_CORES 16]
    set_app_var report_default_significant_digits 5
    redirect reports/host_options.rpt {report_host_options}
    set handle [open [file join $root scripts rtl.f] r]
    set sources {}
    foreach line [split [read $handle] \n] {
        if {[string trim $line] ne ""} {lappend sources [file join $root [string trim $line]]}
    }
    close $handle
    if {![analyze -format sverilog $sources]} {error "Analyze failed"}
    if {![elaborate $top]} {error "Elaboration failed"}
    current_design $top
    if {![link]} {error "Link failed"}
    redirect reports/units.rpt {report_units}
    redirect reports/library.rpt {
        foreach_in_collection library [get_libs *] {report_lib [get_object_name $library]}
    }
    redirect reports/check_design_pre.rpt {check_design}
    if {![check_design]} {error "Pre-compile design checks failed"}
    source [file join $root syn constraints.tcl]
    redirect reports/check_timing_pre.rpt {check_timing}
    write -format ddc -hierarchy -output netlist/elaborated.ddc
    if {![compile -map_effort high]} {error "Compile failed"}
    change_names -rules verilog -hierarchy
    redirect reports/check_design.rpt {check_design}
    redirect reports/check_timing.rpt {check_timing}
    redirect reports/qor.rpt {report_qor}
    redirect reports/area.rpt {report_area -hierarchy}
    redirect reports/timing_registers.rpt {report_timing -from [all_registers -clock_pins] -to [all_registers -data_pins] -delay_type max -max_paths 100 -nworst 1 -significant_digits 5}
    redirect reports/timing_setup.rpt {report_timing -delay_type max -max_paths 30 -nets -transition_time -capacitance}
    redirect reports/timing_hold.rpt {report_timing -delay_type min -max_paths 30 -nets -transition_time -capacitance}
    redirect reports/constraints.rpt {report_constraint -all_violators}
    redirect reports/resources.rpt {report_resources -hierarchy}
    redirect reports/references.rpt {report_reference -hierarchy}
    redirect reports/clocks.rpt {report_clock}
    if {![check_design]} {error "Post-compile design checks failed"}
    write -format verilog -hierarchy -output netlist/mapped.v
    write -format ddc -hierarchy -output netlist/mapped.ddc
    write_sdc netlist/mapped.sdc
    write_sdf netlist/mapped.sdf
    set handle [open SYNTHESIS_COMPLETED w]
    puts $handle "Mapping only. Not a timing, power or equivalence acceptance."
    close $handle
} reason]} {
    puts stderr "SYNTHESIS_FAILED: $reason"
    puts stderr $::errorInfo
    exit 1
}
exit 0
