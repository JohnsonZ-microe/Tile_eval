# Explicit direct-mode numerical replay — 2026-11-18

Extended the VCD reader to accept a dot-separated root scope, rebasing signal names relative to that scope. Extra scopes must now share the selected root, preventing sibling-module contamination. The original single-level root remains the default.

The Y external-input checker accepts an explicit baseline/direct mode. Baseline selects tb_yacc_v4 and YNumericReplay. Direct selects tb_yacc_direct_v4.probe and DirectYExperiment. Results record both mode and top. There is no auto-fit, inferred time shift or fallback from one model to the other.

The hand-written numerical fixture now has a direct variant with presentation edges 235+6*r and acceptance 236+6*r, compared with baseline presentation 236+7*r. Both fixtures produce ten known numerical rows. The direct variant passes its selected model; each wrong-mode pairing is rejected at yb_valid. A synthetic nested VCD checks clock extraction, relative DUT names and isolation from sibling signals. Existing error, data and address corruption tests remain enabled.

For a new candidate waveform:

    python NPU_eval/af/vcd_y_numeric_check.py Tile_eval/vcd/yacc_direct_v4.vcd --mode direct

This is the raw waveform checker. The existing y_run_evidence binding orchestrator still accepts baseline yacc only; candidate source/manifest/receipt binding must be checked separately until that orchestrator is extended. No new candidate VCD has been received, so dynamic RTL calibration is pending. Local fixture success is not a substitute for VCS validation or PPA measurement.

Source hashes are recorded in sources.json and the full AF regression in af-regression.log.

Full AF regression: 289 tests passed in 60.794 seconds.
