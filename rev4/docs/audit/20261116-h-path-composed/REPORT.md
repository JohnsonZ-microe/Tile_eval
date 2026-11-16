# Composed H path and D readiness — 2026-11-16

HPathReplay composes the routing register, four-stage quantizer timing/release
cancellation, and H-bank ownership/row validity. A raw H input can write at
input+5 and make readiness visible after that edge; D samples readiness at
input+6. Ready requires all expected rows/lanes, not merely the last input time.

The model accepts H=(pass,row,lane) and take/release operations. All components
use pre-edge ownership; a new take does not retroactively admit an H input on
that edge. Release cancellation survives same-pass bank reassignment. Duplicate
rows, lane/token errors, missing rows and reset preserve their component rules.
No numeric quantization, SRAM payload or command admission is invented.

h_path_trace_replay reads raw FT_H down-sideband records, plus observed
bank_take/release pulses, and predicts quant_accept, quant_consume, discarded
results, actual attempted bank writes and post-edge ownership/ready/error.
Observed writes/readiness are comparison-only. Sparse gaps advance the pending
stages and error-clearing edge before skipping stable idle cycles.

Two received full Tile CMD-retire traces passed:

- vcs-20261115T151442Z-8320: 4320 accepted writes, 24 ready transitions,
  zero mismatches, zero canceled results and zero route rejections.
- vcs-20261115T221329Z-18837: the same counts, zero mismatches.

checks.json contains each predicted ready edge, trace hashes and counts;
model-sources.json binds implementation hashes. These are not reset-validation
results for the newer RTL candidate: these traces contain only epoch initialization,
and do not exercise in-flight reset or malformed late H cancellation.

run_phase now supports h_inputs={cycle:{h/take/release...}} and an explicit
h_bank for phase D. It uses composed bank readiness to gate matrix issue,
preserving bias prefetch. Supplied d_ready_cycle and h_inputs are mutually
exclusive. Existing ideal/explicit-ready experiments remain available and
retain their scope labels. H input cycles are relative to the isolated phase's
model origin; full lifecycle time mapping is not supplied automatically.

Seven composition/checker tests passed, including corruption of raw input,
missing-row rejection despite observed writes, early ready, identity mutation,
same-edge take, reused-pass cancellation and 1..4 token full-bank completion.
Six D readiness tests passed; both bias settings produced identical issue/PE
events to an independently calculated ready edge (last H at 75, write at 80,
D availability at 81). Removing a row prevents matrix progress.

Full AF regression is recorded in af-regression.log. The remaining calibration
gap is independent generation of ownership/admission/retirement and continuous
bus/queue arbitration, followed by numerical payload and AF integration. This
work eliminates observed H write and ready timing as model inputs; it does not
eliminate observed ownership pulses or establish the full objective.
