# Y DRAIN numerical formatting — 2026-11-17

Implemented integer-only FP32-bit-pattern to BF16 conversion with round-to-nearest-even, signed zero, subnormal, finite-overflow and signed canonical NaN behavior from pe4_pkg.fp32_to_bf16. The implementation uses quotient/remainder rounding rather than host floating-point arithmetic. DRAIN row formatting masks inactive columns and rejects unknown active words.

YMemoryReplay now builds DRAIN payloads from its modeled SRAM return, registers the payload in the send phase, holds it under backpressure and resets the output. Invalid slots produce zero beats without SRAM reads. COMMIT arithmetic still uses the explicit write-value callback; it is not claimed independent or complete.

Functional tests enumerate all non-NaN BF16 exact values and all finite midpoint rounding cases, plus directed signed NaN/infinity, zero, subnormal and overflow examples. Integration exercises a partial interval spanning two rows, output stalls, last-segment ownership release, reset, and invalid-slot zero output. Checker tests corrupt both captured and output payloads and remove an input to verify rejection.

Existing yacc waveform conditional replay passed: 98,114 edges; 3,000 SRAM-to-phit captures; 3,000 accepted payload beats; 7,490 stalled valid edges. All post-edge output payload registers match, including held values. No invalid-slot zero presentation occurred in this waveform (zero_presentations=0); that behavior is covered only by local tests here.

This waveform checker observes SRAM return data and FSM state. It proves conversion and output-register behavior, not independently predicted accumulation, full command-driven scheduling or physical SRAM behavior. The VCD hash matches the earlier yacc audit for vcs-20261114T042332Z-95723. New protocol simulation results are separate evidence.

Reproduce from project root: `python NPU_eval/af/vcd_y_payload_check.py Tile_eval/vcd/yacc_v4.vcd`. Full regression output is in af-regression.log. Source hashes and waveform identity are in sources.json and checks.json.

Full AF regression: 260 tests passed in 42.972 seconds.
