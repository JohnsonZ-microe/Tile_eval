# Matched Y synthesis tops — 2026-11-18

Added pe4_yacc_baseline and pe4_yacc_direct in pe4_yacc_variants.sv, included in rtl.f. Both expose the same ports and instantiate a single core with identical hierarchy; only DIRECT_DRAIN differs (0 versus 1). This avoids comparing a bare baseline with a differently wrapped candidate under compile_ultra -no_autoungroup. The normal Tile instantiation remains default baseline.

Both synthesis tops passed semantic elaboration. The compiler reported the existing pe4_sched empty-body warning; no errors. The first file-generation attempt used the wrong relative work directory and failed before editing; it was rerun with an explicit project path. dc_shell is not available on this local PATH, so no synthesis or numeric area/timing/power result was generated.

Corrected settings.txt DC_CORES default from 16 to 4 to match run_dc.tcl's actual set_host_options default. This changes provenance output, not the effective synthesis setting.

When collecting paired licensed DC runs using the existing readable TARGET_DB environment:

    bash syn/run_dc.sh --top pe4_yacc_baseline --suite smoke --seed 817
    bash syn/run_dc.sh --top pe4_yacc_direct --suite smoke --seed 817

Retain both product directories including manifest.json, settings.txt, reports/, netlist.v and SYNTHESIS_COMPLETED. Verify identical source hashes, target-library hash/corner, effective delay/uncertainty/load constraints, memory mode and tool version before comparing area or slack. The top name is the intended difference. Review design/timing checks and missing reports before accepting either run. Current summarize_dc.py's area ratio alone does not establish comparability.

Default flow defines PE4_MEM_BLACKBOX. Its area covers mapped logic, excluding Y SRAM macros and other unmapped memories. Full-memory mode maps behavioral arrays and still does not produce physical SRAM macro area. No activity-based power report is currently generated; energy must remain unknown. The dphit register could be removed by constant propagation in direct mode, but no register or area savings are claimed until netlist/report inspection. A shorter cycle count may increase switching per cycle or alter timing; energy efficiency cannot be inferred from latency alone.

No remote job was started and the optimization remains opt-in pending dynamic validation and PPA evidence. sources.json and compile.log identify the prepared comparison configuration.
