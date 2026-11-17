# Raw CTRL DRAIN to continuous output

DrainInputReplay models the registered DRAIN decode in tile_ffn_v4.sv. It filters FT_CTRL and operation zero, accepts the selected tile or broadcast target, and emits bank/slot/start/count/segment/last_segment one edge later. It preserves illegal ranges for the existing drain engine to reject. DrainDrivenOutputReplay connects this decoder to the continuous GU/Y/bus model; capture, commit and STATUS remain caller inputs, and other downstream operations are outside this adapter.

Four tests passed: registered fields and consecutive commands with target/op filtering, reset cancellation, raw CTRL through real Y control timing, and illegal range reporting. Busy engine commands remain explicitly rejected by the composed model rather than silently lost.

Both current received full traces passed 60/60 comparisons of epoch, command edge, bank, slot, start and count against drain_accept events. Segment and last_segment are decoded and unit-tested but are NOT recorded by this trace event, so this audit does not establish their RTL trace equivalence. The batch audit exploits decode independence: each raw flit is decoded then its registered output is sampled one edge later. Consecutive/register/reset behavior is covered separately by unit tests.

This removes manual DRAIN-field input from the continuous output adapter. It does not implement full CTRL/status handling, core scheduling, numerical outputs or a full-Tile continuous throughput calibration. Original logs remain unchanged. check.py and checks.json preserve the trace comparison and source hashes bind the implementation.
