# ALARM trace terminal completeness

The first sparse checker could accept a prefix ending after one successful ALARM delivery. It now requires alarm_end_v1, emitted on normal testbench termination at calibration_cycle-1 (the last fully sampled edge). Payload bits 186:0 hold the same state as alarm_state_v1; bits 218:187 contain the testbench error count. A timeout/fatal cannot produce a successful terminal record.

The checker advances through the full terminal cycle, compares the final state, rejects pending delivery, nonzero testbench errors, missing/early/duplicate terminal records and ALARM samples after termination. It still checks only the observed error-input to register-state relationship. Completion markers detect ordinary truncated transfers, not arbitrary tampering or omitted silent-tail events; source hashes remain necessary.

Each epoch must contain a terminal record. The current tile bench emits one at final termination and normally has one active epoch; a multi-epoch trace without per-epoch terminals is explicitly rejected, not silently considered covered.

Validation: four focused checker tests pass, including terminal corruption and missing data. Initial semantic compile failed due to declaration order (preserved in ../20261117-alarm-trace-terminal). Moving terminal logging into a task below the declarations resolved it; this directory's checks.json records successful semantic compilation. Dynamic VCS validation remains pending. af-regression.log records the full subsequent Python regression.

No RTL datapath, stimulus or remote job changed. Sync tb_tile_v4.sv before the next planned tile calibration run. Existing simulation traces and prior audit evidence were preserved. The dated UI source comparisons describe their earlier snapshot; this subsequent testbench edit is not covered by those source hashes.
