# Full Tile overlap trace verification — 2026-11-15

Run vcs-20261115T023443Z-101124, full suite, seed 817, +OVERLAP confirmed
in the simulator command. Compile/run exit zero and the numeric scoreboard
reports PASS: 9818 flits, 877 beats, 48 SYNC1. All 22 RTL/ROM/testbench source
hashes match the current local files. Expected error-injection status 0e0004
matches checks.json; it is not an unexpected functional failure.

The 102757498-byte schema-2 CSV has 572949 events. Both issue/return/consume
counts are 108600; 60 Y publications and 60 DRAIN accepts agree with the run.
MemoryReplay checks latency, inflight credits and RQ capacity successfully,
using observed request/consume intent. Every paired component transaction has
matching epoch and identity: memory return +3 (108600), PE visible commit +35
(103680), ACT consume +24 (864), quant consume +4 (4320). These timings retain
the trace's pre/post sampling conventions.

Actual overlap: all 24 D commands precede the corresponding GU SYNC1, versus
none in the ordinary run. The bench still fences gathered H input until GU
completion, and waits for phase/Y readiness before DRAIN. This is command
admission overlap, not unrestricted end-to-end simultaneous GU/D computation.

Ordinary last output: cycle 355982; overlap: 355910. Both start their first command at 107291; the measured difference is 72 cycles across 24 cases (3 cycles per case on average). Do not extrapolate this synthetic command/gather schedule to workload throughput.

Artifacts: checks.json, stimulus.json, overlap-comparison.json and check.py.
The trace hashes differ between the two runs even though file sizes/counts match.
No existing historical report was overwritten.

Full Tile calibration remains unverified: the above checks consume observed
component inputs, not solely external flits/credits. Independent scheduler,
operand ownership and numerical replay still need integration. Physical PPA,
multi-seed/reset/backpressure coverage and real AF throughput are not proven
by these two simulations. No additional server run is required just to finish
this trace analysis.
