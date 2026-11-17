# Persistent output contention: model experiment

60 parameter combinations passed model invariants: token counts 1..4, credit return delays 1/6/7/16/64 edges, and GU capture at edges 160/179/240. Every case has one committed 80-column Y slot, one H packet and one STATUS. A paired run without Y supplies the GU retirement baseline. No state/credit reset occurs between producers. Returned credit is scheduled only for actually accepted output beats.

Checks require exactly the expected H/Y/STATUS counts, no packet interleaving, no credit overreturn, credit plus outstanding returns equal six at every edge, no bypass when pre-edge credit is zero, final credit six, and final Y-slot release. These are synthetic Python model checks, not new RTL coverage or application-throughput measurements.

## Observed control cost

For one token, capture edge 179 makes H ready at edge 240. With delay 1, the no-Y GU retires at 244; with Y it retires at 305 (61 edges later). Y owns the packet lock for all 61 waiting edges, including 52 edges with no valid Y source beat. STATUS follows at 306. This case has zero credit stalls, so its delay is attributable to packet locking and the sparse Y producer rather than insufficient credits.

| Credit return delay | GU retirement | Delta vs no Y | STATUS edge | Credit-stall edges |
|---|---:|---:|---:|---:|
| 1 | 305 | 61 | 306 | 0 |
| 6 | 305 | 61 | 307 | 1 |
| 7 | 305 | 61 | 308 | 2 |
| 16 | 310 | 66 | 317 | 11 |
| 64 | 381 | 137 | 388 | 82 |

The clock origin and launch schedule are synthetic. Deltas are not measured savings for the real full-suite workload, which has zero H/Y simultaneous requests.

## RTL mechanism and candidate work

pe4_yacc DRAIN cycles through DWAIT (registered read and countdown) and DSEND (present/accept one row), then starts the next read only after acceptance. pe4_bus retains the Y grant until packet last. This explains why a ready H producer waits through Y read bubbles. A row prefetch buffer could overlap SRAM reads with the current row's output; a 128-bit phit entry alone is not a complete area estimate because metadata, outstanding-read tracking and control also cost hardware.

Do not merely shorten dwait_cnt: the shared SRAM port has a registered read path and same-bank COMMIT can replace read data. Current whole-COMMIT yield and read-countdown restart prevent a known wrong-slot race. A candidate pipeline must preserve data identity across yield/reset/credit stalls, never drop or replay a row, retain partial-row masks and last_segment clearing, and bound outstanding reads by actual buffers. Packet preemption would additionally require protocol/receiver support and is not assumed here.

Next RTL acceptance should run simultaneous H/Y/STATUS with credit delays, compare full payload and row identity, inject same-bank COMMIT during every prefetch stage, and reset at every outstanding-read position. Only after those tests and synthesis can latency/area/energy tradeoffs be claimed. No RTL optimization or remote run was performed in this audit.

## Reproduction

python Tile_eval/rev4/docs/audit/20261117-output-contention/check.py

Three new unittest methods (including the 60-case sweep) pass; nine existing continuous-output tests also pass (continuous-tests.log). checks.json includes detailed beats and counters; sources.json fingerprints the model and RTL sources.
