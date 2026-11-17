# External-input Y waveform replay gate — 2026-11-17

Added vcd_y_numeric_check.py. It reconstructs Y model inputs exclusively from reset, D-buffer loads, COMMIT fields (including packed slot and weight aliases), DRAIN commands and ready. Internal SRAM write/read ports are checked against predictions; none of their values seed the model. The checker compares physical write enable/address/data, registered read requests, busy, output valid/payload/sideband and illegal-DRAIN pulses. It requires load/commit/write/output coverage, sampled reset and a drained terminal state. On reset it still checks a previously registered physical write after the first priming reset edge.

A hand-calculated 303-edge fixture covers reset, one D-buffer load, a ten-row commit and a ten-beat DRAIN. The fixture is constructed without calling the model: CRD edges are 3+22*r, physical writes 25+22*r, output presentation 236+7*r and acceptance 237+7*r. Row 0 contains FP32 3; the other rows contain FP32 1. Mutation tests reject changed physical write addresses/data, output payload/tag/last, read addresses, busy and valid timing. Missing packed command inputs, truncated workloads and absent coverage are also rejected.

The historical yacc waveform is rejected at timestamp 145000 because model_commit_slots is absent. This is an expected evidence gap, not an RTL or numerical mismatch. The newly added testbench aliases are required to run this checker against a fresh simulation. No historical waveform has been relabeled as full external-input calibrated.

When the new yacc VCD arrives, run from the project root:

    python NPU_eval/af/vcd_y_numeric_check.py Tile_eval/vcd/yacc_v4.vcd

If it fails, retain the result and diagnose the first divergence. Full external-input RTL calibration is pending. This checker validates the Y component given upstream D-buffer data; it does not establish correctness of upstream PE dot products, full Tile scheduling, physical timing or PPA.

See historical-waveform-check.json, af-regression.log and sources.json for the observed gate result, regression and hashes.

Full AF regression: 273 tests passed in 46.360 seconds.
