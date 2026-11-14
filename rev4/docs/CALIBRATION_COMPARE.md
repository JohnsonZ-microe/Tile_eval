# Schema-2 calibration trace comparison

Status (2026-11-14): comparison infrastructure implemented and locally tested;
whole-tile RTL/model calibration remains unverified. Scope: current rev4
`tb_tile_v4.sv` CALIBRATION_TRACE schema 2. This does not change RTL timing,
stimulus, arithmetic, the legacy four-column comparator, or historical results.

## Capture

From Tile_eval/rev4 on the VCS host:

```bash
bash scripts/run_vcs.sh --test tile --suite full --seed 817 --waves --trace --calibration-trace
```

A separate overlap run must also pass before claiming overlap coverage:

```bash
bash scripts/run_vcs.sh --test tile --suite full --seed 817 --overlap --trace --calibration-trace
```

These commands have not been executed as part of this change. Keep the complete
run directory, including manifest, snapshots, logs and calibration-events.csv.
The supplied 20261114 YACC run passed its 216-packet scoreboard and read-identity
check; it is not a tile run and supplies no tile calibration CSV.

## Compare

```bash
python -B model/calibration_compare.py model-events.csv calibration-events.csv --require-event down --require-event memory_issue --require-event memory_return --require-event memory_consume --require-event pe_accept --require-event sync1 --require-event up_beat
```

The model-events file must come from an independent model driven by exactly the
captured stimulus, reset and credit schedule. That replay adapter is still
missing; do not copy RTL output into the expected stream or rename the legacy
model trace and call the result calibration.

Both files must use the exact 12-column header emitted by the RTL monitor.
Comparison preserves epoch, cycle, pre/post stage, transaction, pass, phase,
slot, kb, group, bank and the full 512-bit payload. Only hexadecimal letter case
is normalized. X/Z, malformed rows, empty streams and time-order violations fail.
Reset may restart cycle numbering only with a nondecreasing epoch ordering.
Independent event channels may be printed in either order at the same sample;
within a channel, no event is dropped, reordered or timestamp-shifted.
`--require-event` is repeatable and fails when either file lacks that channel.
Select additional scenario-specific events (ACT, quantization, Y drain, etc.)
according to the tested contract. Presence alone does not prove scenario coverage.

Exit status is 0 only for agreement; invalid files and mismatches return 1.
JSON output identifies the channel, occurrence, differing fields and nearby rows.
A PASS establishes agreement of the supplied traces only, not completeness of
stimulus coverage, numerical correctness, physical timing or PPA.

## Local validation

```text
python -B -m unittest discover -s model -p test_calibration*.py -v
9 tests passed (7 comparator tests, 2 existing trace interface source checks).
python -B -m unittest discover -s model -p test_tile_cycles.py -v
17 existing cycle-model tests passed.
```

Tests cover all identity fields, missing/extra/duplicate/reordered events,
required-channel absence, empty traces, reset epochs, pre/post ordering and X/Z.
These are Python checks, not VCS execution or RTL coverage measurements.
