# YACC commit timing correction — 2026-11-14

Scope: the current rev4 YACC commit component and the analytical models that
consume its latency. Whole-tile calibration, physical timing/PPA and full AF
throughput validation remain incomplete. RTL was not changed.

## Evidence

Input: Tile_eval/vcd/yacc_v4.vcd from the reported
vcs-20261114T011738Z-74848 run. The independent extraction records the VCD SHA-256,
size, analyzer hash and corrected model hash in yacc-timing-checked.json.
The local pe4_yacc.sv SHA-256 equals the run manifest value:
1751b20529723f40660349ff06ce0faa327d96767085e0add1679fc06de1a3b9.
The original manifest records waveform size but no waveform hash; association
also relies on the user-provided path and matching timestamp/count evidence.

Measured: 152 commits, 216 DRAIN packets, 2160 SRAM row writes, 2160 output beats,
9394 yield cycles. Output counts agree with the simulation log.
All 1944 adjacent reads within a lane have a 22-cycle interval, not 17.
The analytical schedule matches every recorded row start, SRAM write,
valid-slot publication and idle-visible edge in all 152 commits.
Observed masks are 0001, 0010, 0101, 1010, across both banks.
Other masks are RTL-derived and locally tested, not waveform-validated here.

## Correction

At trigger E0 the FSM enters CRD. An active row starts at E1, raises its write
request at E22 and writes SRAM at E23. Subsequent active rows start 22 cycles
apart. A disabled lane consumes one scan cycle. Each lane publishes its valid
bit at its last SRAM write edge; consumers see it on the following edge.
The post-edge idle time relative to trigger is:

    1 + 220 * popcount(mask) + (4 - popcount(mask))

Thus one enabled lane takes 224 cycles; two take 443. Four take 881 by the
RTL-derived schedule. tile_cycles.py now uses 22-cycle rows, disabled-lane
scans, and next-edge valid consumption. The generic NPU D-sweep model includes
the same disabled-lane scan cost. Its variable-row sweeps remain conditional
extensions, not validated native RTL functionality.

The existing independent NPU_eval/af/commit_replay.py already models the 21-cycle
read-to-write-request delay and registered application. This correction aligns
the older analytical path with that component timing; it does not replace the
existing replay modules or claim they form a calibrated whole-tile simulator.

## Model impact

The 24-case default single-pass sweep (six formats, 1–4 tokens, no bias) is in
yacc-model-impact.json. Predicted finish increases by 51/101/151/201 cycles for
1/2/3/4 tokens. Example fp4 four-token pass: 9499 -> 9700 cycles.
These are revised model predictions, not measured whole-tile throughput.
Historical reports and their manifests are not rewritten.

## Reproduce

From Tile_eval/rev4, choose a new output filename:

    python -B model/yacc_wave_timing.py ../vcd/yacc_v4.vcd --out NEW.json --check-commit
    python -B -m unittest discover -s model -p test_yacc*.py -v
    python -B -m unittest discover -s model -p test_tile_cycles.py -v

The waveform reader samples pre-edge inputs before any changes at a rising-edge
timestamp and outputs after all changes at that timestamp. It is tailored to
this bench, whose inputs are driven at falling edges. It does not claim to
recover delta-cycle order from VCD. Raw time units are preserved.

## Remaining performance issue

The current RTL holds a same-bank DRAIN throughout a busy commit; the standalone
analytical launcher still approximates yield at CRD collisions and uses a
six-cycle DRAIN interval. That path needs bank-aware, registered-port replay
integration before its latency and stall counters can be called calibrated.
The 9394 measured yield cycles identify a real serialization cost. Narrowing
arbitration requires preserving read identity through the registered mux/SRAM
pipeline, not simply deleting the whole-commit fence.

Physical area/energy benefit is unknown until synthesis and memory mapping.
