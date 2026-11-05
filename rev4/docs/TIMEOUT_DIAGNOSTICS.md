# Tile timeout diagnostics

This change instruments the testbench and runner only. It does not change
arithmetic, RTL, golden values, or historical run snapshots. Python checks
are not VCS compilation or simulation evidence.

Run on the licensed Linux server from rev4:

```bash
bash scripts/run_vcs.sh --test tile --seed 817 \
  --progress-cycles 10000 --wait-limit 2000000 --max-cycles 20000000
```

`--progress-cycles 0` disables periodic messages, not event/timeout messages.
Wait and global cycle limits must be positive signed 32-bit integers.
The global limit starts when reset is released and includes RRAM loading.
`TIMEOUT_SECONDS` remains 1800 by default for VCS commands; it measures wall
time per subprocess, not simulation cycles. The diagnostic plusargs are
passed only to tile, not math. A global cycle watchdog cannot detect a
zero-time scheduling loop; the wall timeout remains the final guard.

Every `PROGRESS` line is flushed and contains time, cycle, stage/target,
traffic counts, credits, FIFO/request occupancy, PE/Y busy, errors and the
last selected Y bank/slot. Y bank/slot are meaningful for Y waits; other
events may retain the last selection. The line is a monitoring snapshot,
not a transaction-level timing assertion. Stage completion is logged on
SYNC; GU/D and DRAIN send events are logged after the sampling edge.

The manifest contains diagnostic parameters, `timeout_seconds`, total
`seconds`, per-command `steps`, per-test `simulations`, `failed_step`, and
the last flushed progress line (`null` means unknown). `rtl_validation`
uses `not started`, `running`, `passed`, `failed`, or `timeout`. Compilation
failure is not an RTL simulation failure; per-test records distinguish
partial progress when running both math and tile. Top-level `status` is
`completed`, `failed`, or `timeout`; all unsuccessful runs return nonzero.
An anchored PASS marker, a zero process exit, and no FAIL/Fatal marker
are required. No output comparison is skipped.

Interpretation:

- Cycles and transaction counts advancing: measure speed before raising a wall limit.
- Cycles advancing, transactions stalled: inspect the named wait and resource state.
- Heartbeat stops while CPU remains active: investigate a possible zero-time loop.
- Heartbeat stops with inactive CPU: inspect process and server resource waits.

Preserve the new run's manifest and complete compile/run logs. Do not mix
logs or vectors from other Products directories. Physical SRAM mapping,
timing closure and complete Tile correctness remain separate validations.
